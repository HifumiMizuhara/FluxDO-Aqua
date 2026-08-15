import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser list 识别', () {
    test('ul 产生 ListNode(ordered=false)', () {
      final result = parser.parse('<ul><li>a</li><li>b</li></ul>');
      expect(result, hasLength(1));
      final list = result[0] as ListNode;
      expect(list.ordered, isFalse);
      expect(list.depth, 0);
      expect(list.items, hasLength(2));
      expect(list.items[0].inlines, [const TextRun('a')]);
      expect(list.items[1].inlines, [const TextRun('b')]);
    });

    test('ol 产生 ListNode(ordered=true)', () {
      final result = parser.parse('<ol><li>第一</li><li>第二</li></ol>');
      expect(result, hasLength(1));
      final list = result[0] as ListNode;
      expect(list.ordered, isTrue);
      expect(list.items, hasLength(2));
    });

    test('li 内含 inline 混排', () {
      final result = parser.parse(
        '<ul><li>含 <strong>粗</strong> 和 <a href="/x">链接</a></li></ul>',
      );
      final list = result[0] as ListNode;
      final item = list.items[0];
      // text + strong + text + link + nothing(trailing 空)
      expect(item.inlines.length, greaterThanOrEqualTo(3));
      expect(item.inlines.whereType<StrongRun>(), hasLength(1));
      expect(item.inlines.whereType<LinkRun>(), hasLength(1));
    });

    test('li 内嵌套 ul → children 不为空', () {
      final result = parser.parse('<ul><li>外<ul><li>内</li></ul></li></ul>');
      final outer = result[0] as ListNode;
      final item = outer.items[0];
      expect(item.children, isNotNull);
      expect(item.children, hasLength(1));
      final inner = item.children![0];
      expect(inner.ordered, isFalse);
      expect(inner.depth, 1);
      expect(inner.items[0].inlines, [const TextRun('内')]);
    });

    test('li 内嵌套 ol → depth 递增', () {
      final result = parser.parse(
        '<ul><li>x<ol><li>1<ul><li>深</li></ul></li></ol></li></ul>',
      );
      final outer = result[0] as ListNode;
      final lvl1 = outer.items[0].children![0];
      expect(lvl1.depth, 1);
      expect(lvl1.ordered, isTrue);
      final lvl2 = lvl1.items[0].children![0];
      expect(lvl2.depth, 2);
      expect(lvl2.ordered, isFalse);
    });

    test('叶子 li children = null', () {
      final result = parser.parse('<ul><li>x</li></ul>');
      final list = result[0] as ListNode;
      expect(list.items[0].children, isNull);
    });

    test('list 跟 p 混排,各自独立 BlockNode', () {
      final result = parser.parse('<p>前</p><ul><li>a</li></ul><p>后</p>');
      expect(result, hasLength(3));
      expect(result[0], isA<ParagraphNode>());
      expect(result[1], isA<ListNode>());
      expect(result[2], isA<ParagraphNode>());
    });

    test('id 在嵌套场景下全局唯一,不冲突', () {
      final result = parser.parse(
        '<ul><li>a<ul><li>b</li></ul></li></ul><p>c</p>',
      );
      final outer = result[0] as ListNode;
      final inner = outer.items[0].children![0];
      final p = result[1] as ParagraphNode;
      // 三个 BlockNode 各自有独立 id
      expect({outer.id, inner.id, p.id}, hasLength(3));
    });

    test('非 li 子节点(白噪音 text)被忽略', () {
      final result = parser.parse('<ul>  \n  <li>x</li>  \n  </ul>');
      final list = result[0] as ListNode;
      expect(list.items, hasLength(1));
    });

    test('ol start 属性解析(<ol start="2"> → start=2,默认 1)', () {
      final s2 = parser.parse('<ol start="2"><li>a</li></ol>')[0] as ListNode;
      expect(s2.ordered, isTrue);
      expect(s2.start, 2);
      final s1 = parser.parse('<ol><li>a</li></ol>')[0] as ListNode;
      expect(s1.start, 1);
      // ul 忽略 start(恒 1)
      final ul = parser.parse('<ul start="5"><li>a</li></ul>')[0] as ListNode;
      expect(ul.start, 1);
      // start 非法值 → 回退 1
      final bad = parser.parse('<ol start="x"><li>a</li></ol>')[0] as ListNode;
      expect(bad.start, 1);
    });

    test('末尾 <br> 吸收一个(<br><br>→留1=一行空隙;单 <br>→0);中间保留', () {
      // 对齐浏览器:块/列表项最后一个 <br> 被边界吸收,其余各占一行。
      // <br><br> → 留 1 个(网页就是一行空隙;修前两行,过度裁后零行,均不对)。
      final two = parser.parse('<ul><li>x<br>\n<br></li></ul>')[0] as ListNode;
      expect(
        two.items.single.inlines.whereType<LineBreakRun>(),
        hasLength(1),
        reason: '<br><br> 末尾留 1 个 → 一行空隙',
      );
      expect(
        two.items.single.inlines
            .whereType<TextRun>()
            .map((t) => t.text)
            .toList(),
        ['x'],
      );
      // 单个末尾 <br> → 吸收 → 0。
      final one = parser.parse('<ul><li>x<br></li></ul>')[0] as ListNode;
      expect(
        one.items.single.inlines.whereType<LineBreakRun>(),
        isEmpty,
        reason: '单个末尾 <br> 被吸收',
      );
      // 内容中间 br 保留(故意换行)。
      final mid = parser.parse('<ul><li>a<br>b</li></ul>')[0] as ListNode;
      expect(
        mid.items.single.inlines.whereType<LineBreakRun>(),
        hasLength(1),
        reason: '内容中间 br 保留',
      );
    });

    test('外层 li 仅含嵌套 ol+ul(无直接文本)→ inlines 空 + children 两个子 list', () {
      // 真机 bug 结构:<li><ol>..</ol><ul>..</ul></li> 的包裹 li。
      final result = parser.parse(
        '<ul><li>'
        '<ol start="2"><li>中转站</li></ol>'
        '<ul><li>BASE_URL</li></ul>'
        '</li></ul>',
      );
      final outer = result[0] as ListNode;
      final wrapper = outer.items.single;
      expect(wrapper.inlines, isEmpty, reason: '包裹 li 无直接文本 → inlines 空');
      expect(wrapper.blocks, isNull, reason: 'ol/ul 不触发块级形态,走 inline 快路径');
      expect(wrapper.children, hasLength(2), reason: 'ol + ul 两个子 list');
      expect(wrapper.children![0].ordered, isTrue);
      expect(wrapper.children![0].start, 2);
      expect(wrapper.children![1].ordered, isFalse);
    });
  });
}

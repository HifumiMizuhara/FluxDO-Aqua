import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser click_count 识别', () {
    test('基础 span.click-count → ClickCountRun', () {
      final result = parser.parse(
        '<p>链接 <span class="click-count">42</span></p>',
      );
      final p = result[0] as ParagraphNode;
      final cc = p.inlines.whereType<ClickCountRun>().single;
      expect(cc.count, '42');
    });

    test('thin space 包裹的数字被 trim', () {
      final result = parser.parse(
        '<p><span class="click-count"> 1.2k </span></p>',
      );
      final cc = (result[0] as ParagraphNode).inlines
          .whereType<ClickCountRun>()
          .single;
      expect(cc.count, '1.2k');
    });

    test('普通空格也被 trim', () {
      final result = parser.parse(
        '<p><span class="click-count">  5  </span></p>',
      );
      final cc = (result[0] as ParagraphNode).inlines
          .whereType<ClickCountRun>()
          .single;
      expect(cc.count, '5');
    });

    test('空 count → 降级展平,不产 ClickCountRun', () {
      final result = parser.parse(
        '<p>x<span class="click-count">   </span>y</p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<ClickCountRun>(), isEmpty);
    });

    test('多个 click-count 各自独立', () {
      final result = parser.parse(
        '<p>'
        '<span class="click-count">10</span>'
        '<span class="click-count">20</span>'
        '<span class="click-count">30</span>'
        '</p>',
      );
      final ccs = (result[0] as ParagraphNode).inlines
          .whereType<ClickCountRun>()
          .toList();
      expect(ccs.map((c) => c.count), ['10', '20', '30']);
    });

    test('非 click-count 的 span 不识别', () {
      final result = parser.parse('<p><span>纯 span</span></p>');
      expect(
        (result[0] as ParagraphNode).inlines.whereType<ClickCountRun>(),
        isEmpty,
      );
    });

    test('链接后跟 click-count(典型 _injectClickCounts 形态)', () {
      final result = parser.parse(
        '<p><a href="/x">链接</a> <span class="click-count">99</span></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<LinkRun>(), hasLength(1));
      expect(p.inlines.whereType<ClickCountRun>(), hasLength(1));
    });

    test('ClickCountRun ==/hashCode 按 count', () {
      const a = ClickCountRun('42');
      const b = ClickCountRun('42');
      const c = ClickCountRun('43');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('countImageRuns 不计 ClickCountRun', () {
      final result = parser.parse(
        '<p><img src="a.png"><span class="click-count">5</span></p>',
      );
      expect(countImageRuns(result), 1);
    });
  });
}

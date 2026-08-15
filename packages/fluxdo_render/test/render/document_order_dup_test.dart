/// 回归:重复内容的 li 必须拿到**不同**的 docOrder。
///
/// ListItem/TextRun 都是值相等(ListItem 无 id 字段),assignDocumentOrder
/// 若用普通 map(按 ==/hashCode)会让内容相同的两个 li 碰撞成同一条目 →
/// 共享同一 docOrder → 选区范围判定把前一项排除在外(高亮跳项)。
/// 见:书单帖 #2/#12 均为「我的女友来自未来」,选 1~6 时第 2 项不高亮。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';
import 'package:fluxdo_render/src/render/document_order.dart';

void main() {
  test('重复文本 li:docOrder 互不相同且随文档序单调递增', () {
    final nodes = ParagraphParser().parse('''
<ol>
<li>不许没收我的人籍</li>
<li>我的女友来自未来</li>
<li>恋爱净化协议</li>
<li>我的女友来自未来</li>
</ol>
''');
    final list = nodes.whereType<ListNode>().single;
    expect(list.items, hasLength(4));
    // 值相等前提(碰撞条件确实存在,防未来模型改动让本测试失去意义)
    expect(
      list.items[1] == list.items[3],
      isTrue,
      reason: '重复文本 li 应值相等(这是本回归防御的碰撞前提)',
    );

    final orders = assignDocumentOrder(nodes);
    final o = [for (final item in list.items) orders[item]];
    expect(
      o.every((v) => v != null),
      isTrue,
      reason: '每个 li 都应有独立 docOrder 条目',
    );
    expect(o.toSet().length, o.length, reason: '重复文本 li 不得共享 docOrder(否则选区跳项)');
    for (var i = 1; i < o.length; i++) {
      expect(o[i]! > o[i - 1]!, isTrue, reason: 'docOrder 应随文档序单调递增');
    }
  });

  test('重复段落/重复嵌套子列表同样不碰撞', () {
    final nodes = ParagraphParser().parse('''
<p>同一句话</p>
<p>同一句话</p>
<ul>
<li>甲<ul><li>子</li></ul></li>
<li>甲<ul><li>子</li></ul></li>
</ul>
''');
    final orders = assignDocumentOrder(nodes);
    final ps = nodes.whereType<ParagraphNode>().toList();
    final list = nodes.whereType<ListNode>().single;
    final ids = <int?>[
      for (final p in ps) orders[p],
      for (final item in list.items) orders[item],
      for (final item in list.items) orders[item.children!.single],
    ];
    expect(ids.every((v) => v != null), isTrue);
    expect(ids.toSet().length, ids.length, reason: '任何重复内容节点都不得共享 docOrder');
  });
}

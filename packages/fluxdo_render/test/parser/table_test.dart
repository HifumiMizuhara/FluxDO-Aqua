import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser table 识别', () {
    test('thead + tbody 基础形态', () {
      final result = parser.parse(
        '<table>'
        '<thead><tr><th>A</th><th>B</th></tr></thead>'
        '<tbody><tr><td>1</td><td>2</td></tr></tbody>'
        '</table>',
      );
      expect(result, hasLength(1));
      final t = result[0] as TableNode;
      expect(t.hasHeader, isTrue);
      expect(t.columnCount, 2);
      expect(t.rows, hasLength(2)); // header + 1 body
      expect(t.rows[0][0].isHeader, isTrue);
      expect(t.rows[1][0].isHeader, isFalse);
    });

    test('裸 tr(无 thead/tbody)→ hasHeader=false 全 body', () {
      final result = parser.parse(
        '<table>'
        '<tr><td>a</td><td>b</td></tr>'
        '<tr><td>c</td><td>d</td></tr>'
        '</table>',
      );
      final t = result[0] as TableNode;
      expect(t.hasHeader, isFalse);
      expect(t.rows, hasLength(2));
      for (final row in t.rows) {
        for (final cell in row) {
          expect(cell.isHeader, isFalse);
        }
      }
    });

    test('cell 内 inline 样式 → 走 _parseBlocks 保留', () {
      final result = parser.parse(
        '<table><tbody><tr>'
        '<td><strong>加粗</strong></td>'
        '<td><a href="https://x">链接</a></td>'
        '</tr></tbody></table>',
      );
      final t = result[0] as TableNode;
      // 每个 cell 应有 1 个 ParagraphNode
      final p0 = t.rows[0][0].children[0] as ParagraphNode;
      expect(p0.inlines.whereType<StrongRun>(), hasLength(1));
      final p1 = t.rows[0][1].children[0] as ParagraphNode;
      expect(p1.inlines.whereType<LinkRun>(), hasLength(1));
    });

    test('columnCount = max(row.length)', () {
      final result = parser.parse(
        '<table>'
        '<thead><tr><th>A</th><th>B</th></tr></thead>'
        '<tbody>'
        '<tr><td>1</td></tr>'
        '<tr><td>2</td><td>3</td><td>4</td></tr>'
        '</tbody></table>',
      );
      final t = result[0] as TableNode;
      expect(t.columnCount, 3);
    });

    test('thead 内 td 也算 header(forceHeader)', () {
      final result = parser.parse(
        '<table>'
        '<thead><tr><td>X</td></tr></thead>'
        '<tbody><tr><td>1</td></tr></tbody>'
        '</table>',
      );
      final t = result[0] as TableNode;
      expect(t.rows[0][0].isHeader, isTrue);
    });

    test('空表(无 tr)→ null,不产 TableNode', () {
      final result = parser.parse('<table></table>');
      expect(result.whereType<TableNode>(), isEmpty);
    });

    test('countImageRuns 递归 cell.children 计图', () {
      final result = parser.parse(
        '<p><img src="outside.png"></p>'
        '<table><tbody>'
        '<tr><td><img src="cell1.png"></td><td><img src="cell2.png"></td></tr>'
        '</tbody></table>',
      );
      // outside + cell1 + cell2 = 3
      expect(countImageRuns(result), 3);
    });

    test('id 唯一(多个 table)', () {
      final result = parser.parse(
        '<table><tbody><tr><td>a</td></tr></tbody></table>'
        '<table><tbody><tr><td>b</td></tr></tbody></table>',
      );
      expect(result, hasLength(2));
      final t1 = result[0] as TableNode;
      final t2 = result[1] as TableNode;
      expect(t1.id, isNot(t2.id));
    });

    test('TableCellData ==/hashCode 按 children + isHeader', () {
      const c1 = TableCellData(
        children: [
          ParagraphNode(id: 'b_0', inlines: [TextRun('x')]),
        ],
        isHeader: true,
      );
      const c2 = TableCellData(
        children: [
          ParagraphNode(id: 'b_99', inlines: [TextRun('x')]),
        ],
        isHeader: true,
      );
      expect(c1, c2); // id 不参与 == (ParagraphNode 同理)
      expect(c1.hashCode, c2.hashCode);
    });

    test('cell 内嵌套 block(list)→ children 含 ListNode', () {
      final result = parser.parse(
        '<table><tbody><tr><td>'
        '<ul><li>项一</li><li>项二</li></ul>'
        '</td></tr></tbody></table>',
      );
      final t = result[0] as TableNode;
      expect(t.rows[0][0].children.whereType<ListNode>(), hasLength(1));
    });

    test('row 单元格少于 columnCount 时不补 cell(渲染层负责补 SizedBox)', () {
      final result = parser.parse(
        '<table>'
        '<thead><tr><th>A</th><th>B</th></tr></thead>'
        '<tbody><tr><td>x</td></tr></tbody>'
        '</table>',
      );
      final t = result[0] as TableNode;
      // 数据模型不补 cell;rows[1] 只有 1 个 cell
      expect(t.rows[1].length, 1);
      expect(t.columnCount, 2);
    });

    test('div.md-table 包裹层透明拆壳 → 内部 table 正常识别', () {
      // Discourse markdown 真实 cooked 形态:<div class="md-table"><table>
      final result = parser.parse(
        '<div class="md-table">'
        '<table>'
        '<thead><tr><th>序号</th><th>名称</th></tr></thead>'
        '<tbody><tr><td>1</td><td>GitHub</td></tr></tbody>'
        '</table>'
        '</div>',
      );
      // 必须产出 TableNode,而不是被展平成纯文本 ParagraphNode
      expect(result.whereType<TableNode>(), hasLength(1));
      expect(result.whereType<ParagraphNode>(), isEmpty);
      final t = result.whereType<TableNode>().single;
      expect(t.hasHeader, isTrue);
      expect(t.columnCount, 2);
      expect(t.rows, hasLength(2));
    });
  });
}

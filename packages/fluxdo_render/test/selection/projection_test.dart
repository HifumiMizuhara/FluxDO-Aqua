import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/selection/projection.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';

void main() {
  group('RenderTextProjection.project', () {
    // 模拟 "Hi" + emoji(:heart:) + "yo" 的映射表:
    // 渲染偏移: H=0 i=1 ￼=2 y=3 o=4 → renderLength 5
    final proj = RenderTextProjection([
      const ProjectionEntry(
        renderStart: 0,
        renderLen: 2,
        logicalText: 'Hi',
        kind: ProjectionKind.text,
      ),
      const ProjectionEntry(
        renderStart: 2,
        renderLen: 1,
        logicalText: ':heart:',
        kind: ProjectionKind.emoji,
      ),
      const ProjectionEntry(
        renderStart: 3,
        renderLen: 2,
        logicalText: 'yo',
        kind: ProjectionKind.text,
      ),
    ]);

    test('renderLength 取末条 renderEnd', () {
      expect(proj.renderLength, 5);
    });

    test('全区间投影 = Hi:heart:yo', () {
      expect(proj.projectAll(), 'Hi:heart:yo');
    });

    test('纯文本部分切片', () {
      expect(proj.project(0, 2), 'Hi');
      expect(proj.project(1, 2), 'i');
      expect(proj.project(3, 5), 'yo');
      expect(proj.project(3, 4), 'y');
    });

    test('占位符原子:相交即整条 :heart:', () {
      // 只碰到 ￼(2..3)→ 整条
      expect(proj.project(2, 3), ':heart:');
      // 从 i 跨到 ￼ 一半(其实 ￼ 不可切)→ i + 整条 emoji
      expect(proj.project(1, 3), 'i:heart:');
      // ￼ 到 y → 整条 emoji + y
      expect(proj.project(2, 4), ':heart:y');
    });

    test('跨占位符:Hi + emoji + yo', () {
      expect(proj.project(0, 5), 'Hi:heart:yo');
      expect(proj.project(1, 4), 'i:heart:y');
    });

    test('越界自动 clamp', () {
      expect(proj.project(-5, 100), 'Hi:heart:yo');
      expect(proj.project(3, 100), 'yo');
    });

    test('start >= end 返回空串', () {
      expect(proj.project(2, 2), '');
      // 入参反向自动 swap → 等价正向区间
      expect(proj.project(4, 1), proj.project(1, 4));
    });

    test('空映射表', () {
      expect(RenderTextProjection.empty.projectAll(), '');
      expect(RenderTextProjection.empty.renderLength, 0);
    });

    test('空 logicalText 占位符(空名 emoji)不贡献文本', () {
      final p = RenderTextProjection([
        const ProjectionEntry(
          renderStart: 0,
          renderLen: 1,
          logicalText: 'A',
          kind: ProjectionKind.text,
        ),
        const ProjectionEntry(
          renderStart: 1,
          renderLen: 1,
          logicalText: '',
          kind: ProjectionKind.emoji,
        ),
        const ProjectionEntry(
          renderStart: 2,
          renderLen: 1,
          logicalText: 'B',
          kind: ProjectionKind.text,
        ),
      ]);
      expect(p.projectAll(), 'AB');
      expect(p.project(1, 2), ''); // 只选空 emoji
    });

    test('clickCount 排除(logicalText 空)', () {
      final p = RenderTextProjection([
        const ProjectionEntry(
          renderStart: 0,
          renderLen: 3,
          logicalText: '链接文',
          kind: ProjectionKind.text,
        ),
        const ProjectionEntry(
          renderStart: 3,
          renderLen: 1,
          logicalText: '',
          kind: ProjectionKind.clickCount,
        ),
      ]);
      // clickCount 不进文本
      expect(p.project(0, 4), p.project(0, 3));
      expect(p.project(0, 4), '链接文');
    });

    test('isAtomic 判定', () {
      expect(
        const ProjectionEntry(
          renderStart: 0,
          renderLen: 1,
          logicalText: ':x:',
          kind: ProjectionKind.emoji,
        ).isAtomic,
        isTrue,
      );
      expect(
        const ProjectionEntry(
          renderStart: 0,
          renderLen: 2,
          logicalText: 'ab',
          kind: ProjectionKind.text,
        ).isAtomic,
        isFalse,
      );
      expect(
        const ProjectionEntry(
          renderStart: 0,
          renderLen: 1,
          logicalText: '\n',
          kind: ProjectionKind.lineBreak,
        ).isAtomic,
        isFalse,
      );
    });
  });

  group('DocumentSelection / DocumentPosition', () {
    const b0 = SelectableBlockId(0);
    const b1 = SelectableBlockId(1);

    test('SelectableBlockId == 按 seq', () {
      expect(
        const SelectableBlockId(3) ==
            const SelectableBlockId(3, debugLabel: 'x'),
        isTrue,
      );
      expect(const SelectableBlockId(3) == const SelectableBlockId(4), isFalse);
    });

    test('isCollapsed', () {
      const pos = DocumentPosition(blockId: b0, renderOffset: 5);
      expect(
        const DocumentSelection(base: pos, extent: pos).isCollapsed,
        isTrue,
      );
      expect(
        const DocumentSelection(
          base: DocumentPosition(blockId: b0, renderOffset: 1),
          extent: DocumentPosition(blockId: b0, renderOffset: 3),
        ).isCollapsed,
        isFalse,
      );
    });

    test('isSingleBlock', () {
      expect(
        const DocumentSelection(
          base: DocumentPosition(blockId: b0, renderOffset: 0),
          extent: DocumentPosition(blockId: b0, renderOffset: 3),
        ).isSingleBlock,
        isTrue,
      );
      expect(
        const DocumentSelection(
          base: DocumentPosition(blockId: b0, renderOffset: 0),
          extent: DocumentPosition(blockId: b1, renderOffset: 3),
        ).isSingleBlock,
        isFalse,
      );
    });
  });
}

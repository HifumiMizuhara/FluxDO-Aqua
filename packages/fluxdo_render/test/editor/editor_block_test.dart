/// 块模型 v2 专项测试:孤岛选区语义、pending marks、块命令语义表。
library;

import 'dart:ui' show TextRange;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/node/node.dart';

TextBlock tb(
  String id,
  String text, {
  TextBlockKind kind = TextBlockKind.paragraph,
  int headingLevel = 1,
  bool ordered = false,
  int depth = 0,
  int quoteDepth = 0,
}) => TextBlock(
  id: id,
  content: EditableTextContent(text: text),
  kind: kind,
  headingLevel: headingLevel,
  ordered: ordered,
  depth: depth,
  quoteDepth: quoteDepth,
);

IslandBlock island(String id) => IslandBlock(
  id: id,
  node: const CodeBlockNode(id: 'b_x', code: 'x = 1', language: 'py'),
);

void caretAt(EditorState s, String blockId, int offset) {
  s.updateSelection(
    EditorSelection.collapsed(EditorPosition(blockId: blockId, offset: offset)),
  );
}

void main() {
  group('孤岛选区语义', () {
    EditorState makeDoc() => EditorState(
      blocks: [tb('e_0', 'aaa'), island('e_1'), tb('e_2', 'bbb')],
    );

    test('前段尾退格(deleteForward 对称):两段式 —— 第一次整选岛', () {
      final s = makeDoc();
      caretAt(s, 'e_2', 0);
      s.backspace();
      expect(
        s.selection!.base,
        const EditorPosition(blockId: 'e_1', offset: 0),
      );
      expect(
        s.selection!.extent,
        const EditorPosition(blockId: 'e_1', offset: 1),
      );
      expect(s.blocks.length, 3, reason: '第一次退格只选中,不删');
      // 第二次退格 → 删岛
      s.backspace();
      expect(s.blocks.length, 2);
      expect(s.blocks.whereType<IslandBlock>(), isEmpty);
    });

    test('deleteForward 段尾遇岛:同样两段式', () {
      final s = makeDoc();
      caretAt(s, 'e_0', 3);
      s.deleteForward();
      expect(s.selection!.isCollapsed, false);
      expect(s.selection!.base.blockId, 'e_1');
      s.deleteForward();
      expect(s.blocks.whereType<IslandBlock>(), isEmpty);
    });

    test('水平移动:一步整选岛,再一步落另一侧', () {
      final s = makeDoc();
      caretAt(s, 'e_0', 3);
      s.moveCaretHorizontal(1);
      expect(s.selection!.isCollapsed, false);
      expect(s.selection!.base.blockId, 'e_1');
      s.moveCaretHorizontal(1);
      expect(
        s.selection,
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_2', offset: 0),
        ),
      );
      // 反向
      s.moveCaretHorizontal(-1);
      expect(s.selection!.isCollapsed, false);
      s.moveCaretHorizontal(-1);
      expect(
        s.selection,
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 3),
        ),
      );
    });

    test('跨岛选区删除:岛计入(端点四象限 from@0/to@1)', () {
      final s = makeDoc();
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 1),
          extent: EditorPosition(blockId: 'e_2', offset: 1),
        ),
      );
      s.deleteSelection();
      expect(s.blocks.length, 1);
      expect((s.blocks[0] as TextBlock).content.text, 'abb');
    });

    test('选区止于岛前(to=island@0):岛保留', () {
      final s = makeDoc();
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 1),
          extent: EditorPosition(blockId: 'e_1', offset: 0),
        ),
      );
      s.deleteSelection();
      expect(s.blocks.whereType<IslandBlock>().length, 1);
      expect((s.blocks[0] as TextBlock).content.text, 'a');
    });

    test('选区起于岛后(from=island@1):岛保留', () {
      final s = makeDoc();
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_1', offset: 1),
          extent: EditorPosition(blockId: 'e_2', offset: 2),
        ),
      );
      s.deleteSelection();
      expect(s.blocks.whereType<IslandBlock>().length, 1);
      expect((s.blocks[2] as TextBlock).content.text, 'b');
    });

    test('全岛文档兜底:删光文本块自动补空段', () {
      final s = EditorState(blocks: [tb('e_0', 'x'), island('e_1')]);
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 0),
          extent: EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      s.deleteSelection();
      expect(s.blocks.whereType<TextBlock>(), isNotEmpty);
    });

    test('岛上回车:offset 1 岛后建段 / offset 0 岛前建段', () {
      final s = makeDoc();
      caretAt(s, 'e_1', 1);
      s.splitBlock();
      expect(s.blocks.length, 4);
      expect(s.blocks[2], isA<TextBlock>());
      expect(s.selection!.extent.blockId, s.blocks[2].id);

      final s2 = makeDoc();
      caretAt(s2, 'e_1', 0);
      s2.splitBlock();
      expect(s2.blocks[1], isA<TextBlock>());
      expect((s2.blocks[1] as TextBlock).content.text, '');
    });
  });

  group('pending marks', () {
    test('折叠 toggle → 下次输入生效并清除', () {
      final s = EditorState.fromTexts(const ['abc']);
      caretAt(s, s.blocks[0].id, 3);
      s.toggleMark(MarkKind.strong);
      expect(s.pendingMarks, {MarkKind.strong});
      s.insertText('X');
      final c = (s.blocks[0] as TextBlock).content;
      expect(c.text, 'abcX');
      expect(c.isRangeFullyMarked(3, 4, MarkKind.strong), true);
      expect(s.pendingMarks, isNull);
    });

    test('toggle 两次抵消', () {
      final s = EditorState.fromTexts(const ['abc']);
      caretAt(s, s.blocks[0].id, 3);
      s.toggleMark(MarkKind.em);
      s.toggleMark(MarkKind.em);
      expect(s.pendingMarks, isEmpty);
      s.insertText('X');
      expect(
        (s.blocks[0] as TextBlock).content.isRangeFullyMarked(
          3,
          4,
          MarkKind.em,
        ),
        false,
      );
    });

    test('选区移动清 pending', () {
      final s = EditorState.fromTexts(const ['abc']);
      caretAt(s, s.blocks[0].id, 3);
      s.toggleMark(MarkKind.strong);
      caretAt(s, s.blocks[0].id, 1);
      expect(s.pendingMarks, isNull);
    });

    test('粗体中间光标 toggle:pending 从当前样式出发(关闭粗体)', () {
      final s = EditorState.fromTexts(const ['abc']);
      final id = s.blocks[0].id;
      s.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: id, offset: 0),
          extent: EditorPosition(blockId: id, offset: 3),
        ),
      );
      s.toggleMark(MarkKind.strong); // 全加粗
      caretAt(s, id, 2);
      s.toggleMark(MarkKind.strong); // 关闭
      expect(s.pendingMarks, isEmpty);
      s.insertText('X');
      final c = (s.blocks[0] as TextBlock).content;
      expect(
        c.isRangeFullyMarked(2, 3, MarkKind.strong),
        false,
        reason: '插入的 X 不带粗体',
      );
    });

    test('imeReplace 命中锚点:pending 应用(composing 中保留)', () {
      final s = EditorState.fromTexts(const ['abc']);
      final id = s.blocks[0].id;
      caretAt(s, id, 3);
      s.toggleMark(MarkKind.strong);
      // composing 阶段
      s.imeReplace(
        id,
        3,
        3,
        'n',
        caretOffset: 4,
        composing: const TextRange(start: 3, end: 4),
      );
      expect(s.pendingMarks, isNotNull, reason: 'composing 中保留');
      var c = (s.blocks[0] as TextBlock).content;
      expect(c.isRangeFullyMarked(3, 4, MarkKind.strong), true);
      // 上屏(composing 清)
      s.imeReplace(id, 3, 4, '你', caretOffset: 4);
      expect(s.pendingMarks, isNull);
      c = (s.blocks[0] as TextBlock).content;
      expect(c.isRangeFullyMarked(3, 4, MarkKind.strong), true);
    });
  });

  group('选区 toggle mark', () {
    test('单块选区加粗/还原', () {
      final s = EditorState.fromTexts(const ['abcdef']);
      final id = s.blocks[0].id;
      s.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: id, offset: 1),
          extent: EditorPosition(blockId: id, offset: 4),
        ),
      );
      s.toggleMark(MarkKind.strong);
      var c = (s.blocks[0] as TextBlock).content;
      expect(c.isRangeFullyMarked(1, 4, MarkKind.strong), true);
      s.toggleMark(MarkKind.strong);
      c = (s.blocks[0] as TextBlock).content;
      expect(c.marks.where((m) => m.kind == MarkKind.strong), isEmpty);
    });
  });

  group('块命令语义表', () {
    test('heading 尾回车 → 新块是段落;中部回车 → 两半同级', () {
      final s = EditorState(
        blocks: [
          tb('e_0', '标题文字', kind: TextBlockKind.heading, headingLevel: 2),
        ],
      );
      caretAt(s, 'e_0', 4);
      s.splitBlock();
      expect((s.blocks[1] as TextBlock).isParagraph, true);

      final s2 = EditorState(
        blocks: [
          tb('e_0', '标题文字', kind: TextBlockKind.heading, headingLevel: 2),
        ],
      );
      caretAt(s2, 'e_0', 2);
      s2.splitBlock();
      final second = s2.blocks[1] as TextBlock;
      expect(second.isHeading, true);
      expect(second.headingLevel, 2);
    });

    test('listItem 非空回车:新块同属性', () {
      final s = EditorState(
        blocks: [
          tb(
            'e_0',
            'item',
            kind: TextBlockKind.listItem,
            ordered: true,
            depth: 1,
          ),
        ],
      );
      caretAt(s, 'e_0', 4);
      s.splitBlock();
      final second = s.blocks[1] as TextBlock;
      expect(second.isListItem, true);
      expect(second.ordered, true);
      expect(second.depth, 1);
    });

    test('空 listItem 回车:depth>0 逐级退;depth==0 转段落(不分裂)', () {
      final s = EditorState(
        blocks: [tb('e_0', '', kind: TextBlockKind.listItem, depth: 1)],
      );
      caretAt(s, 'e_0', 0);
      s.splitBlock();
      expect(s.blocks.length, 1);
      expect((s.blocks[0] as TextBlock).depth, 0);
      expect((s.blocks[0] as TextBlock).isListItem, true);
      s.splitBlock();
      expect((s.blocks[0] as TextBlock).isParagraph, true);
    });

    test('quote 内空段回车:退出引用', () {
      final s = EditorState(blocks: [tb('e_0', '', quoteDepth: 1)]);
      caretAt(s, 'e_0', 0);
      s.splitBlock();
      expect(s.blocks.length, 1);
      expect((s.blocks[0] as TextBlock).quoteDepth, 0);
    });

    test('listItem 块首退格:先降级不合并', () {
      final s = EditorState(
        blocks: [
          tb('e_0', 'aaa'),
          tb('e_1', 'item', kind: TextBlockKind.listItem, depth: 1),
        ],
      );
      caretAt(s, 'e_1', 0);
      s.backspace();
      expect(s.blocks.length, 2);
      expect((s.blocks[1] as TextBlock).depth, 0);
      s.backspace();
      expect((s.blocks[1] as TextBlock).isParagraph, true);
      s.backspace();
      expect(s.blocks.length, 1, reason: '降到段落后才合并');
    });

    test('quote 内块首退格:先退引用', () {
      final s = EditorState(
        blocks: [tb('e_0', 'aaa'), tb('e_1', 'quoted', quoteDepth: 2)],
      );
      caretAt(s, 'e_1', 0);
      s.backspace();
      expect((s.blocks[1] as TextBlock).quoteDepth, 1);
      s.backspace();
      expect((s.blocks[1] as TextBlock).quoteDepth, 0);
      s.backspace();
      expect(s.blocks.length, 1);
    });

    test('toggleHeading:全同级还原,否则统一', () {
      final s = EditorState.fromTexts(const ['a', 'b']);
      s.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: s.blocks[0].id, offset: 0),
          extent: EditorPosition(blockId: s.blocks[1].id, offset: 1),
        ),
      );
      s.toggleHeading(2);
      expect(s.blocks.whereType<TextBlock>().every((b) => b.isHeading), true);
      s.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: s.blocks[0].id, offset: 0),
          extent: EditorPosition(blockId: s.blocks[1].id, offset: 1),
        ),
      );
      s.toggleHeading(2);
      expect(s.blocks.whereType<TextBlock>().every((b) => b.isParagraph), true);
    });

    test('toggleList + Tab 缩进上限 + Shift-Tab 退出', () {
      final s = EditorState.fromTexts(const ['a', 'b']);
      s.updateSelection(
        EditorSelection(
          base: EditorPosition(blockId: s.blocks[0].id, offset: 0),
          extent: EditorPosition(blockId: s.blocks[1].id, offset: 1),
        ),
      );
      s.toggleList(ordered: false);
      expect(s.blocks.whereType<TextBlock>().every((b) => b.isListItem), true);

      // 第二项缩进:上限 = 前项 depth+1 = 1
      caretAt(s, s.blocks[1].id, 0);
      s.indentListItem();
      expect((s.blocks[1] as TextBlock).depth, 1);
      s.indentListItem();
      expect((s.blocks[1] as TextBlock).depth, 1, reason: '超上限不动');

      // 首项缩进:无前项 listItem,上限 0
      caretAt(s, s.blocks[0].id, 0);
      s.indentListItem();
      expect((s.blocks[0] as TextBlock).depth, 0);

      // Shift-Tab 退出
      caretAt(s, s.blocks[1].id, 0);
      s.outdentListItem();
      expect((s.blocks[1] as TextBlock).depth, 0);
      s.outdentListItem();
      expect((s.blocks[1] as TextBlock).isParagraph, true);
    });

    test('toggleQuote 往返', () {
      final s = EditorState.fromTexts(const ['a']);
      caretAt(s, s.blocks[0].id, 0);
      s.toggleQuote();
      expect((s.blocks[0] as TextBlock).quoteDepth, 1);
      caretAt(s, s.blocks[0].id, 0);
      s.toggleQuote();
      expect((s.blocks[0] as TextBlock).quoteDepth, 0);
    });

    test('insertAtom:光标处插原子,光标 +1', () {
      const emoji = EmojiRun(name: 'heart', url: 'u');
      final s = EditorState.fromTexts(const ['ab']);
      caretAt(s, s.blocks[0].id, 1);
      s.insertAtom(emoji);
      final c = (s.blocks[0] as TextBlock).content;
      expect(c.text, 'a${kAtomChar}b');
      expect(c.atoms[1], same(emoji));
      expect(s.selection!.extent.offset, 2);
    });

    test('insertIslandAfter:插岛并选中其后端', () {
      final s = EditorState.fromTexts(const ['a']);
      s.insertIslandAfter(s.blocks[0].id, const HorizontalRuleNode(id: 'b_hr'));
      expect(s.blocks[1], isA<IslandBlock>());
      expect(s.selection!.extent.blockId, s.blocks[1].id);
    });
  });
}

/// 剪贴板原语测试:copySelectionAsBlocks / copySelectionAsMarkdown /
/// pasteBlocks / pastePlainText。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/node/node.dart';

EditorState buildState(List<EditorBlock> blocks) {
  final s = EditorState(blocks: blocks);
  addTearDown(s.dispose);
  return s;
}

TextBlock tb(
  String id,
  String text, {
  List<MarkSpan> marks = const [],
  TextBlockKind kind = TextBlockKind.paragraph,
  bool ordered = false,
  int depth = 0,
  int quoteDepth = 0,
}) => TextBlock(
  id: id,
  content: EditableTextContent(text: text, marks: marks),
  kind: kind,
  ordered: ordered,
  depth: depth,
  quoteDepth: quoteDepth,
);

void main() {
  group('copySelectionAsBlocks', () {
    test('单块中段:slice 保留 marks 平移', () {
      final s = buildState([
        tb(
          'e_0',
          'abcdef',
          marks: const [MarkSpan(start: 2, end: 5, kind: MarkKind.strong)],
        ),
      ]);
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 1),
          extent: EditorPosition(blockId: 'e_0', offset: 5),
        ),
      );
      final frag = s.copySelectionAsBlocks();
      expect(frag, hasLength(1));
      final t = frag.single as TextBlock;
      expect(t.content.text, 'bcde');
      expect(
        t.content.marks.single,
        const MarkSpan(start: 1, end: 4, kind: MarkKind.strong),
      );
    });

    test('跨块:首尾截断,中间整块;岛端点四象限', () {
      const island = IslandBlock(
        id: 'e_isl',
        node: HorizontalRuleNode(id: 'b_hr'),
      );
      final s = buildState([tb('e_0', 'AAAA'), island, tb('e_2', 'BBBB')]);
      // 从 A 的中部选到 B 的中部:岛整颗计入
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 2),
          extent: EditorPosition(blockId: 'e_2', offset: 2),
        ),
      );
      final frag = s.copySelectionAsBlocks();
      expect(frag, hasLength(3));
      expect((frag[0] as TextBlock).content.text, 'AA');
      expect(frag[1], isA<IslandBlock>());
      expect((frag[2] as TextBlock).content.text, 'BB');
      // 选区止于岛前(offset 0):岛不计入
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 0),
          extent: EditorPosition(blockId: 'e_isl', offset: 0),
        ),
      );
      final frag2 = s.copySelectionAsBlocks();
      expect(frag2, hasLength(1));
      expect((frag2[0] as TextBlock).content.text, 'AAAA');
    });

    test('折叠选区:空表;markdown 为空串', () {
      final s = buildState([tb('e_0', 'abc')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      expect(s.copySelectionAsBlocks(), isEmpty);
      expect(s.copySelectionAsMarkdown(), '');
    });

    test('markdown:块属性保留(列表/引用/mark)', () {
      final s = buildState([
        tb('e_0', '甲', kind: TextBlockKind.listItem),
        tb('e_1', '乙', kind: TextBlockKind.listItem),
      ]);
      s.selectAll();
      expect(s.copySelectionAsMarkdown(), '- 甲\n- 乙');
    });
  });

  group('pasteBlocks', () {
    test('单文本块:内联并入,不分裂宿主', () {
      final s = buildState([tb('e_0', 'ab')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      s.pasteBlocks([
        tb(
          'p_0',
          'XY',
          marks: const [MarkSpan(start: 0, end: 2, kind: MarkKind.em)],
        ),
      ]);
      expect(s.blocks, hasLength(1));
      final t = s.blocks.single as TextBlock;
      expect(t.content.text, 'aXYb');
      expect(
        t.content.marks.single,
        const MarkSpan(start: 1, end: 3, kind: MarkKind.em),
      );
      expect(s.selection!.extent.offset, 3);
    });

    test('多块:宿主劈开,纯段落首块并前半;列表尾块整块插入', () {
      final s = buildState([tb('e_0', 'ab')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      s.pasteBlocks([
        tb('p_0', 'X'),
        tb('p_1', 'Y', kind: TextBlockKind.listItem),
      ]);
      // 列表项不与宿主后半内联合并(M5:带块属性的块整块插入,
      // 否则粘贴的列表会吞掉宿主文字);宿主后半独立成段
      expect(s.blocks, hasLength(3));
      expect((s.blocks[0] as TextBlock).content.text, 'aX');
      final li = s.blocks[1] as TextBlock;
      expect(li.content.text, 'Y');
      expect(li.isListItem, isTrue);
      final tail = s.blocks[2] as TextBlock;
      expect(tail.content.text, 'b');
      expect(s.selection!.extent.blockId, tail.id);
      expect(s.selection!.extent.offset, 0);
    });

    test('单岛片段:段落绕岛分裂', () {
      final s = buildState([tb('e_0', 'ab')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      s.pasteBlocks([
        const IslandBlock(
          id: 'p_i',
          node: HorizontalRuleNode(id: 'b_hr'),
        ),
      ]);
      expect(s.blocks, hasLength(3));
      expect((s.blocks[0] as TextBlock).content.text, 'a');
      expect(s.blocks[1], isA<IslandBlock>());
      expect((s.blocks[2] as TextBlock).content.text, 'b');
      // 粘贴片段的 id 重发(不与来源撞)
      expect(s.blocks[1].id, isNot('p_i'));
    });

    test('非折叠选区:先删再贴', () {
      final s = buildState([tb('e_0', 'abcd')]);
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 1),
          extent: EditorPosition(blockId: 'e_0', offset: 3),
        ),
      );
      s.pasteBlocks([tb('p_0', 'Z')]);
      expect((s.blocks.single as TextBlock).content.text, 'aZd');
    });

    test('自我复制粘贴:undo 一步回原状', () {
      final s = buildState([tb('e_0', 'hello')]);
      s.selectAll();
      final frag = s.copySelectionAsBlocks();
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 5),
        ),
      );
      s.pasteBlocks(frag);
      expect((s.blocks.single as TextBlock).content.text, 'hellohello');
      s.undo();
      expect((s.blocks.single as TextBlock).content.text, 'hello');
    });

    test('回归:单块容器片段(插入菜单 [quote] 模板)保留容器帧', () {
      final s = buildState([tb('e_0', '')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 0),
        ),
      );
      s.pasteBlocks([
        TextBlock(
          id: 'p_0',
          content: EditableTextContent(text: '引用内容'),
          containers: const [QuoteCardFrame(groupId: 'g1', username: 'u')],
        ),
      ]);
      // 壳保留 + 空宿主不留孤儿空段 + 壳后有落点空段
      final withCard = s.blocks
          .whereType<TextBlock>()
          .where((b) => b.containers.any((f) => f is QuoteCardFrame))
          .toList();
      expect(withCard, hasLength(1));
      expect(withCard.single.content.text, '引用内容');
      expect(
        (s.blocks.first as TextBlock).containers,
        isNotEmpty,
        reason: '空宿主前半不该留孤儿空段',
      );
      expect(
        (s.blocks.last as TextBlock).containers,
        isEmpty,
        reason: '壳后应有顶层落点空段',
      );
    });

    test('回归:自我复制容器块再粘贴,groupId 重发不吸并', () {
      final s = buildState([
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: '甲'),
          containers: const [QuoteFrame(groupId: 'g1')],
        ),
      ]);
      s.selectAll();
      final frag = s.copySelectionAsBlocks();
      // 光标放块尾粘贴
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      s.pasteBlocks(frag);
      final quoted = s.blocks
          .whereType<TextBlock>()
          .where((b) => b.containers.isNotEmpty)
          .toList();
      expect(quoted.length, greaterThanOrEqualTo(2));
      // 粘贴块的 groupId ≠ 原块(两个独立引用,不合并成一个)
      final ids = quoted.map((b) => b.containers.first.groupId).toSet();
      expect(ids.length, 2);
    });
  });

  group('pastePlainText', () {
    test('双换行分段,单换行段内硬换行', () {
      final s = buildState([tb('e_0', '')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 0),
        ),
      );
      s.pastePlainText('第一段\n还是第一段\n\n第二段');
      expect(s.blocks, hasLength(2));
      expect((s.blocks[0] as TextBlock).content.text, '第一段\n还是第一段');
      expect((s.blocks[1] as TextBlock).content.text, '第二段');
    });

    test('CRLF 归一;FFFC 剥除', () {
      final s = buildState([tb('e_0', '')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 0),
        ),
      );
      s.pastePlainText('a\r\nb￼c');
      expect((s.blocks.single as TextBlock).content.text, 'a\nbc');
    });
  });

  group('replaceIsland(岛源码编辑)', () {
    test('单块替换:re-id,光标落片段末尾', () {
      final s = buildState([
        tb('e_0', 'AA'),
        const IslandBlock(
          id: 'e_isl',
          node: HorizontalRuleNode(id: 'b_hr'),
        ),
        tb('e_2', 'BB'),
      ]);
      s.replaceIsland('e_isl', [tb('p_0', 'XYZ')]);
      expect(s.blocks, hasLength(3));
      final mid = s.blocks[1] as TextBlock;
      expect(mid.content.text, 'XYZ');
      expect(mid.id, isNot('p_0')); // re-id
      expect(s.selection!.extent.blockId, mid.id);
      expect(s.selection!.extent.offset, 3);
    });

    test('多块替换(编辑后 cook 出两块)', () {
      final s = buildState([
        const IslandBlock(
          id: 'e_isl',
          node: HorizontalRuleNode(id: 'b_hr'),
        ),
        tb('e_1', 'tail'),
      ]);
      s.replaceIsland('e_isl', [
        tb('p_0', '甲'),
        const IslandBlock(
          id: 'p_1',
          node: HorizontalRuleNode(id: 'b_hr2'),
        ),
      ]);
      expect(s.blocks, hasLength(3));
      expect((s.blocks[0] as TextBlock).content.text, '甲');
      expect(s.blocks[1], isA<IslandBlock>());
    });

    test('空片段=删岛;undo 恢复', () {
      final s = buildState([
        tb('e_0', 'AA'),
        const IslandBlock(
          id: 'e_isl',
          node: HorizontalRuleNode(id: 'b_hr'),
        ),
      ]);
      s.replaceIsland('e_isl', const []);
      expect(s.blocks, hasLength(1));
      s.undo();
      expect(s.blocks, hasLength(2));
      expect(s.blocks[1], isA<IslandBlock>());
    });

    test('非岛 id / 不存在 id:无操作', () {
      final s = buildState([tb('e_0', 'AA')]);
      s.replaceIsland('e_0', [tb('p_0', 'X')]);
      s.replaceIsland('ghost', [tb('p_0', 'X')]);
      expect((s.blocks.single as TextBlock).content.text, 'AA');
    });
  });
}

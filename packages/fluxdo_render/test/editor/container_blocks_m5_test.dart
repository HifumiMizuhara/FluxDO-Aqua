/// M5-B 容器块测试:doc_converter 容器化双向、编辑语义、序列化分组。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/doc_converter.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

String Function() idGen() {
  var n = 0;
  return () => 'e_${n++}';
}

void main() {
  final parser = ParagraphParser();

  group('容器化导入(可进入,非岛)', () {
    test('quote 卡 → QuoteCardFrame 子块', () {
      final nodes = parser.parse(
        '<aside class="quote" data-username="sam" data-post="2" data-topic="123">'
        '<div class="title">sam:</div>'
        '<blockquote><p>第一段</p><p>第二段</p></blockquote></aside>',
      );
      final doc = blockNodesToDoc(nodes, idGen());
      expect(doc.whereType<IslandBlock>(), isEmpty);
      final tbs = doc.whereType<TextBlock>().toList();
      expect(tbs, hasLength(2));
      final frame = tbs[0].containers.single as QuoteCardFrame;
      expect(frame.username, 'sam');
      expect(frame.postNumber, 2);
      expect(tbs[1].containers.single, frame);
    });

    test('spoiler 块 / details → 各自 Frame', () {
      final spo = blockNodesToDoc(
        parser.parse('<div class="spoiler"><p>秘密</p></div>'),
        idGen(),
      );
      expect((spo.single as TextBlock).containers.single, isA<SpoilerFrame>());

      final det = blockNodesToDoc(
        parser.parse('<details open><summary>标题</summary><p>内容</p></details>'),
        idGen(),
      );
      final f = (det.single as TextBlock).containers.single as DetailsFrame;
      expect(f.summary, '标题');
      expect(f.open, isTrue);
    });

    test('嵌套:quote 卡里嵌纯引用 → 两层栈', () {
      final nodes = parser.parse(
        '<aside class="quote" data-username="bob">'
        '<blockquote><blockquote><p>深层</p></blockquote>'
        '<p>浅层</p></blockquote></aside>',
      );
      final doc = blockNodesToDoc(nodes, idGen());
      final tbs = doc.whereType<TextBlock>().toList();
      expect(tbs[0].containers, hasLength(2)); // card > quote
      expect(tbs[0].containers[0], isA<QuoteCardFrame>());
      expect(tbs[0].containers[1], isA<QuoteFrame>());
      expect(tbs[1].containers, hasLength(1));
    });

    test('容器内含岛内容 → 整棵岛化(零丢失)', () {
      final nodes = parser.parse(
        '<div class="spoiler"><p>文字</p>'
        '<pre><code>code</code></pre></div>',
      );
      final doc = blockNodesToDoc(nodes, idGen());
      expect(doc.whereType<IslandBlock>().length, 1);
      expect((doc.single as IslandBlock).node, isA<SpoilerBlockNode>());
    });

    test('导出重建:分组还原容器树(identity 等价)', () {
      final nodes = parser.parse(
        '<aside class="quote" data-username="sam" data-post="2" data-topic="1">'
        '<blockquote><p>甲</p><p>乙</p></blockquote></aside><p>外部</p>',
      );
      final doc = blockNodesToDoc(nodes, idGen());
      final back = docToBlockNodes(doc);
      expect(back, hasLength(2));
      final card = back[0] as QuoteCardNode;
      expect(card.username, 'sam');
      expect(card.children, hasLength(2));
      expect(back[1], isA<ParagraphNode>());
    });
  });

  group('编辑语义', () {
    EditorState makeState(List<ContainerFrame> containers) {
      final s = EditorState(
        blocks: [
          TextBlock(
            id: 'e_0',
            content: EditableTextContent(text: 'abc'),
            containers: containers,
          ),
        ],
      );
      addTearDown(s.dispose);
      return s;
    }

    test('块首退格:弹出最内层容器', () {
      final s = makeState([
        const QuoteCardFrame(groupId: 'g1', username: 'u'),
        const QuoteFrame(groupId: 'g2'),
      ]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 0),
        ),
      );
      s.backspace();
      var b = s.blocks.single as TextBlock;
      expect(b.containers, hasLength(1));
      expect(b.containers.single, isA<QuoteCardFrame>());
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 0),
        ),
      );
      s.backspace();
      b = s.blocks.single as TextBlock;
      expect(b.containers, isEmpty);
    });

    test('容器内空段回车:逐级退出', () {
      final s = EditorState(
        blocks: [
          TextBlock(
            id: 'e_0',
            content: EditableTextContent.empty,
            containers: const [SpoilerFrame(groupId: 'g1')],
          ),
        ],
      );
      addTearDown(s.dispose);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 0),
        ),
      );
      s.splitBlock();
      expect((s.blocks.single as TextBlock).containers, isEmpty);
    });

    test('容器内回车分裂:新块同容器栈', () {
      final s = makeState([const SpoilerFrame(groupId: 'g_new')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      s.splitBlock();
      expect(s.blocks, hasLength(2));
      expect((s.blocks[1] as TextBlock).containers.single, isA<SpoilerFrame>());
    });

    test('toggleQuote:包/弹 QuoteFrame(保留其他容器)', () {
      final s = makeState([const SpoilerFrame(groupId: 'g_new')]);
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      s.toggleQuote();
      var b = s.blocks.single as TextBlock;
      expect(b.containers, hasLength(2));
      expect(b.containers[0], isA<QuoteFrame>());
      s.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 1),
        ),
      );
      s.toggleQuote();
      b = s.blocks.single as TextBlock;
      expect(b.containers.single, isA<SpoilerFrame>());
    });

    test('wrapInContainer:选区统一包壳', () {
      final s = EditorState(
        blocks: [
          TextBlock(
            id: 'e_0',
            content: EditableTextContent(text: 'a'),
          ),
          TextBlock(
            id: 'e_1',
            content: EditableTextContent(text: 'b'),
          ),
        ],
      );
      addTearDown(s.dispose);
      s.selectAll();
      s.wrapInContainer(const DetailsFrame(groupId: 'gd', summary: 's'));
      for (final b in s.blocks.whereType<TextBlock>()) {
        expect(
          b.containers.single,
          const DetailsFrame(groupId: 'gd', summary: 's'),
        );
      }
    });
  });

  group('序列化分组', () {
    test('quote 卡多段 + 相邻独立容器不合并', () {
      final md = docToMarkdown([
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: '甲'),
          containers: const [
            QuoteCardFrame(
              groupId: 'gA',
              username: 'u',
              postNumber: 1,
              topicId: 2,
            ),
          ],
        ),
        TextBlock(
          id: 'e_1',
          content: EditableTextContent(text: '乙'),
          containers: const [
            QuoteCardFrame(
              groupId: 'gA',
              username: 'u',
              postNumber: 1,
              topicId: 2,
            ),
          ],
        ),
        TextBlock(
          id: 'e_2',
          content: EditableTextContent(text: '丙'),
          containers: const [
            QuoteCardFrame(
              groupId: 'gB',
              username: 'v',
              postNumber: 3,
              topicId: 2,
            ),
          ],
        ),
      ]);
      expect(
        md,
        '[quote="u, post:1, topic:2"]\n甲\n\n乙\n[/quote]\n\n'
        '[quote="v, post:3, topic:2"]\n丙\n[/quote]',
      );
    });

    test('嵌套容器:details 里 spoiler', () {
      final md = docToMarkdown([
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: '双层'),
          containers: const [
            DetailsFrame(groupId: 'gd2', summary: '套娃'),
            SpoilerFrame(groupId: 'gs2'),
          ],
        ),
      ]);
      expect(md, '[details="套娃"]\n[spoiler]\n双层\n[/spoiler]\n[/details]');
    });

    test('quote 内块间 > 前缀空行(容器递归路径)', () {
      final md = docToMarkdown([
        TextBlock(
          id: 'e_0',
          content: EditableTextContent(text: '段一'),
          containers: const [QuoteFrame(groupId: 'gq')],
        ),
        TextBlock(
          id: 'e_1',
          content: EditableTextContent(text: '段二'),
          containers: const [QuoteFrame(groupId: 'gq')],
        ),
      ]);
      expect(md, '> 段一\n>\n> 段二');
    });
  });
}

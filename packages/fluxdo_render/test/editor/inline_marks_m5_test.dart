/// M5 行内 mark(spoilerInline / link)测试:双向转换、序列化、命令。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/node/node.dart';

TextBlock tb(String text, {List<MarkSpan> marks = const []}) => TextBlock(
  id: 'e_t',
  content: EditableTextContent(text: text, marks: marks),
);

void main() {
  group('fromInlines / toInlines 往返', () {
    test('SpoilerRun → spoilerInline mark → SpoilerRun', () {
      final c = EditableTextContent.fromInlines(const [
        TextRun('前 '),
        SpoilerRun(children: [TextRun('秘密')]),
        TextRun(' 后'),
      ]);
      expect(c.text, '前 秘密 后');
      expect(
        c.marks.single,
        const MarkSpan(start: 2, end: 4, kind: MarkKind.spoilerInline),
      );
      final back = c.toInlines();
      expect(back.whereType<SpoilerRun>().length, 1);
    });

    test('LinkRun(href 进 attr)→ link mark → LinkRun', () {
      final c = EditableTextContent.fromInlines(const [
        LinkRun(href: 'https://a.com', children: [TextRun('甲')]),
        LinkRun(href: 'https://b.com', children: [TextRun('乙')]),
      ]);
      expect(c.marks, hasLength(2));
      expect(c.marks[0].attr, 'https://a.com');
      expect(c.marks[1].attr, 'https://b.com');
      // 相邻不同 href 不合并
      final back = c.toInlines();
      final links = back.whereType<LinkRun>().toList();
      expect(links, hasLength(2));
      expect(links[0].href, 'https://a.com');
      expect(links[1].href, 'https://b.com');
    });

    test('链接内嵌样式(粗体链接)双向', () {
      final c = EditableTextContent.fromInlines(const [
        LinkRun(
          href: 'https://x.com',
          children: [
            StrongRun(children: [TextRun('粗链')]),
          ],
        ),
      ]);
      expect(c.marks, hasLength(2)); // strong + link
      final back = c.toInlines();
      final link = back.whereType<LinkRun>().single;
      expect(link.children.single, isA<StrongRun>());
    });

    test('spoiler 内 emoji 原子:阅读态包壳,编辑态裸原子', () {
      final c = EditableTextContent.fromInlines(const [
        SpoilerRun(
          children: [
            TextRun('看'),
            EmojiRun(name: 'smile', url: 'u'),
          ],
        ),
      ]);
      final read = c.toInlines();
      expect(read.whereType<SpoilerRun>().length, greaterThanOrEqualTo(1));
      final editing = c.toInlines(forEditing: true);
      expect(editing.whereType<SpoilerRun>(), isEmpty);
      expect(editing.whereType<EmojiRun>().length, 1);
    });

    test('编辑态渲染:link=着色纯文本;spoiler 交给 painter(不包壳)', () {
      final c = EditableTextContent.fromInlines(const [
        LinkRun(href: 'https://x.com', children: [TextRun('链')]),
        SpoilerRun(children: [TextRun('密')]),
      ]);
      final editing = c.toInlines(forEditing: true);
      expect(editing.whereType<LinkRun>(), isEmpty);
      expect(editing.whereType<SpoilerRun>(), isEmpty);
      // link → ColoredRun;spoiler 底纹由 _SpoilerDecorPainter 按 mark
      // 区间自绘,文本层不再包 ColoredRun
      expect(editing.whereType<ColoredRun>().length, 1);
    });
  });

  group('序列化', () {
    test('link → [text](href);spoiler → [spoiler]…[/spoiler]', () {
      expect(
        docToMarkdown([
          tb(
            '看这里',
            marks: const [
              MarkSpan(
                start: 1,
                end: 3,
                kind: MarkKind.link,
                attr: 'https://x.com',
              ),
            ],
          ),
        ]),
        '看[这里](https://x.com)',
      );
      expect(
        docToMarkdown([
          tb(
            '前密后',
            marks: const [
              MarkSpan(start: 1, end: 2, kind: MarkKind.spoilerInline),
            ],
          ),
        ]),
        '前[spoiler]密[/spoiler]后',
      );
    });

    test('链接文字带样式:[**粗**](url)', () {
      expect(
        docToMarkdown([
          tb(
            '粗',
            marks: const [
              MarkSpan(start: 0, end: 1, kind: MarkKind.strong),
              MarkSpan(
                start: 0,
                end: 1,
                kind: MarkKind.link,
                attr: 'https://x.com',
              ),
            ],
          ),
        ]),
        '[**粗**](https://x.com)',
      );
    });
  });

  group('applyMark(link attr 语义)', () {
    test('同 kind 异 attr 不合并;覆盖旧链接', () {
      var c = EditableTextContent(text: 'abcdef');
      c = c.applyMark(0, 3, MarkKind.link, attr: 'https://a.com');
      c = c.applyMark(3, 6, MarkKind.link, attr: 'https://b.com');
      expect(c.marks, hasLength(2));
      // 覆盖中段:旧的两条被切,新 href 接管 [2,4)
      c = c.applyMark(2, 4, MarkKind.link, attr: 'https://c.com');
      final hrefs = c.marks.map((m) => m.attr).toList();
      expect(
        hrefs,
        containsAll(['https://a.com', 'https://b.com', 'https://c.com']),
      );
      expect(
        c.marks.firstWhere((m) => m.attr == 'https://c.com'),
        const MarkSpan(
          start: 2,
          end: 4,
          kind: MarkKind.link,
          attr: 'https://c.com',
        ),
      );
    });
  });

  group('EditorState 命令', () {
    test('applyLink / removeLink', () {
      final s = EditorState(blocks: [tb('hello')]);
      addTearDown(s.dispose);
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_t', offset: 0),
          extent: EditorPosition(blockId: 'e_t', offset: 5),
        ),
      );
      s.applyLink('https://x.com');
      var block = s.blocks.single as TextBlock;
      expect(block.content.marks.single.kind, MarkKind.link);
      expect(block.content.linkHrefAt(2), 'https://x.com');

      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_t', offset: 0),
          extent: EditorPosition(blockId: 'e_t', offset: 5),
        ),
      );
      s.removeLink();
      block = s.blocks.single as TextBlock;
      expect(block.content.marks, isEmpty);
    });

    test('toggleMark(spoilerInline) 区间幂等', () {
      final s = EditorState(blocks: [tb('秘密文字')]);
      addTearDown(s.dispose);
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_t', offset: 0),
          extent: EditorPosition(blockId: 'e_t', offset: 4),
        ),
      );
      s.toggleMark(MarkKind.spoilerInline);
      expect(
        (s.blocks.single as TextBlock).content.marks.single.kind,
        MarkKind.spoilerInline,
      );
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_t', offset: 0),
          extent: EditorPosition(blockId: 'e_t', offset: 4),
        ),
      );
      s.toggleMark(MarkKind.spoilerInline);
      expect((s.blocks.single as TextBlock).content.marks, isEmpty);
    });

    test('marksAt 不含 link(pending 不带 attr 防坏链接)', () {
      final c = EditableTextContent(
        text: 'ab',
        marks: const [
          MarkSpan(
            start: 0,
            end: 2,
            kind: MarkKind.link,
            attr: 'https://x.com',
          ),
          MarkSpan(start: 0, end: 2, kind: MarkKind.strong),
        ],
      );
      expect(c.marksAt(1), {MarkKind.strong});
      expect(c.linkHrefAt(1), 'https://x.com');
    });
  });
}

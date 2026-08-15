import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser attachment 识别', () {
    test('a.attachment 产生 isAttachment 的 LinkRun + filename', () {
      final result = parser.parse(
        '<p><a class="attachment" href="/uploads/default/original/1X/abc.pdf">报告.pdf</a> (1.2 MB)</p>',
      );
      final p = result[0] as ParagraphNode;
      final link = p.inlines.whereType<LinkRun>().single;
      expect(link.isAttachment, isTrue);
      expect(link.filename, '报告.pdf');
      expect(link.href, '/uploads/default/original/1X/abc.pdf');
      expect(link.children, [const TextRun('报告.pdf')]);
      // 尾部 " (1.2 MB)" 是锚点外兄弟文本,走普通 TextRun
      expect(
        p.inlines.whereType<TextRun>().any((t) => t.text.contains('(1.2 MB)')),
        isTrue,
      );
    });

    test('secure-uploads 也识别为附件', () {
      final result = parser.parse(
        '<p><a class="attachment" href="/secure-uploads/original/2X/f/f62.zip">archive.zip</a></p>',
      );
      final link = (result[0] as ParagraphNode).inlines
          .whereType<LinkRun>()
          .single;
      expect(link.isAttachment, isTrue);
      expect(link.filename, 'archive.zip');
    });

    test('普通链接不是附件(isAttachment=false, filename 空)', () {
      final result = parser.parse('<p><a href="https://x.com">x</a></p>');
      final link = (result[0] as ParagraphNode).inlines
          .whereType<LinkRun>()
          .single;
      expect(link.isAttachment, isFalse);
      expect(link.filename, '');
    });

    test('==/hashCode 把 isAttachment+filename 纳入比较', () {
      const a = LinkRun(
        href: '/u/a.pdf',
        children: [TextRun('a.pdf')],
        isAttachment: true,
        filename: 'a.pdf',
      );
      const b = LinkRun(
        href: '/u/a.pdf',
        children: [TextRun('a.pdf')],
        isAttachment: true,
        filename: 'a.pdf',
      );
      const plain = LinkRun(href: '/u/a.pdf', children: [TextRun('a.pdf')]);
      expect(a, b);
      expect(a == plain, isFalse);
    });
  });
}

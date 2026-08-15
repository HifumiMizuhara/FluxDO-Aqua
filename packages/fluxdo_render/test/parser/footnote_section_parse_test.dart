import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';
import 'package:fluxdo_render/src/node/node.dart';

void main() {
  group('FootnotesSectionNode 解析 entries', () {
    const html =
        '<p>引用 <sup class="footnote-ref"><a href="#fn:1">1</a></sup>。</p>'
        '<hr class="footnotes-sep">'
        '<section class="footnotes"><ol class="footnotes-list">'
        '<li id="fn:1"><p>正文一 <a href="https://x.com">L</a>. '
        '<a class="footnote-backref" href="#fnref:1">↩︎</a></p></li>'
        '<li id="fn:2"><p>正文二。 '
        '<a class="footnote-backref" href="#fnref:2">↩︎</a></p></li>'
        '</ol></section>';

    test('section 节点带 2 条 entries,编号递增,backref 被剥离', () {
      final nodes = ParagraphParser().parse(html);
      final section = nodes.whereType<FootnotesSectionNode>().single;
      expect(section.entries, hasLength(2));
      expect(section.entries[0].id, 'fn:1');
      expect(section.entries[0].number, '1');
      expect(section.entries[1].number, '2');
      // entry1 含链接 LinkRun,且不含 backref 的 ↩ 文本
      final hasLink = section.entries[0].inlines.any((n) => n is LinkRun);
      expect(hasLink, isTrue);
      final flat = section.entries[0].inlines
          .whereType<TextRun>()
          .map((t) => t.text)
          .join();
      expect(flat.contains('↩'), isFalse);
    });

    test('上标 popover 数据源(FootnoteRefRun.contentHtml)与底部列表并存', () {
      final nodes = ParagraphParser().parse(html);
      // 正文段里的上标仍带 contentHtml(popover 不受底部列表影响)
      final para = nodes.whereType<ParagraphNode>().first;
      final ref = para.inlines.whereType<FootnoteRefRun>().single;
      expect(ref.fnId, 'fn:1');
      expect(ref.contentHtml, isNotNull);
    });

    test('section 无可用 li(无 id)→ entries 为空', () {
      const bad =
          '<section class="footnotes"><ol class="footnotes-list">'
          '<li><p>无 id</p></li></ol></section>';
      final nodes = ParagraphParser().parse(bad);
      final section = nodes.whereType<FootnotesSectionNode>().single;
      expect(section.entries, isEmpty);
    });
  });
}

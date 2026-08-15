import 'package:flutter_test/flutter_test.dart';
import 'dart:ui' show TextAlign;
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser figure 拆壳', () {
    test('figure>img+figcaption → 图片段 + 居中小字 caption 段', () {
      final r = parser.parse(
        '<figure><img src="https://e.com/a.png" alt="x" width="600" height="400">'
        '<figcaption>图片说明</figcaption></figure>',
      );
      expect(r, hasLength(2));
      final imgP = r[0] as ParagraphNode;
      expect(imgP.inlines, hasLength(1));
      final img = imgP.inlines[0] as ImageRun;
      expect(img.src, 'https://e.com/a.png');
      expect(img.width, 600);
      expect(img.height, 400);
      final capP = r[1] as ParagraphNode;
      expect(capP.textAlign, TextAlign.center);
      final styled = capP.inlines.single as StyledRun;
      expect(styled.kind, InlineStyleKind.small);
      expect((styled.children.single as TextRun).text, '图片说明');
    });

    test('figure 无 figcaption → 只产图片段(不产空 caption)', () {
      final r = parser.parse('<figure><img src="a.png"></figure>');
      expect(r, hasLength(1));
      expect((r[0] as ParagraphNode).inlines.single, isA<ImageRun>());
    });

    test('figure 包 lightbox-wrapper → 取缩略图 src + 原图 lightboxUrl', () {
      final r = parser.parse(
        '<figure><div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x/full.png">'
        '<img src="https://x/thumb.png" width="690" height="52">'
        '<div class="meta"><span class="filename">h</span></div>'
        '</a></div><figcaption>cap</figcaption></figure>',
      );
      final img = (r[0] as ParagraphNode).inlines.single as ImageRun;
      expect(img.src, 'https://x/thumb.png');
      expect(img.lightboxUrl, 'https://x/full.png');
      // .meta 文字不应进任何 TextRun(只在 caption 段出现 cap)
      expect(
        (r[1] as ParagraphNode).inlines.whereType<StyledRun>(),
        hasLength(1),
      );
    });

    test('figure 多图 → 同段 ImageRun + LineBreakRun 分隔', () {
      final r = parser.parse(
        '<figure><img src="a.png"><img src="b.png"></figure>',
      );
      final p = r[0] as ParagraphNode;
      expect(p.inlines.whereType<ImageRun>(), hasLength(2));
      expect(p.inlines.whereType<LineBreakRun>(), hasLength(1));
    });

    test('figure 无图(只 figcaption)→ caption 段,不丢、不报未覆盖', () {
      final diag = parser.parseWithDiagnostics(
        '<figure><figcaption>only cap</figcaption></figure>',
      );
      expect(diag.unhandledTags, isNot(contains('figure')));
      // caption 文本仍在(无图时退回 _parseBlocks 内部为空 → 仅 caption 段)
      final hasCap = diag.nodes.whereType<ParagraphNode>().any(
        (p) => p.inlines.whereType<StyledRun>().isNotEmpty,
      );
      expect(hasCap, isTrue);
    });

    test('indexInPost 连续:figure 前后普通图与 figure 内图统一计数', () {
      final r = parser.parse(
        '<p><img src="pre.png"></p>'
        '<figure><img src="fig.png"><figcaption>c</figcaption></figure>'
        '<p><img src="post.png"></p>',
      );
      final idx = <int>[];
      for (final n in r.whereType<ParagraphNode>()) {
        idx.addAll(n.inlines.whereType<ImageRun>().map((e) => e.indexInPost));
      }
      expect(idx, [0, 1, 2]);
    });
  });

  group('parser picture 拆壳', () {
    test('块级 picture>source+img → 取 img fallback', () {
      final r = parser.parse(
        '<picture><source srcset="b-480.webp 480w, b-800.webp 800w">'
        '<img src="b.png" alt="y"></picture>',
      );
      expect(r, hasLength(1));
      final img = (r[0] as ParagraphNode).inlines.single as ImageRun;
      expect(img.src, 'b.png');
    });

    test('块级 picture 无 img → 取首个 source srcset 首个 URL', () {
      final r = parser.parse(
        '<picture><source srcset="first.webp 480w, second.webp 800w"></picture>',
      );
      final img = (r[0] as ParagraphNode).inlines.single as ImageRun;
      expect(img.src, 'first.webp');
    });

    test('行内 <p><picture><source><img></picture></p> → 保 ImageRun 不报未覆盖', () {
      final diag = parser.parseWithDiagnostics(
        '<p>前 <picture><source srcset="s.webp"><img src="i.png"></picture> 后</p>',
      );
      expect(diag.unhandledTags, isNot(contains('picture')));
      expect(diag.unhandledTags, isNot(contains('source')));
      final p = diag.nodes.single as ParagraphNode;
      expect(p.inlines.whereType<ImageRun>(), hasLength(1));
    });
  });
}

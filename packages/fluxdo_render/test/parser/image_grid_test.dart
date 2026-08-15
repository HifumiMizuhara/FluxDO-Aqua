import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser image_grid 识别', () {
    test('基础 d-image-grid + lightbox-wrapper → ImageGridNode', () {
      final result = parser.parse(
        '<div class="d-image-grid" data-columns="2">'
        '<div class="lightbox-wrapper"><a class="lightbox" href="full1.jpg"><img src="t1.jpg" width="600" height="400"></a></div>'
        '<div class="lightbox-wrapper"><a class="lightbox" href="full2.jpg"><img src="t2.jpg" width="600" height="400"></a></div>'
        '</div>',
      );
      expect(result, hasLength(1));
      final g = result[0] as ImageGridNode;
      expect(g.columns, 2);
      expect(g.mode, ImageGridMode.grid);
      expect(g.images, hasLength(2));
      expect(g.images[0].src, 't1.jpg');
      expect(g.images[0].lightboxUrl, 'full1.jpg');
      expect(g.images[1].lightboxUrl, 'full2.jpg');
    });

    test('裸 img(无 lightbox-wrapper)也能识别,lightboxUrl=null', () {
      final result = parser.parse(
        '<div class="d-image-grid" data-columns="3">'
        '<img src="a.jpg" width="300" height="200">'
        '<img src="b.jpg">'
        '</div>',
      );
      final g = result[0] as ImageGridNode;
      expect(g.columns, 3);
      expect(g.images, hasLength(2));
      expect(g.images[0].lightboxUrl, isNull);
      expect(g.images[0].src, 'a.jpg');
      expect(g.images[0].width, 300);
      expect(g.images[0].height, 200);
      expect(g.images[1].width, isNull);
    });

    test('data-mode="carousel" → ImageGridMode.carousel', () {
      final result = parser.parse(
        '<div class="d-image-grid" data-mode="carousel">'
        '<img src="x.jpg">'
        '</div>',
      );
      final g = result[0] as ImageGridNode;
      expect(g.mode, ImageGridMode.carousel);
    });

    test('class d-image-grid--carousel 也识别为 carousel', () {
      final result = parser.parse(
        '<div class="d-image-grid d-image-grid--carousel">'
        '<img src="x.jpg">'
        '</div>',
      );
      final g = result[0] as ImageGridNode;
      expect(g.mode, ImageGridMode.carousel);
    });

    test('data-columns 缺失/非法 → 默认 2', () {
      final r1 = parser.parse(
        '<div class="d-image-grid"><img src="a.jpg"></div>',
      );
      final r2 = parser.parse(
        '<div class="d-image-grid" data-columns="abc"><img src="a.jpg"></div>',
      );
      expect((r1[0] as ImageGridNode).columns, 2);
      expect((r2[0] as ImageGridNode).columns, 2);
    });

    test('跳过 emoji/avatar/thumbnail/yt 缩略类 img', () {
      final result = parser.parse(
        '<div class="d-image-grid" data-columns="2">'
        '<div class="lightbox-wrapper"><a class="lightbox" href="full1.jpg"><img src="t1.jpg"></a></div>'
        '<img class="emoji" src="emoji.png">'
        '<img class="avatar" src="avatar.png">'
        '<img class="thumbnail" src="thumb.png">'
        '<img class="ytp-thumbnail-image" src="yt.png">'
        '<img src="bare.jpg">'
        '</div>',
      );
      final g = result[0] as ImageGridNode;
      // 只剩 lightbox + bare 一共 2 张
      expect(g.images, hasLength(2));
      expect(g.images[0].src, 't1.jpg');
      expect(g.images[1].src, 'bare.jpg');
    });

    test('lightbox-wrapper 包裹的 img 不会被裸 img 扫到重复', () {
      // 同一个 img 元素既在 lightbox-wrapper 里也会被 querySelectorAll('img') 命中,
      // _parseImageGrid 用 consumedImgs Set 去重,确保不重复
      final result = parser.parse(
        '<div class="d-image-grid" data-columns="2">'
        '<div class="lightbox-wrapper"><a class="lightbox" href="x.jpg"><img src="t.jpg"></a></div>'
        '</div>',
      );
      final g = result[0] as ImageGridNode;
      expect(g.images, hasLength(1));
      expect(g.images[0].lightboxUrl, 'x.jpg');
    });

    test('grid 内直包 a.lightbox 的 img 也保留 lightboxUrl', () {
      final result = parser.parse(
        '<div class="d-image-grid" data-columns="2">'
        '<a class="lightbox" href="full.jpg"><img src="thumb.jpg"></a>'
        '</div>',
      );
      final g = result[0] as ImageGridNode;
      expect(g.images, hasLength(1));
      expect(g.images[0].src, 'thumb.jpg');
      expect(g.images[0].lightboxUrl, 'full.jpg');
    });

    test('空 grid(无 img)→ ImageGridNode + images 空', () {
      final result = parser.parse(
        '<div class="d-image-grid" data-columns="2"></div>',
      );
      final g = result[0] as ImageGridNode;
      expect(g.images, isEmpty);
    });

    test('grid 内 ImageRun 的 indexInPost 自增 + 全局共享', () {
      final result = parser.parse(
        '<p><img src="before.jpg"></p>'
        '<div class="d-image-grid" data-columns="2">'
        '<img src="g1.jpg">'
        '<img src="g2.jpg">'
        '</div>'
        '<p><img src="after.jpg"></p>',
      );
      // before(0) + grid 内 g1(1)/g2(2) + after(3) 共 4 张
      expect(result, hasLength(3));
      expect(countImageRuns(result), 4);
      final g = result[1] as ImageGridNode;
      expect(g.images[0].indexInPost, 1);
      expect(g.images[1].indexInPost, 2);
    });

    test('countImageRuns 把 ImageGridNode.images 算入', () {
      final result = parser.parse(
        '<div class="d-image-grid">'
        '<img src="a.jpg">'
        '<img src="b.jpg">'
        '<img src="c.jpg">'
        '</div>',
      );
      expect(countImageRuns(result), 3);
    });

    test('不带 d-image-grid 的 div 不会被识别', () {
      final result = parser.parse('<div><img src="a.jpg"></div>');
      // 走 fallback paragraph(只取 textContent);img 在 fallback 路径下不被
      // 提取(块级 fallback 不走 inline 收集),所以结果为空。
      // 关键断言:绝对不应该是 ImageGridNode。
      expect(result.whereType<ImageGridNode>().toList(), isEmpty);
    });

    test('id 唯一', () {
      final result = parser.parse(
        '<div class="d-image-grid"><img src="a.jpg"></div>'
        '<div class="d-image-grid"><img src="b.jpg"></div>',
      );
      expect(result, hasLength(2));
      final g1 = result[0] as ImageGridNode;
      final g2 = result[1] as ImageGridNode;
      expect(g1.id, isNot(g2.id));
    });
  });
}

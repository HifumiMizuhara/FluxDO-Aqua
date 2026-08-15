/// 图片缩放(image-controls 预览形态)数据链测试:
/// parser 提取 scale/index/原始尺寸反推 → 序列化写回 `|WxH, N%`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

/// 与 cook bundle 实际输出同构的最小预览形态(乘过 50% 的显示尺寸)。
String _previewImg({
  required String alt,
  required int w,
  required int h,
  required String active,
  int index = 0,
  String orig = 'upload://aaaBBB123.jpeg',
}) =>
    '<span class="image-wrapper">'
    '<img src="/images/transparent.png" alt="$alt" data-orig-src="$orig" '
    'width="$w" height="$h" class="resizable">'
    '<span class="button-wrapper" data-image-index="$index">'
    '<span class="scale-btn-container">'
    '<span class="scale-btn${active == '100' ? ' active' : ''}" data-scale="100">100%</span>'
    '<span class="scale-btn${active == '75' ? ' active' : ''}" data-scale="75">75%</span>'
    '<span class="scale-btn${active == '50' ? ' active' : ''}" data-scale="50">50%</span>'
    '</span></span></span>';

ImageRun _firstImage(List<BlockNode> nodes) {
  for (final n in nodes) {
    if (n is ParagraphNode) {
      for (final i in n.inlines) {
        if (i is ImageRun) return i;
      }
    }
  }
  fail('无 ImageRun');
}

void main() {
  test('50% 档:提取 scale/index,ceil 反推原始尺寸', () {
    // raw ![13599.jpg|690x388, 50%] → cook 出 345x194
    final nodes = ParagraphParser().parse(
      '<p>${_previewImg(alt: '13599.jpg', w: 345, h: 194, active: '50')}</p>',
    );
    final img = _firstImage(nodes);
    expect(img.scale, 50);
    expect(img.previewImageIndex, 0);
    expect(img.width, 345);
    expect(img.origWidth, 690);
    expect(img.origHeight, 388);
    expect(img.origSrc, 'upload://aaaBBB123.jpeg');
  });

  test('100% 档:scale=100,无反推(width 即原始)', () {
    final nodes = ParagraphParser().parse(
      '<p>${_previewImg(alt: 'a', w: 690, h: 388, active: '100')}</p>',
    );
    final img = _firstImage(nodes);
    expect(img.scale, 100);
    expect(img.origWidth, isNull);
    expect(img.width, 690);
  });

  test('服务端 baked 形态(无控件):scale 系全 null', () {
    final nodes = ParagraphParser().parse(
      '<p><img src="https://cdn.x/a.png" width="690" height="388"></p>',
    );
    final img = _firstImage(nodes);
    expect(img.scale, isNull);
    expect(img.previewImageIndex, isNull);
    expect(img.origWidth, isNull);
  });

  test('序列化写回:50% → `![alt|690x388, 50%](短链)`;100% 无后缀', () {
    final nodes50 = ParagraphParser().parse(
      '<p>${_previewImg(alt: '13599.jpg', w: 345, h: 194, active: '50')}</p>',
    );
    var doc = blockNodesToDoc(nodes50, _idGen());
    expect(
      docToMarkdown(doc),
      '![13599.jpg|690x388, 50%](upload://aaaBBB123.jpeg)',
    );

    final nodes100 = ParagraphParser().parse(
      '<p>${_previewImg(alt: 'a', w: 690, h: 388, active: '100')}</p>',
    );
    doc = blockNodesToDoc(nodes100, _idGen());
    expect(docToMarkdown(doc), '![a|690x388](upload://aaaBBB123.jpeg)');
  });

  test('奇数尺寸 ceil 反推:75% 档 517x291 → 690x388(floor 往返一致)', () {
    // 690*0.75=517.5 → parseInt 截断 517;388*0.75=291
    final nodes = ParagraphParser().parse(
      '<p>${_previewImg(alt: 'x', w: 517, h: 291, active: '75')}</p>',
    );
    final img = _firstImage(nodes);
    expect(img.origWidth, 690, reason: 'ceil(517*100/75)=690');
    expect(img.origHeight, 388);
    // 反推值再 cook 一遍(floor 乘法)必须回到显示尺寸
    expect((img.origWidth! * 75 / 100).floor(), 517);
    expect((img.origHeight! * 75 / 100).floor(), 291);
  });

  test('grid 预览形态:逐图提取 scale/index,序列化写回 [grid] 保缩放', () {
    // cook `[grid]\n![a|690x388, 50%](upload://aaa)\n![b|100x200](upload://bbb)\n[/grid]`
    // 的实测输出结构:div.d-image-grid > p > image-wrapper ×2,index 连续编号
    final cooked =
        '<div class="d-image-grid" data-columns="2"><p>'
        '${_previewImg(alt: 'a', w: 345, h: 194, active: '50', index: 0, orig: 'upload://aaa.jpeg')}'
        '${_previewImg(alt: 'b', w: 100, h: 200, active: '100', index: 1, orig: 'upload://bbb.png')}'
        '</p></div>';
    final nodes = ParagraphParser().parse(cooked);
    final grid = nodes.whereType<ImageGridNode>().single;
    expect(grid.images, hasLength(2));
    expect(grid.images[0].scale, 50);
    expect(grid.images[0].previewImageIndex, 0);
    expect(grid.images[0].origWidth, 690);
    expect(grid.images[1].scale, 100);
    expect(grid.images[1].previewImageIndex, 1);

    // grid 在编辑器里是岛:serializeIslandNode 写回必须保缩放后缀
    expect(
      serializeIslandNode(grid),
      '[grid]\n'
      '![a|690x388, 50%](upload://aaa.jpeg)\n'
      '![b|100x200](upload://bbb.png)\n'
      '[/grid]',
    );
  });
}

String Function() _idGen() {
  var n = 0;
  return () => 'e_${n++}';
}

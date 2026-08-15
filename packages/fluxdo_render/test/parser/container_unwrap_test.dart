import 'dart:ui' show TextAlign;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

/// 通用容器 div / `<center>`(含块级子)的透明拆壳。
///
/// 回归背景:手写 `<div align="center">` 包上传图时,cooked 里的
/// `<p><div class="lightbox-wrapper">` 是非法嵌套,html 解析器按 HTML5
/// 规则把 `<p>` 提前闭合 → lightbox-wrapper 成 div 的直接块级子。
/// 修复前该 div 掉进"未识别块级 → 纯 textContent 兜底":图全丢,
/// 只剩 lightbox meta 里的「文件名 + 尺寸」文字。
void main() {
  final parser = ParagraphParser();

  /// 收集所有段落顶层 TextRun 文本(meta 泄漏时文本恰好落在顶层)。
  String topLevelText(List<BlockNode> nodes) {
    final buf = StringBuffer();
    for (final n in nodes.whereType<ParagraphNode>()) {
      for (final inline in n.inlines) {
        if (inline is TextRun) buf.write(inline.text);
      }
    }
    return buf.toString();
  }

  group('通用容器拆壳(div / center 含块级子)', () {
    test('div[align=center] 包 img + p>lightbox-wrapper:图不丢、meta 不漏、对齐下放', () {
      const html = '''
<div align="center">
  <img src="https://example.com/images/badge.png" alt="badge" width="120" height="60">
<p><div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/uploads/full/photo.png" title="photo.png"><img src="https://example.com/uploads/opt/photo_690x388.png" width="690" height="388"><div class="meta"><svg class="fa d-icon d-icon-far-image svg-icon" aria-hidden="true"><use href="#far-image"></use></svg><span class="filename">photo.png</span><span class="informations">1920×1080 233 KB</span><svg class="fa d-icon d-icon-discourse-expand svg-icon" aria-hidden="true"><use href="#discourse-expand"></use></svg></div></a></div></p>
</div>
''';
      final result = parser.parse(html);

      // 两张图都被解析出来,lightbox 原图链接保留
      final images = collectImageRuns(result);
      expect(images, hasLength(2));
      expect(images[0].src, 'https://example.com/images/badge.png');
      expect(
        images[1].src,
        'https://example.com/uploads/opt/photo_690x388.png',
      );
      expect(
        images[1].lightboxUrl,
        'https://example.com/uploads/full/photo.png',
      );

      // lightbox meta(文件名/尺寸)不泄漏成正文
      final text = topLevelText(result);
      expect(text, isNot(contains('photo.png')));
      expect(text, isNot(contains('1920×1080')));

      // 容器对齐下放到图片段落
      final paragraphs = result.whereType<ParagraphNode>().toList();
      expect(paragraphs, isNotEmpty);
      for (final p in paragraphs) {
        expect(p.textAlign, TextAlign.center);
      }
    });

    test('无对齐的 div 含块级子:拆壳保留内部段落结构', () {
      final result = parser.parse('<div><p>第一段</p><p>第二段</p></div>');
      final ps = result.whereType<ParagraphNode>().toList();
      expect(ps, hasLength(2));
      expect((ps[0].inlines.single as TextRun).text, '第一段');
      expect((ps[1].inlines.single as TextRun).text, '第二段');
      expect(ps[0].textAlign, isNull);
      expect(ps[1].textAlign, isNull);
    });

    test('容器对齐不覆盖子块自身对齐', () {
      final result = parser.parse(
        '<div align="center">'
        '<p style="text-align:right">自己右对齐</p>'
        '<p>跟随容器</p>'
        '</div>',
      );
      final ps = result.whereType<ParagraphNode>().toList();
      expect(ps, hasLength(2));
      expect(ps[0].textAlign, TextAlign.right);
      expect(ps[1].textAlign, TextAlign.center);
    });

    test('<center> 含块级子:拆壳且下放居中', () {
      final result = parser.parse('<center><p>甲</p><p>乙</p></center>');
      final ps = result.whereType<ParagraphNode>().toList();
      expect(ps, hasLength(2));
      expect(ps[0].textAlign, TextAlign.center);
      expect(ps[1].textAlign, TextAlign.center);
    });

    test('嵌套容器:内层对齐优先,外层只补无对齐的', () {
      final result = parser.parse(
        '<div align="center">'
        '<div align="right"><p>内层右</p></div>'
        '<p>外层中</p>'
        '</div>',
      );
      final ps = result.whereType<ParagraphNode>().toList();
      expect(ps, hasLength(2));
      expect(ps[0].textAlign, TextAlign.right);
      expect(ps[1].textAlign, TextAlign.center);
    });

    test('div 内块级子与散落 inline 混排:inline 聚段、块级保序', () {
      final result = parser.parse(
        '<div align="center">前置文字<p>中间段落</p>后置文字</div>',
      );
      final ps = result.whereType<ParagraphNode>().toList();
      expect(ps, hasLength(3));
      expect((ps[0].inlines.single as TextRun).text, '前置文字');
      expect((ps[1].inlines.single as TextRun).text, '中间段落');
      expect((ps[2].inlines.single as TextRun).text, '后置文字');
      for (final p in ps) {
        expect(p.textAlign, TextAlign.center);
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser 内容型 svg 识别', () {
    test('有 viewBox 的顶层 svg → SvgNode(带源串)', () {
      const svg =
          '<svg viewBox="0 0 100 50"><rect width="100" height="50"/></svg>';
      final result = parser.parse(svg);
      expect(result, hasLength(1));
      final n = result[0] as SvgNode;
      expect(n.svgSource.contains('viewBox'), isTrue);
    });

    test('有显式宽高(无 viewBox)的 svg → SvgNode + width/height', () {
      final result = parser.parse('<svg width="120" height="80"><rect/></svg>');
      final n = result.single as SvgNode;
      expect(n.width, 120);
      expect(n.height, 80);
    });

    test('d-icon 图标 svg(无 viewBox 无尺寸)→ 不产 SvgNode', () {
      final result = parser.parse(
        '<svg class="fa d-icon d-icon-far-image"><use href="#far-image"/></svg>',
      );
      expect(result.whereType<SvgNode>(), isEmpty);
    });

    test('既无 viewBox 又无尺寸的裸 svg → 不产 SvgNode(图标占位)', () {
      final result = parser.parse('<svg><use href="#x"/></svg>');
      expect(result.whereType<SvgNode>(), isEmpty);
    });

    test('d-icon 即使带 viewBox 也判为图标 → 不产 SvgNode', () {
      final result = parser.parse(
        '<svg class="d-icon" viewBox="0 0 16 16"><use href="#x"/></svg>',
      );
      expect(result.whereType<SvgNode>(), isEmpty);
    });

    test('inline 路径(<p> 内 d-icon)仍整体跳过', () {
      final p =
          parser.parse(
                '<p>前 <svg class="d-icon"><use href="#x"/></svg> 后</p>',
              )[0]
              as ParagraphNode;
      expect(p.inlines.whereType<TextRun>().map((e) => e.text), ['前 ', ' 后']);
    });
  });
}

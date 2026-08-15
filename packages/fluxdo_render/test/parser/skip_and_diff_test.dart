import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser 跳过纯展示元素(svg / d-icon / meta / lb-spacer)', () {
    test('inline <svg> 完全跳过,不留任何 inline', () {
      final result = parser.parse(
        '<p>前 <svg class="d-icon"><use href="#x"></use></svg> 后</p>',
      );
      final p = result[0] as ParagraphNode;
      // 期望:只有 "前 " + " 后",svg 完全不进 inline
      expect(p.inlines.length, 2);
      expect(p.inlines[0], const TextRun('前 '));
      expect(p.inlines[1], const TextRun(' 后'));
    });

    test('span.d-icon 跳过', () {
      final result = parser.parse(
        '<p>前 <span class="d-icon">icon-text-shouldnt-show</span> 后</p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(2));
      expect(p.inlines.whereType<TextRun>().map((e) => e.text), ['前 ', ' 后']);
    });

    test('div.meta 在块级 fallback 时跳过(不产生 ParagraphNode)', () {
      final result = parser.parse(
        '<div class="meta">hidden filename + 1686×128 15.7 KB</div>',
      );
      // div.meta 走块级 default 分支,_isSkipElement 跳过 → 不产节点
      expect(result, isEmpty);
    });

    test('div.lb-spacer 跳过(legacy 是 lightbox 占位高度)', () {
      final result = parser.parse('<div class="lb-spacer"></div>');
      expect(result, isEmpty);
    });

    test('block 级内容 svg(带尺寸)→ 现在产 SvgNode(不再跳过)', () {
      final result = parser.parse(
        '<svg width="100" height="100"><use href="#x"/></svg>',
      );
      expect(result.whereType<SvgNode>(), hasLength(1));
    });

    test('block 级图标 svg(无 viewBox 无尺寸)仍跳过', () {
      final result = parser.parse('<svg><use href="#x"/></svg>');
      expect(result, isEmpty);
    });
  });

  group('parser ins / del / s / sup / sub → StyledRun(对齐 fwfh)', () {
    test('<ins> → StyledRun.underline', () {
      final p = parser.parse('<p>x <ins>new</ins> y</p>')[0] as ParagraphNode;
      final styled = p.inlines.whereType<StyledRun>().single;
      expect(styled.kind, InlineStyleKind.underline);
      expect(styled.children, [const TextRun('new')]);
    });

    test('<del> / <s> / <strike> → StyledRun.lineThrough', () {
      InlineStyleKind kindOf(String html) =>
          ((parser.parse('<p>$html</p>')[0] as ParagraphNode).inlines
                  .whereType<StyledRun>()
                  .single)
              .kind;
      expect(kindOf('<del>old</del>'), InlineStyleKind.lineThrough);
      expect(kindOf('<s>strike</s>'), InlineStyleKind.lineThrough);
      expect(kindOf('<strike>x</strike>'), InlineStyleKind.lineThrough);
    });

    test('<sup> / <sub> → StyledRun.superscript/subscript', () {
      final p =
          parser.parse('<p>H<sub>2</sub>O 和 E=mc<sup>2</sup></p>')[0]
              as ParagraphNode;
      final styled = p.inlines.whereType<StyledRun>().toList();
      expect(styled.map((s) => s.kind), [
        InlineStyleKind.subscript,
        InlineStyleKind.superscript,
      ]);
    });

    test('sup.footnote-ref 仍走 FootnoteRefRun(不当上标)', () {
      final p =
          parser.parse(
                '<p>x<sup class="footnote-ref"><a href="#fn:a">1</a></sup></p>',
              )[0]
              as ParagraphNode;
      expect(p.inlines.whereType<FootnoteRefRun>(), hasLength(1));
      expect(p.inlines.whereType<StyledRun>(), isEmpty);
    });

    test('<small>/<big>/<mark>/<kbd>/<u> → 对应 StyledRun', () {
      InlineStyleKind kindOf(String html) =>
          ((parser.parse('<p>$html</p>')[0] as ParagraphNode).inlines
                  .whereType<StyledRun>()
                  .single)
              .kind;
      expect(kindOf('<small>s</small>'), InlineStyleKind.small);
      expect(kindOf('<big>b</big>'), InlineStyleKind.big);
      expect(kindOf('<mark>m</mark>'), InlineStyleKind.mark);
      expect(kindOf('<kbd>K</kbd>'), InlineStyleKind.monospace);
      expect(kindOf('<samp>s</samp>'), InlineStyleKind.monospace);
      expect(kindOf('<u>u</u>'), InlineStyleKind.underline);
    });
  });

  group('parser 顶层裸 br 跳过(消除 block 之间空行)', () {
    test('两个 block 之间裸 br 不产 ParagraphNode', () {
      final result = parser.parse('<p>1</p><br><p>2</p>');
      expect(result, hasLength(2));
      expect(result.every((n) => n is ParagraphNode), isTrue);
    });

    test('inline 内的 br 仍正常产 LineBreakRun', () {
      final result = parser.parse('<p>a<br>b</p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<LineBreakRun>(), hasLength(1));
    });
  });
}

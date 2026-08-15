import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser spoiler 识别', () {
    test('span.spoiler 行内 → SpoilerRun', () {
      final result = parser.parse(
        '<p>答案是 <span class="spoiler">42</span>。</p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<SpoilerRun>(), hasLength(1));
      final sp = p.inlines.whereType<SpoilerRun>().first;
      expect(sp.children, [const TextRun('42')]);
    });

    test('span.spoiled 也识别', () {
      final result = parser.parse('<p><span class="spoiled">x</span></p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<SpoilerRun>(), hasLength(1));
    });

    test('span 内嵌 strong / link 保留', () {
      final result = parser.parse(
        '<p><span class="spoiler"><strong>粗</strong> 和 <a href="/x">link</a></span></p>',
      );
      final p = result[0] as ParagraphNode;
      final sp = p.inlines.whereType<SpoilerRun>().first;
      expect(sp.children, hasLength(3));
      expect(sp.children.whereType<StrongRun>(), hasLength(1));
      expect(sp.children.whereType<LinkRun>(), hasLength(1));
    });

    test('其他 span(非 spoiler)展平,不产生 SpoilerRun', () {
      final result = parser.parse('<p>x <span class="other">y</span></p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<SpoilerRun>(), isEmpty);
    });

    test('div.spoiler 块级 → SpoilerBlockNode', () {
      final result = parser.parse(
        '<div class="spoiler"><p>x</p><p>y</p></div>',
      );
      expect(result, hasLength(1));
      final s = result[0] as SpoilerBlockNode;
      expect(s.children, hasLength(2));
      expect(s.children.every((c) => c is ParagraphNode), isTrue);
    });

    test('div.spoiled 也识别', () {
      final result = parser.parse('<div class="spoiled"><p>x</p></div>');
      expect(result[0], isA<SpoilerBlockNode>());
    });

    test('div.spoiler 内含 list / code', () {
      final result = parser.parse(
        '<div class="spoiler"><p>p</p><ul><li>x</li></ul></div>',
      );
      final s = result[0] as SpoilerBlockNode;
      expect(s.children, hasLength(2));
      expect(s.children[0], isA<ParagraphNode>());
      expect(s.children[1], isA<ListNode>());
    });

    test('其他 div(非 spoiler)走 fallback textContent', () {
      final result = parser.parse('<div class="other">x</div>');
      expect(result.whereType<SpoilerBlockNode>(), isEmpty);
    });

    test('==/hashCode 按 children', () {
      const a = SpoilerBlockNode(
        id: 'b_0',
        children: [
          ParagraphNode(id: 'b_1', inlines: [TextRun('x')]),
        ],
      );
      const b = SpoilerBlockNode(
        id: 'b_42',
        children: [
          ParagraphNode(id: 'b_99', inlines: [TextRun('x')]),
        ],
      );
      expect(a, b);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser details 识别', () {
    test('基础形态 → DetailsNode + summary + children', () {
      final result = parser.parse(
        '<details><summary>标题</summary><p>内容</p></details>',
      );
      expect(result, hasLength(1));
      final d = result[0] as DetailsNode;
      expect(d.summary, '标题');
      expect(d.initiallyOpen, isFalse);
      expect(d.children, hasLength(1));
      expect(d.children[0], isA<ParagraphNode>());
    });

    test('<details open> → initiallyOpen=true', () {
      final result = parser.parse(
        '<details open><summary>x</summary><p>y</p></details>',
      );
      expect((result[0] as DetailsNode).initiallyOpen, isTrue);
    });

    test('无 summary → summary 为空串', () {
      final result = parser.parse('<details><p>just body</p></details>');
      final d = result[0] as DetailsNode;
      expect(d.summary, '');
      expect(d.children, hasLength(1));
    });

    test('summary 不参与 children(只取剩余 nodes 递归)', () {
      final result = parser.parse(
        '<details><summary>S</summary><p>a</p><p>b</p></details>',
      );
      final d = result[0] as DetailsNode;
      expect(d.children, hasLength(2));
      expect(d.children.every((c) => c is ParagraphNode), isTrue);
    });

    test('嵌套 details', () {
      final result = parser.parse(
        '<details><summary>外</summary>'
        '<p>外内容</p>'
        '<details><summary>内</summary><p>内内容</p></details>'
        '</details>',
      );
      final outer = result[0] as DetailsNode;
      expect(outer.children, hasLength(2));
      expect(outer.children[0], isA<ParagraphNode>());
      final inner = outer.children[1] as DetailsNode;
      expect(inner.summary, '内');
      expect(inner.children, hasLength(1));
    });

    test('details 内含 list / code 等混合块', () {
      final result = parser.parse(
        '<details><summary>S</summary>'
        '<p>p</p><ul><li>a</li></ul>'
        '<pre><code>code</code></pre>'
        '</details>',
      );
      final d = result[0] as DetailsNode;
      expect(d.children, hasLength(3));
      expect(d.children[0], isA<ParagraphNode>());
      expect(d.children[1], isA<ListNode>());
      expect(d.children[2], isA<CodeBlockNode>());
    });

    test('id 在嵌套场景下全局唯一', () {
      final result = parser.parse(
        '<details><summary>S</summary>'
        '<p>a</p>'
        '<details><summary>inner</summary><p>b</p></details>'
        '</details>',
      );
      final outer = result[0] as DetailsNode;
      final outerP = outer.children[0] as ParagraphNode;
      final inner = outer.children[1] as DetailsNode;
      final innerP = inner.children[0] as ParagraphNode;
      expect({outer.id, outerP.id, inner.id, innerP.id}, hasLength(4));
    });
  });
}

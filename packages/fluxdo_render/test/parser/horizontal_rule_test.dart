import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser hr 识别', () {
    test('单独 hr 产生 HorizontalRuleNode', () {
      final result = parser.parse('<hr>');
      expect(result, hasLength(1));
      expect(result[0], isA<HorizontalRuleNode>());
    });

    test('两段之间 hr 产生 3 个 BlockNode', () {
      final result = parser.parse('<p>前</p><hr><p>后</p>');
      expect(result, hasLength(3));
      expect(result[0], isA<ParagraphNode>());
      expect(result[1], isA<HorizontalRuleNode>());
      expect(result[2], isA<ParagraphNode>());
    });

    test('连续 3 条 hr 产生 3 个独立 HorizontalRuleNode', () {
      final result = parser.parse('<hr><hr><hr>');
      expect(result, hasLength(3));
      expect(result.every((n) => n is HorizontalRuleNode), isTrue);
      // 3 个独立 id
      expect(result.map((n) => n.id).toSet(), hasLength(3));
    });

    test('blockquote 内的 hr', () {
      final result = parser.parse(
        '<blockquote><p>x</p><hr><p>y</p></blockquote>',
      );
      final bq = result[0] as BlockquoteNode;
      expect(bq.children, hasLength(3));
      expect(bq.children[1], isA<HorizontalRuleNode>());
    });
  });
}

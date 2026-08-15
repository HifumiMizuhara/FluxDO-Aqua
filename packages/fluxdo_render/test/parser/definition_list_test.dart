import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser dl 识别', () {
    test('基础 dl 产生 DefinitionListNode + 正确条目', () {
      final result = parser.parse(
        '<dl><dt>术语A</dt><dd>释义A</dd><dt>术语B</dt><dd>释义B</dd></dl>',
      );
      expect(result, hasLength(1));
      final dl = result[0] as DefinitionListNode;
      expect(dl.items, hasLength(2));
      // 第一条 term 行内为 '术语A'
      final term0 = dl.items[0].term;
      expect(term0.whereType<TextRun>().map((t) => t.text).join(), '术语A');
      expect(dl.items[0].definitions, hasLength(1));
    });

    test('一个 dt 后跟多个 dd', () {
      final result = parser.parse('<dl><dt>T</dt><dd>d1</dd><dd>d2</dd></dl>');
      final dl = result[0] as DefinitionListNode;
      expect(dl.items, hasLength(1));
      expect(dl.items[0].definitions, hasLength(2));
    });

    test('孤儿 dd(无前置 dt)自动开 term 为空的条目', () {
      final result = parser.parse('<dl><dd>无主释义</dd></dl>');
      final dl = result[0] as DefinitionListNode;
      expect(dl.items, hasLength(1));
      expect(dl.items[0].term, isEmpty);
      expect(dl.items[0].definitions, hasLength(1));
    });

    test('dd 内块级(段落+列表)走 _parseBlocks', () {
      final result = parser.parse(
        '<dl><dt>Q</dt><dd><p>a</p><ul><li>x</li></ul></dd></dl>',
      );
      final dl = result[0] as DefinitionListNode;
      final dd0 = dl.items[0].definitions[0];
      expect(dd0.whereType<ParagraphNode>(), isNotEmpty);
      expect(dd0.whereType<ListNode>(), isNotEmpty);
    });

    test('空 dl 不产节点', () {
      final result = parser.parse('<dl>\n  \n</dl>');
      expect(result.whereType<DefinitionListNode>(), isEmpty);
    });

    test('两段之间的 dl', () {
      final result = parser.parse(
        '<p>前</p><dl><dt>T</dt><dd>D</dd></dl><p>后</p>',
      );
      expect(result, hasLength(3));
      expect(result[0], isA<ParagraphNode>());
      expect(result[1], isA<DefinitionListNode>());
      expect(result[2], isA<ParagraphNode>());
    });
  });
}

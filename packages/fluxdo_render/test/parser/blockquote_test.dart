import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser blockquote 识别', () {
    test('blockquote 产生 BlockquoteNode + 内含 ParagraphNode', () {
      final result = parser.parse('<blockquote><p>引用</p></blockquote>');
      expect(result, hasLength(1));
      final bq = result[0] as BlockquoteNode;
      expect(bq.children, hasLength(1));
      final p = bq.children[0] as ParagraphNode;
      expect(p.inlines, [const TextRun('引用')]);
    });

    test('多段引用 → 多 ParagraphNode child', () {
      final result = parser.parse('<blockquote><p>一</p><p>二</p></blockquote>');
      final bq = result[0] as BlockquoteNode;
      expect(bq.children, hasLength(2));
      expect(bq.children.every((c) => c is ParagraphNode), isTrue);
    });

    test('blockquote 内含 ul → list 作 child', () {
      final result = parser.parse(
        '<blockquote><p>前</p><ul><li>a</li></ul><p>后</p></blockquote>',
      );
      final bq = result[0] as BlockquoteNode;
      expect(bq.children, hasLength(3));
      expect(bq.children[0], isA<ParagraphNode>());
      expect(bq.children[1], isA<ListNode>());
      expect(bq.children[2], isA<ParagraphNode>());
    });

    test('嵌套 blockquote 三层', () {
      final result = parser.parse(
        '<blockquote>'
        '<p>外</p>'
        '<blockquote>'
        '<p>中</p>'
        '<blockquote><p>内</p></blockquote>'
        '</blockquote>'
        '</blockquote>',
      );
      final outer = result[0] as BlockquoteNode;
      // outer.children: [p('外'), blockquote(...)]
      expect(outer.children, hasLength(2));
      final mid = outer.children[1] as BlockquoteNode;
      expect(mid.children, hasLength(2));
      final inner = mid.children[1] as BlockquoteNode;
      expect(inner.children, hasLength(1));
      final innerP = inner.children[0] as ParagraphNode;
      expect(innerP.inlines, [const TextRun('内')]);
    });

    test('裸 inline 在 blockquote 内自动合并成 paragraph', () {
      final result = parser.parse(
        '<blockquote>裸文本 <strong>粗</strong></blockquote>',
      );
      final bq = result[0] as BlockquoteNode;
      expect(bq.children, hasLength(1));
      final p = bq.children[0] as ParagraphNode;
      expect(p.inlines.length, 2);
      expect(p.inlines[0], const TextRun('裸文本 '));
      expect(p.inlines[1], const StrongRun(children: [TextRun('粗')]));
    });

    test('blockquote 跟其他 BlockNode 平级混排', () {
      final result = parser.parse(
        '<p>前</p><blockquote><p>引</p></blockquote><p>后</p>',
      );
      expect(result, hasLength(3));
      expect(result[0], isA<ParagraphNode>());
      expect(result[1], isA<BlockquoteNode>());
      expect(result[2], isA<ParagraphNode>());
    });

    test('id 在嵌套场景下全局唯一', () {
      final result = parser.parse(
        '<blockquote><p>a</p><blockquote><p>b</p></blockquote></blockquote>',
      );
      final outer = result[0] as BlockquoteNode;
      final outerP = outer.children[0] as ParagraphNode;
      final inner = outer.children[1] as BlockquoteNode;
      final innerP = inner.children[0] as ParagraphNode;
      // 4 个 BlockNode 各有独立 id
      expect({outer.id, outerP.id, inner.id, innerP.id}, hasLength(4));
    });

    test('空 blockquote 产生空 children', () {
      final result = parser.parse('<blockquote></blockquote>');
      final bq = result[0] as BlockquoteNode;
      expect(bq.children, isEmpty);
    });
  });

  group('parser blockquote 装饰下放 data-fxd-pos', () {
    test('默认无属性 → chunkPos = whole', () {
      final bq =
          parser.parse('<blockquote><p>x</p></blockquote>')[0]
              as BlockquoteNode;
      expect(bq.chunkPos, BlockquoteChunkPos.whole);
    });

    test('data-fxd-pos=first/mid/last → 对应位置', () {
      BlockquoteChunkPos pos(String v) =>
          (parser.parse(
                    '<blockquote data-fxd-pos="$v"><p>x</p></blockquote>',
                  )[0]
                  as BlockquoteNode)
              .chunkPos;
      expect(pos('first'), BlockquoteChunkPos.first);
      expect(pos('mid'), BlockquoteChunkPos.mid);
      expect(pos('last'), BlockquoteChunkPos.last);
    });

    test('未知值 → whole(兜底)', () {
      final bq =
          parser.parse(
                '<blockquote data-fxd-pos="bogus"><p>x</p></blockquote>',
              )[0]
              as BlockquoteNode;
      expect(bq.chunkPos, BlockquoteChunkPos.whole);
    });
  });
}

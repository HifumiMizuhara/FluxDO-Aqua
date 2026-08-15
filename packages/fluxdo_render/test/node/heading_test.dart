import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('HeadingNode 数据模型', () {
    test('==/hashCode 按 level + inlines 比较(忽略 id)', () {
      const a = HeadingNode(id: 'b_0', level: 1, inlines: [TextRun('x')]);
      const b = HeadingNode(id: 'b_9', level: 1, inlines: [TextRun('x')]);
      const c = HeadingNode(id: 'b_0', level: 2, inlines: [TextRun('x')]);
      expect(a, b);
      expect(a == c, isFalse);
    });

    test('level 越界 assert', () {
      expect(
        () => HeadingNode(id: 'x', level: 0, inlines: const []),
        throwsAssertionError,
      );
      expect(
        () => HeadingNode(id: 'x', level: 7, inlines: const []),
        throwsAssertionError,
      );
    });
  });

  group('parser heading 识别', () {
    test('h1 - h6 都识别', () {
      for (var i = 1; i <= 6; i++) {
        final result = parser.parse('<h$i>title</h$i>');
        expect(result, hasLength(1), reason: 'h$i should produce 1 node');
        final h = result[0] as HeadingNode;
        expect(h.level, i);
        expect(h.inlines, [const TextRun('title')]);
      }
    });

    test('heading 内可含 em / strong / br', () {
      final result = parser.parse('<h2>plain <em>italic</em> <br>newline</h2>');
      final h = result[0] as HeadingNode;
      expect(h.level, 2);
      // <em> 与 <br> 间的空格紧邻换行 → HTML 空白规整去掉(浏览器换行处空白
      // 不渲染),故 4 个 inline。
      expect(h.inlines, hasLength(4));
      expect(h.inlines[0], const TextRun('plain '));
      expect(h.inlines[1], const EmRun(children: [TextRun('italic')]));
      expect(h.inlines[2], const LineBreakRun());
      expect(h.inlines[3], const TextRun('newline'));
    });

    test('多 heading 顺序保留', () {
      final result = parser.parse('<h1>A</h1><h2>B</h2><h3>C</h3>');
      expect(result, hasLength(3));
      expect((result[0] as HeadingNode).level, 1);
      expect((result[1] as HeadingNode).level, 2);
      expect((result[2] as HeadingNode).level, 3);
      // id 按出现顺序递增
      expect((result[0] as HeadingNode).id, 'b_0');
      expect((result[1] as HeadingNode).id, 'b_1');
      expect((result[2] as HeadingNode).id, 'b_2');
    });

    test('heading 与 paragraph 混排', () {
      final result = parser.parse('<p>p1</p><h2>h2</h2><p>p2</p>');
      expect(result, hasLength(3));
      expect(result[0], isA<ParagraphNode>());
      expect(result[1], isA<HeadingNode>());
      expect(result[2], isA<ParagraphNode>());
    });
  });
}

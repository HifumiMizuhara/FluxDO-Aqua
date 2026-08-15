import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser math 识别', () {
    test('块级 div.math → MathBlockNode + latex', () {
      final result = parser.parse(r'<div class="math">x = \frac{1}{2}</div>');
      expect(result, hasLength(1));
      final m = result[0] as MathBlockNode;
      expect(m.latex, r'x = \frac{1}{2}');
    });

    test('行内 span.math → MathInlineRun', () {
      final result = parser.parse(
        r'<p>欧拉 <span class="math">e^{i\pi}+1=0</span></p>',
      );
      final p = result[0] as ParagraphNode;
      final m = p.inlines.whereType<MathInlineRun>().single;
      expect(m.latex, r'e^{i\pi}+1=0');
    });

    test('空 div.math → 不产 MathBlockNode', () {
      final result = parser.parse('<div class="math">   </div>');
      expect(result.whereType<MathBlockNode>(), isEmpty);
    });

    test('空 span.math → 不产 MathInlineRun(降级展平)', () {
      final result = parser.parse('<p>x<span class="math"></span>y</p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<MathInlineRun>(), isEmpty);
    });

    test('普通 div / span 不识别', () {
      final r1 = parser.parse('<div>不是 math</div>');
      final r2 = parser.parse('<p><span>不是 math</span></p>');
      expect(r1.whereType<MathBlockNode>(), isEmpty);
      expect(
        (r2[0] as ParagraphNode).inlines.whereType<MathInlineRun>(),
        isEmpty,
      );
    });

    test('text trim(前后空白)', () {
      final result = parser.parse(
        r'<div class="math">   \int_0^1 x\,dx   </div>',
      );
      expect((result[0] as MathBlockNode).latex, r'\int_0^1 x\,dx');
    });

    test('多个 inline math 各自独立', () {
      final result = parser.parse(
        '<p><span class="math">a</span> 与 <span class="math">b</span></p>',
      );
      final inlines = (result[0] as ParagraphNode).inlines;
      final maths = inlines.whereType<MathInlineRun>().toList();
      expect(maths, hasLength(2));
      expect(maths[0].latex, 'a');
      expect(maths[1].latex, 'b');
    });

    test('MathBlockNode / MathInlineRun ==/hashCode 按 latex', () {
      const a = MathBlockNode(id: 'b_0', latex: 'x=1');
      const b = MathBlockNode(id: 'b_99', latex: 'x=1');
      const c = MathBlockNode(id: 'b_0', latex: 'x=2');
      expect(a, b);
      expect(a, isNot(c));
      const i1 = MathInlineRun('y');
      const i2 = MathInlineRun('y');
      expect(i1, i2);
    });

    test('countImageRuns 不计 math 节点', () {
      final result = parser.parse(
        '<p><img src="a.png"><span class="math">x</span></p>'
        '<div class="math">y</div>',
      );
      expect(countImageRuns(result), 1);
    });

    test('id 唯一(多个 block math)', () {
      final result = parser.parse(
        '<div class="math">a</div><div class="math">b</div>',
      );
      expect(result, hasLength(2));
      final m1 = result[0] as MathBlockNode;
      final m2 = result[1] as MathBlockNode;
      expect(m1.id, isNot(m2.id));
    });
  });
}

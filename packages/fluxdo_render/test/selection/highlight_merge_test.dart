import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/selection/selection_highlight_painter.dart';

void main() {
  TextBox box(double l, double t, double r, double b) =>
      TextBox.fromLTRBD(l, t, r, b, TextDirection.ltr);

  group('mergeSelectionBoxesByLine', () {
    test('同行文字 + 偏高 emoji → 合并成统一行高(union)', () {
      // 文字 box 高 16(t4~b20),emoji box 高 32(t-4~b28),同一行。
      final merged = mergeSelectionBoxesByLine([
        box(0, 4, 50, 20),
        box(50, -4, 82, 28),
        box(82, 4, 120, 20),
      ]);
      expect(merged.length, 1, reason: '同行合并成一个');
      final r = merged.first;
      expect(r.top, -4, reason: 'union 取最高');
      expect(r.bottom, 28);
      expect(r.left, 0);
      expect(r.right, 120, reason: '水平铺满');
    });

    test('跨行(有间隙)绝不合并', () {
      // tight 行间隙:line1 b19.6,line2 t26.6。
      final merged = mergeSelectionBoxesByLine([
        box(48, 3.6, 97, 19.6), // line1 尾
        box(0, 26.6, 97, 42.6), // line2
        box(0, 49.6, 65, 65.6), // line3
      ]);
      expect(merged.length, 3, reason: '三行各自独立,绝不跨行合并');
    });

    test('跨行 + 行内 emoji 混合:行数正确、各行 union', () {
      final merged = mergeSelectionBoxesByLine([
        box(48, 4, 97, 20), // line1 文字
        box(0, 26, 30, 42), // line2 文字
        box(30, 18, 62, 50), // line2 emoji(偏高,与 line2 文字同行)
        box(62, 26, 97, 42), // line2 文字
      ]);
      expect(merged.length, 2, reason: 'line1 + line2,共两行');
      // line2 含 emoji(t18~b50),是更高的那个矩形;取 union 后 top=18 bottom=50。
      final line2 = merged.reduce((a, b) => a.height >= b.height ? a : b);
      expect(line2.top, 18);
      expect(line2.bottom, 50);
    });

    test('相邻行 1px 微重叠不误并(过半判定)', () {
      // line1 b20,line2 t19.5(重叠 0.5px,远小于行高一半)→ 不合并。
      final merged = mergeSelectionBoxesByLine([
        box(0, 4, 97, 20),
        box(0, 19.5, 97, 35.5),
      ]);
      expect(merged.length, 2, reason: '1px 微重叠不算同行');
    });

    test('空 / 单 box', () {
      expect(mergeSelectionBoxesByLine([]), isEmpty);
      final one = mergeSelectionBoxesByLine([box(5, 10, 55, 30)]);
      expect(one.length, 1);
      expect(one.first, const Rect.fromLTRB(5, 10, 55, 30));
    });
  });
}

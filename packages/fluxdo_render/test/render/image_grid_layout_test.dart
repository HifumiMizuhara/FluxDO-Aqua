/// 瀑布流分列算法(官方 columns.js + d-image-grid.scss):列数派生、
/// 最短列贪心、**列等高化**(高度差平分,底边平齐)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';
import 'package:fluxdo_render/src/render/image_grid_layout.dart';

ImageRun _img(double w, double h) => ImageRun(src: 's', width: w, height: h);

void main() {
  test('列数:2/4 张 2 列,3/5+ 张 3 列;显式 ≥3 尊重', () {
    expect(gridColumnCount(2, 2), 2);
    expect(gridColumnCount(4, 2), 2);
    expect(gridColumnCount(3, 2), 3);
    expect(gridColumnCount(5, 2), 3);
    expect(gridColumnCount(6, 4), 4);
  });

  test('最短列贪心:高图后续图流向其他列', () {
    final cols = distributeGridImages([
      _img(100, 300), // 高图 → 列 0(ratio 3)
      _img(100, 100), // → 列 1
      _img(100, 100), // → 列 2
      _img(100, 100), // 列 1/2 均 1,取更靠前的列 1
    ], 3);
    expect(cols[0].map((e) => e.$1), [0]);
    expect(cols[1].map((e) => e.$1), [1, 3]);
    expect(cols[2].map((e) => e.$1), [2]);
  });

  test('等高化:各列总高(含间距)完全一致,底边平齐', () {
    const colWidth = 200.0;
    const spacing = 6.0;
    final cols = distributeGridImages([
      _img(200, 600), // ratio 3 → 列 0 natural 600
      _img(200, 200), // → 列 1 natural 200
      _img(200, 100), // → 列 2 natural 100
      _img(200, 100), // 最短列 2 → natural +100(+spacing)
    ], 3);
    final heights = gridEqualizedTileHeights(cols, colWidth, spacing);

    double colTotal(int c) =>
        heights[c].fold(0.0, (a, b) => a + b) +
        (heights[c].length - 1) * spacing;
    expect(colTotal(0), closeTo(colTotal(1), 0.001));
    expect(colTotal(1), closeTo(colTotal(2), 0.001));
    // 目标高 = 最高列(列 0 = 600)
    expect(colTotal(0), closeTo(600, 0.001));
    // 列 2 两张图平分差额:natural 100+100+6=206,差 394 → 每张 +197
    expect(heights[2][0], closeTo(297, 0.001));
    expect(heights[2][1], closeTo(297, 0.001));
  });

  test('超高图 cap 1200(官方 max-height)', () {
    expect(gridTileHeight(_img(100, 10000), 300), 1200);
  });
}

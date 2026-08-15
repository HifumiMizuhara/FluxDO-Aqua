/// 瀑布流分列算法(官方 columns.js 对齐)—— 阅读端 buildImageGrid 与
/// 编辑器 EditorImageGrid 共用。
library;

import '../node/inline_node.dart';

/// 官方 count():2/4 张 2 列,其余 3 列;显式 ≥3 列(web 已分列的
/// cooked 形态)尊重。调用方保证 images.length ≥ 2。
int gridColumnCount(int imageCount, int declaredColumns) => declaredColumns >= 3
    ? declaredColumns.clamp(3, 6)
    : ((imageCount == 2 || imageCount == 4) ? 2 : 3);

/// 最短列贪心分配(官方 _distributeEvenly):按宽高比累计列高,逐图放
/// 最短列。返回每列的 (原始 index, ImageRun) 列表 —— index 供编辑器
/// 子选中/删除定位。
List<List<(int, ImageRun)>> distributeGridImages(
  List<ImageRun> images,
  int cols,
) {
  final columns = List.generate(cols, (_) => <(int, ImageRun)>[]);
  final heights = List.filled(cols, 0.0);
  for (var i = 0; i < images.length; i++) {
    final img = images[i];
    var shortest = 0;
    for (var j = 1; j < cols; j++) {
      if (heights[j] < heights[shortest]) shortest = j;
    }
    final ratio = (img.width != null && img.height != null && img.width! > 0)
        ? img.height! / img.width!
        : 1.0;
    heights[shortest] += ratio;
    columns[shortest].add((i, img));
  }
  return columns;
}

/// 瓦片自然高:填满列宽、高按自身宽高比;cap 1200 逻辑像素(官方
/// `max-height: 1200px`,防长截图对网格产生离谱影响),无尺寸按 1:1。
double gridTileHeight(ImageRun img, double columnWidth) {
  final w = img.width;
  final h = img.height;
  if (w != null && h != null && w > 0) {
    return (columnWidth * (h / w)).clamp(60.0, 1200.0);
  }
  return columnWidth;
}

/// 列内瓦片高度(官方 `.d-image-grid-column > div { flex-grow: 1 }`):
/// 三列**强制等高** —— 目标列高 = 最高列的内容高,其余列的高度差
/// **平分**给列内每张图(cover 裁切吸收)。这是官方网格底部平齐、
/// 观感紧凑的关键;纯瀑布(列尾错落)不是官方形态。
///
/// 返回与 [columns] 同构的高度表。[spacing] 是瓦片纵向间距(计算内容
/// 高时扣除,间距本身不参与拉伸)。
List<List<double>> gridEqualizedTileHeights(
  List<List<(int, ImageRun)>> columns,
  double columnWidth,
  double spacing,
) {
  final natural = [
    for (final col in columns)
      [for (final (_, img) in col) gridTileHeight(img, columnWidth)],
  ];
  // 列内容高 = 瓦片高之和(列内间距各列相同仅当图数相同;把间距计入
  // 总高再比,等高才对得齐底边)
  final contentHeights = <double>[
    for (final col in natural)
      col.fold(0.0, (a, b) => a + b) +
          (col.isEmpty ? 0 : (col.length - 1) * spacing),
  ];
  final target = contentHeights.fold(0.0, (a, b) => a > b ? a : b);
  return [
    for (var c = 0; c < natural.length; c++)
      [
        for (final h in natural[c])
          natural[c].isEmpty
              ? h
              : h + (target - contentHeights[c]) / natural[c].length,
      ],
  ];
}

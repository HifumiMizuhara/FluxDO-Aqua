/// 把全局 [DocumentSelection] 拆成「每个块的渲染偏移区间」。
///
/// 高亮(各块画自己的 box)和复制(各块投影自己的文本)都要用。归一化:
/// 按文档/视觉序 `(chunkIndex, docOrder)` 定 start/end,端点块截 renderOffset,
/// 中间块整段。**纯逻辑序 + 逻辑块表 projection**:中间/端点块即使滚出视口被
/// 回收,也能算出区间与文本(对齐 Flutter SelectionArea / CodeMirror state.doc)。
library;

import 'projection.dart';
import 'selection_geometry.dart';
import 'selection_registry.dart';

/// 单块的渲染偏移区间 `[start, end)`。
///
/// 持 [id] + [projection] 逻辑快照(非 live handle)→ 回收块照样能复制;
/// 需要几何(高亮/锚点)时调用方按 [id] 向 registry 取 live handle(可能为 null)。
class BlockRange {
  const BlockRange(this.id, this.projection, this.start, this.end);
  final SelectableBlockId id;
  final RenderTextProjection projection;
  final int start;
  final int end;
  bool get isEmpty => start >= end;
}

/// 按文档/视觉序展开 selection,返回涉及的每个块及其渲染偏移区间。
///
/// 单块选区:返回该块一段(start/end 按 renderOffset 排序)。
/// 跨块选区:首块 [startOffset, len)、中间块整段、末块 [0, endOffset)。
/// 端点块不在逻辑块表(从未注册过)时返回空列表。
List<BlockRange> expandSelection(
  SelectionRegistry registry,
  DocumentSelection selection,
) {
  final order = registry.orderedBlocks();
  if (order.isEmpty) return const [];

  int indexOf(SelectableBlockId id) {
    for (var i = 0; i < order.length; i++) {
      if (order[i].id == id) return i;
    }
    return -1;
  }

  final baseIdx = indexOf(selection.base.blockId);
  final extentIdx = indexOf(selection.extent.blockId);
  if (baseIdx < 0 || extentIdx < 0) return const [];

  // 归一化:确定文档序上的 (startIdx, startOffset) → (endIdx, endOffset)
  late int startIdx, endIdx, startOffset, endOffset;
  if (baseIdx < extentIdx ||
      (baseIdx == extentIdx &&
          selection.base.renderOffset <= selection.extent.renderOffset)) {
    startIdx = baseIdx;
    startOffset = selection.base.renderOffset;
    endIdx = extentIdx;
    endOffset = selection.extent.renderOffset;
  } else {
    startIdx = extentIdx;
    startOffset = selection.extent.renderOffset;
    endIdx = baseIdx;
    endOffset = selection.base.renderOffset;
  }

  final result = <BlockRange>[];
  for (var i = startIdx; i <= endIdx; i++) {
    final b = order[i];
    final len = b.projection.renderLength;
    final s = (i == startIdx) ? startOffset : 0;
    final e = (i == endIdx) ? endOffset : len;
    final cs = s.clamp(0, len);
    final ce = e.clamp(0, len);
    if (cs < ce) result.add(BlockRange(b.id, b.projection, cs, ce));
  }
  return result;
}

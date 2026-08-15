/// 键盘选区导航原语 —— 纯逻辑函数,输入 [SelectionController] + 当前选区,
/// 产出新 [DocumentSelection] 并直接赋给 `controller.selection`(setter 触发
/// 协调器 + 通知,与鼠标/触摸扩选共用一条收敛路径)。
///
/// 设计对齐编辑器的「光标导航」语义(CodeMirror/ProseMirror/Flutter EditableText):
/// - 选区是逻辑模型,base 锚点不动,只动 extent(Shift+方向 = 扩选)。
/// - Cmd/Ctrl+A 全选 = base 首块起点、extent 末块终点(用 registry 的逻辑
///   文档序取首末块,不读 live 几何 → 虚拟化/回收下稳定)。
/// - 逐字符越界跳相邻块边界;逐行用可见块的 RenderParagraph 行框几何,相邻块
///   off-screen(未 mount,无 paragraph)时退化为按字符跳到相邻块边界。
library;

import 'package:flutter/rendering.dart';

import 'block_text_geometry.dart';
import 'selection_geometry.dart';
import 'selection_registry.dart';

/// 选区键盘导航的纯逻辑实现。所有方法都是「读 controller.selection + registry
/// → 算新选区 → 写回 controller.selection」。registry 取自 controller。
class SelectionNavigator {
  const SelectionNavigator._();

  /// 全选:base = 首块 renderOffset 0,extent = 末块 renderOffset = 末块 renderLength。
  ///
  /// 用 [SelectionRegistry.orderedBlocks](逻辑文档序,含回收块)取首末块;
  /// 列表为空(无可选块)则不操作。
  static void selectAll(SelectionController controller) {
    final blocks = controller.registry.orderedBlocks();
    if (blocks.isEmpty) return;
    final first = blocks.first;
    final last = blocks.last;
    controller.selection = DocumentSelection(
      base: DocumentPosition(blockId: first.id, renderOffset: 0),
      extent: DocumentPosition(
        blockId: last.id,
        renderOffset: last.renderLength,
      ),
    );
  }

  /// 逐字符移动 extent(base 不变)。
  ///
  /// extent.renderOffset ±1;越界(<0 或 > 该块 renderLength)则跳到相邻块
  /// (orderedBlocks 里的前/后一块)边界:后退到上一块的 renderLength,前进到
  /// 下一块的 0。到文档首/尾则 clamp 不动。无选区时不操作。
  static void moveExtentByCharacter(
    SelectionController controller, {
    required bool forward,
  }) {
    final sel = controller.selection;
    if (sel == null) return;
    final registry = controller.registry;
    final blocks = registry.orderedBlocks();
    if (blocks.isEmpty) return;

    final idx = _indexOf(blocks, sel.extent.blockId);
    if (idx < 0) return;

    final curLen = blocks[idx].renderLength;
    final next = forward
        ? sel.extent.renderOffset + 1
        : sel.extent.renderOffset - 1;

    DocumentPosition newExtent;
    if (next < 0) {
      // 退到上一块末尾;已是首块 → clamp 到 0 不动。
      if (idx == 0) {
        newExtent = sel.extent.copyWith(renderOffset: 0);
      } else {
        final prev = blocks[idx - 1];
        newExtent = DocumentPosition(
          blockId: prev.id,
          renderOffset: prev.renderLength,
        );
      }
    } else if (next > curLen) {
      // 进到下一块开头;已是末块 → clamp 到该块末尾不动。
      if (idx == blocks.length - 1) {
        newExtent = sel.extent.copyWith(renderOffset: curLen);
      } else {
        final nextBlock = blocks[idx + 1];
        newExtent = DocumentPosition(blockId: nextBlock.id, renderOffset: 0);
      }
    } else {
      newExtent = sel.extent.copyWith(renderOffset: next);
    }

    if (newExtent == sel.extent) return; // 无变化(文档首/尾 clamp)→ 不通知
    controller.selection = sel.copyWith(extent: newExtent);
  }

  /// 逐行移动 extent(base 不变)。
  ///
  /// 用 extent 所在**可见**块的 RenderParagraph 行框:取 caret 处 box 的
  /// (x, y, 行高),目标点 =(同 x,y ± 行高),`getPositionForOffset` 得到新
  /// renderOffset。若目标行越出该块上/下边界,则跳到相邻块边界(相邻块可能
  /// off-screen → 退化为按字符跳到相邻块边界,best-effort)。
  ///
  /// extent 所在块本身 off-screen(无 paragraph)→ 无行几何可用 → 退化为按
  /// 字符移动一步(best-effort,见类注释)。无选区时不操作。
  static void moveExtentByLine(
    SelectionController controller, {
    required bool down,
  }) {
    final sel = controller.selection;
    if (sel == null) return;
    final registry = controller.registry;
    final blocks = registry.orderedBlocks();
    if (blocks.isEmpty) return;

    final idx = _indexOf(blocks, sel.extent.blockId);
    if (idx < 0) return;

    final geometry = registry.byId(sel.extent.blockId)?.geometry;
    if (geometry == null) {
      // extent 块 off-screen,无行几何 → 退化按字符(best-effort)。
      moveExtentByCharacter(controller, forward: down);
      return;
    }

    final caret = _caretBox(geometry, sel.extent.renderOffset);
    if (caret == null) {
      moveExtentByCharacter(controller, forward: down);
      return;
    }

    final lineHeight = (caret.bottom - caret.top).abs();
    // 行高异常(0/NaN)→ 退化按字符。
    if (!lineHeight.isFinite || lineHeight <= 0) {
      moveExtentByCharacter(controller, forward: down);
      return;
    }

    // 目标 y:向上取行框中线上移一行,向下取行框中线下移一行。用中线避免落在
    // 行边界 ±0.5px 抖动。
    final midY = (caret.top + caret.bottom) / 2;
    final targetY = down ? midY + lineHeight : midY - lineHeight;
    final size = geometry.renderBox.size;

    if (targetY < 0) {
      // 越过本块顶部 → 跳上一块末边界。
      _jumpToAdjacentBlock(controller, blocks, idx, down: false);
      return;
    }
    if (targetY > size.height) {
      // 越过本块底部 → 跳下一块起边界。
      _jumpToAdjacentBlock(controller, blocks, idx, down: true);
      return;
    }

    // 同块内逐行:目标点 (caret 中点 x, targetY)。
    final targetX = (caret.left + caret.right) / 2;
    final tp = geometry.getPositionForOffset(Offset(targetX, targetY));
    final newExtent = sel.extent.copyWith(renderOffset: tp.offset);
    if (newExtent == sel.extent) return;
    controller.selection = sel.copyWith(extent: newExtent);
  }

  /// 逐行越界跳相邻块边界:有相邻块则跳其边界(下一块起点 0 / 上一块末尾
  /// renderLength);无相邻块(文档首/尾)则不动。
  static void _jumpToAdjacentBlock(
    SelectionController controller,
    List<LogicalBlock> blocks,
    int idx, {
    required bool down,
  }) {
    final sel = controller.selection;
    if (sel == null) return;
    if (down) {
      if (idx >= blocks.length - 1) return; // 已是末块
      final nextBlock = blocks[idx + 1];
      controller.selection = sel.copyWith(
        extent: DocumentPosition(blockId: nextBlock.id, renderOffset: 0),
      );
    } else {
      if (idx <= 0) return; // 已是首块
      final prev = blocks[idx - 1];
      controller.selection = sel.copyWith(
        extent: DocumentPosition(
          blockId: prev.id,
          renderOffset: prev.renderLength,
        ),
      );
    }
  }

  /// 取某渲染偏移处 caret 的行框(paragraph 局部坐标)。
  ///
  /// 优先用 [offset, offset+1] 的 box(caret 右侧字符行框);末尾偏移
  /// (offset == 末尾,右侧无字符)退化用 [offset-1, offset] 的 box。都取不到
  /// (空块)返回 null。
  static Rect? _caretBox(BlockTextGeometry geometry, int offset) {
    // 先试右侧字符框。
    final right = geometry.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
    );
    if (right.isNotEmpty) return right.first.toRect();
    // 末尾:试左侧字符框。
    if (offset > 0) {
      final left = geometry.getBoxesForSelection(
        TextSelection(baseOffset: offset - 1, extentOffset: offset),
      );
      if (left.isNotEmpty) return left.last.toRect();
    }
    return null;
  }

  /// 在已排序逻辑块列表里找某 blockId 的下标;找不到返回 -1。
  static int _indexOf(List<LogicalBlock> blocks, SelectableBlockId id) {
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].id == id) return i;
    }
    return -1;
  }
}

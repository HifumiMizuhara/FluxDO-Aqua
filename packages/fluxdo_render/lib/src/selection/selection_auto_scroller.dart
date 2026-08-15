/// 选区边缘自动滚 —— 拖选/拖托柄时,统一驱动「外层页面 Scrollable + 拖拽点
/// 所在块的内部滚动器」(代码块横滚/限高纵滚等)的边缘自动滚动。
///
/// 对齐 Flutter SDK 的分层语义:SDK 里每个 Scrollable 都自带
/// _ScrollableSelectionContainerDelegate,选区端点拖出自己视口时**各自**
/// 自动滚自己的轴。自研选区的手势/托柄在顶层统一处理,故由本类扫描
/// 拖拽点命中的块,把它注册的内部滚动器(SelectableBlockHandle
/// .interiorScrollablesGetter)一并纳入边缘自动滚;每次滚动后通过
/// [onScrolled] 让调用方按钉住的指针位置 re-extend(滚动扩选)。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'selection_registry.dart';

class SelectionEdgeAutoScroller {
  SelectionEdgeAutoScroller({
    required this.registry,
    this.outerScrollable,
    this.onScrolled,
    this.velocityScalar = 30,
  });

  final SelectionRegistry registry;

  /// 外层(页面级)Scrollable;可为 null(无滚动容器的场景,如用户卡 bio)。
  /// 祖先变化时由调用方更新。
  ScrollableState? outerScrollable;

  /// 任一滚动器滚动一步后回调 —— 调用方在此按钉住的指针位置重新命中/扩选。
  final VoidCallback? onScrolled;

  final double velocityScalar;

  final Map<ScrollableState, EdgeDraggingAutoScroller> _scrollers = {};

  /// 最近一次 [update] 的拖拽点。滚动一步后用它续滚(见 [_onScrolledInternal]);
  /// [stop] 置 null 作为续滚回路的闸门。
  Offset? _lastGlobal;

  /// 拖拽点移动时每帧调:驱动外层 + 拖拽点所在块的内部滚动器。
  void update(Offset global) {
    _lastGlobal = global;
    final driven = <ScrollableState>{};
    final outer = outerScrollable;
    if (outer != null && outer.mounted) {
      _drive(outer, global);
      driven.add(outer);
    }
    // 内部滚动器:仅拖拽点落在(或贴近)该块可视区时驱动。inflate 24:
    // 托柄拖拽点/手指略出块边缘时仍能触发(与 60px 触发带同数量级)。
    for (final h in registry.liveHandles) {
      final getter = h.interiorScrollablesGetter;
      if (getter == null) continue;
      final rect = h.clipBoundsGetter?.call() ?? h.globalRect();
      if (rect == null || !rect.inflate(24).contains(global)) continue;
      for (final s in getter()) {
        if (!s.mounted || driven.contains(s)) continue;
        _drive(s, global);
        driven.add(s);
      }
    }
    // 本轮未驱动的(指针已离开其块):立即停 —— EdgeDraggingAutoScroller
    // 的内部循环会按最后一次 dragTarget 一直滚到头,不停会「惯性滚到底」。
    _scrollers.removeWhere((s, scroller) {
      if (driven.contains(s)) return false;
      scroller.stopAutoScroll();
      return true;
    });
  }

  /// 滚动一步后:先让调用方 re-extend,再用最新拖拽点**续滚**。
  ///
  /// EdgeDraggingAutoScroller 的 dragTarget 锚定在 scroll-origin 坐标系,
  /// 内容滚过一步(≤20px)后指针相对内容不再贴边 → 内部循环自停;指针物理
  /// 静止在边缘时不会再有 move 事件重新触发。SDK ReorderableList 同款回路:
  /// onScrollViewScrolled → 再次 startAutoScrollIfNecessary,持续滚到头。
  void _onScrolledInternal() {
    final g = _lastGlobal;
    if (g == null) return; // 已 stop,不再续滚(防 stop 后回调重启滚动)
    onScrolled?.call();
    update(g);
  }

  void _drive(ScrollableState s, Offset global) {
    final scroller = _scrollers.putIfAbsent(
      s,
      () => EdgeDraggingAutoScroller(
        s,
        onScrollViewScrolled: _onScrolledInternal,
        velocityScalar: velocityScalar,
      ),
    );
    // 触发带按该滚动器的轴向展开(60 → 距边缘约 30px 即触发,比 1px 命中
    // 边缘更跟手),但夹到不超过滚动器视口尺寸(EdgeDraggingAutoScroller
    // assert:dragTarget 不得大于 scrollable;代码块视口可矮于 60);另一轴
    // 给 1px,避免误触发交叉轴。
    final box = s.context.findRenderObject();
    final viewport = (box is RenderBox && box.hasSize) ? box.size : null;
    final axis = axisDirectionToAxis(s.axisDirection);
    final band = axis == Axis.horizontal
        ? math.min(60.0, math.max(1.0, (viewport?.width ?? 60) - 1))
        : math.min(60.0, math.max(1.0, (viewport?.height ?? 60) - 1));
    final target = axis == Axis.horizontal
        ? Rect.fromCenter(center: global, width: band, height: 1)
        : Rect.fromCenter(center: global, width: 1, height: band);
    scroller.startAutoScrollIfNecessary(target);
  }

  /// 松手/取消:停掉全部自动滚。
  void stop() {
    _lastGlobal = null; // 关续滚闸门(in-flight 的 onScrollViewScrolled 不再重启)
    for (final scroller in _scrollers.values) {
      scroller.stopAutoScroll();
    }
    _scrollers.clear();
  }
}

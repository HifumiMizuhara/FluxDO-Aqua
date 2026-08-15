/// 可选块的句柄 —— registry 通过它访问某个文本块的文本几何 + 映射表。
///
/// **不缓存 RenderObject / 几何**(已探针实测:虚拟列表滚出视口块会被回收,
/// 滚回重建 RenderObject 会换新)。全部 getter 实时取,保证虚拟化/滚动安全。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show ScrollableState;

import 'block_text_geometry.dart';
import 'projection.dart';
import 'selection_geometry.dart';

/// 一个可选文本块的访问句柄。
abstract class SelectableBlockHandle {
  SelectableBlockId get id;

  /// 实时取当前 RenderParagraph;块未 mount / 已回收时返回 null(调用方跳过)。
  ///
  /// 仅编辑器路径(光标/IME 需要 TextPainter 级精确 caret)与
  /// InlineCodeBackgroundPainter 直读;阅读态选区消费方一律走 [geometry]
  /// (直绘块没有 RenderParagraph,只有几何)。
  RenderParagraph? get paragraph;

  /// 实时取文本几何(选区/高亮/命中/导出的统一入口)。
  /// 默认包装 [paragraph];直绘块覆写本 getter 返回自己的几何实现。
  BlockTextGeometry? get geometry {
    final p = paragraph;
    return p == null ? null : ParagraphGeometry(p);
  }

  /// 渲染偏移 ↔ 逻辑投影 映射表(随块内容更新)。
  RenderTextProjection get projection;

  /// 可选的「可视区裁剪矩形」getter(全局坐标)。块在内部滚动容器里时
  /// (如代码块的 SizedBox 限高 + SingleChildScrollView),RenderParagraph.size
  /// 是完整内容尺寸(可达上万 px),直接用会让命中框溢出、误命中相邻块。
  /// 由块自身注入其可视外框(如代码块的限高 SizedBox)→ globalRect 与之求交。
  /// null = 不裁剪(普通段落)。
  Rect? Function()? get clipBoundsGetter => null;

  /// 可选的「内部滚动器链」getter:块自身到选区作用域(SelectionScope)之间的
  /// 全部 Scrollable(代码块的横滚 + 限高纵滚、表格的横滚)。拖选/拖托柄到这些
  /// 滚动器的视口边缘时,选区层驱动其边缘自动滚(对齐 SDK 每个 Scrollable 自带
  /// _ScrollableSelectionContainerDelegate 自滚自轴)。null/空 = 无内部滚动
  /// (普通段落)。实时取,不缓存(虚拟化安全)。
  List<ScrollableState> Function()? get interiorScrollablesGetter => null;

  /// 块在全局坐标系的矩形(用于视觉序排序 + 命中)。null = 不可用。
  Rect? globalRect() {
    final g = geometry;
    if (g == null || !g.isLive) return null;
    final origin = g.renderBox.localToGlobal(Offset.zero);
    // keepAlive 保活但移出视口的块可能无有效 paint 变换 → localToGlobal 出
    // NaN/Infinity。这种几何无效,不能进视觉序/选区(否则 toolbar 定位 NaN 崩)。
    if (!origin.dx.isFinite || !origin.dy.isFinite) return null;
    final raw = origin & g.renderBox.size;
    final clip = clipBoundsGetter?.call();
    if (clip == null) return raw;
    final r = raw.intersect(clip);
    return (r.width <= 0 || r.height <= 0) ? null : r;
  }
}

/// 基于回调的默认实现 —— InlineSpanText 用 closure 提供 paragraph/projection。
class CallbackBlockHandle extends SelectableBlockHandle {
  CallbackBlockHandle({
    required this.id,
    required RenderParagraph? Function() paragraphGetter,
    required RenderTextProjection Function() projectionGetter,
    BlockTextGeometry? Function()? geometryGetter,
    Rect? Function()? clipBoundsGetter,
    List<ScrollableState> Function()? interiorScrollablesGetter,
  }) : _paragraphGetter = paragraphGetter,
       _projectionGetter = projectionGetter,
       _geometryGetter = geometryGetter,
       _clipBoundsGetter = clipBoundsGetter,
       _interiorScrollablesGetter = interiorScrollablesGetter;

  @override
  final SelectableBlockId id;

  final RenderParagraph? Function() _paragraphGetter;
  final RenderTextProjection Function() _projectionGetter;
  final BlockTextGeometry? Function()? _geometryGetter;
  final Rect? Function()? _clipBoundsGetter;
  final List<ScrollableState> Function()? _interiorScrollablesGetter;

  @override
  RenderParagraph? get paragraph => _paragraphGetter();

  @override
  BlockTextGeometry? get geometry {
    final getter = _geometryGetter;
    if (getter != null) return getter();
    return super.geometry;
  }

  @override
  RenderTextProjection get projection => _projectionGetter();

  @override
  Rect? Function()? get clipBoundsGetter => _clipBoundsGetter;

  @override
  List<ScrollableState> Function()? get interiorScrollablesGetter =>
      _interiorScrollablesGetter;
}

/// 列表项悬挂布局 — 复刻浏览器 `list-style-position: outside` 语义。
///
/// 移植自 flutter_widget_from_html_core 0.17.2 的 `HtmlListItem`(MIT),
/// 保留其核心布局算法,按本项目需求做两处调整:
///
/// 1. **content 收 tight 宽度**(约束有界时):对齐旧实现 `Row + Expanded`
///    行为 —— 每个 li 等宽铺满,横向滚动块(代码块/表格)拿到确定可用宽;
///    fwfh 原版是 loose,窄内容会导致 li 宽度逐项抖动。
/// 2. 无序 marker 用 [ListMarkerDot](自绘形状but携带文本基线),而非 fwfh
///    的字形绘制 —— 沿用旧版 6px disc/circle/square 视觉,跨字体一致。
///
/// 布局规则(与浏览器/fwfh 一致):
/// - content 独占布局宽度(marker 不占位);
/// - marker 松约束取自然宽度,右缘悬挂在 content 左缘外 [kGapVsMarker] 处
///   (`dx = -(markerWidth + gap)`),数字位数多长向左延伸多长,永不换行;
/// - marker 与 content 首行**基线对齐**(`dy = childBaseline - markerBaseline`),
///   任一侧无基线时回退顶对齐。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// marker 右缘与 content 左缘的间隙(fwfh 原值)。
const double kGapVsMarker = 5.0;

/// 列表项:content + 悬挂 marker。
class HtmlListItem extends MultiChildRenderObjectWidget {
  HtmlListItem({
    super.key,
    required Widget child,
    Widget? marker,
    required this.textDirection,
  }) : super(children: [child, ?marker]);

  final TextDirection textDirection;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ListItemRenderObject(textDirection: textDirection);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _ListItemRenderObject).textDirection = textDirection;

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty('textDirection', textDirection));
  }
}

class _ListItemData extends ContainerBoxParentData<RenderBox> {}

class _ListItemRenderObject extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ListItemData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ListItemData> {
  _ListItemRenderObject({required TextDirection textDirection})
    : _textDirection = textDirection;

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _compute(firstChild, constraints, ChildLayoutHelper.dryLayoutChild);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      firstChild?.computeMaxIntrinsicHeight(width) ??
      super.computeMaxIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      firstChild?.computeMaxIntrinsicWidth(height) ??
      super.computeMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      firstChild?.computeMinIntrinsicHeight(width) ??
      super.computeMinIntrinsicHeight(width);

  @override
  double computeMinIntrinsicWidth(double height) =>
      firstChild?.getMinIntrinsicWidth(height) ??
      super.computeMinIntrinsicWidth(height);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  void performLayout() =>
      size = _compute(firstChild, constraints, ChildLayoutHelper.layoutChild);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ListItemData) {
      child.parentData = _ListItemData();
    }
  }

  Size _compute(RenderBox? child, BoxConstraints bc, ChildLayouter fn) {
    if (child == null) return bc.smallest;

    // content 收 tight 宽(约束有界时)→ li 等宽铺满,对齐旧 Row+Expanded;
    // 无界(如被放进横向滚动)退回原约束取自然宽。
    final childBc = bc.hasBoundedWidth ? bc.tighten(width: bc.maxWidth) : bc;
    final childData = child.parentData! as _ListItemData;
    final childSize = fn(child, childBc);
    final marker = childData.nextSibling;
    // marker 松约束取自然宽度 → 任意位数永不换行(悬挂,不占 content 宽)。
    final markerSize = marker != null ? fn(marker, bc.loosen()) : Size.zero;
    final height = childSize.height > 0 ? childSize.height : markerSize.height;
    final size = bc.constrain(Size(childSize.width, height));

    if (identical(fn, ChildLayoutHelper.layoutChild) && marker != null) {
      const baseline = TextBaseline.alphabetic;
      // 基线对齐:marker 基线贴 content 首行基线;拿不到基线时回退顶对齐。
      final markerDistance =
          marker.getDistanceToBaseline(baseline, onlyReal: true) ??
          markerSize.height;
      final childDistance =
          child.getDistanceToBaseline(baseline, onlyReal: true) ??
          markerDistance;

      final markerData = marker.parentData! as _ListItemData;
      markerData.offset = Offset(
        textDirection == TextDirection.ltr
            ? -markerSize.width - kGapVsMarker
            : childSize.width + kGapVsMarker,
        childDistance - markerDistance,
      );
    }

    return size;
  }
}

/// 无序列表 marker:自绘 disc/circle/square(沿用旧版 6px 视觉),
/// 但携带**文本基线**(按 [textStyle] 排一行 "1." 取 metrics)——
/// [HtmlListItem] 才能把它与 content 首行基线对齐;纯 Container 无基线,
/// 悬挂后会相对文字垂直漂移。
///
/// 垂直位置沿用 fwfh 公式:圆心 ≈ 基线上方 0.7 × ascent(近似 x-height 中心)。
class ListMarkerDot extends LeafRenderObjectWidget {
  const ListMarkerDot({
    super.key,
    required this.depth,
    required this.color,
    required this.textStyle,
  });

  /// 嵌套深度:0 实心圆 disc / 1 空心圆 circle / ≥2 实心方块 square
  /// (对齐浏览器 CSS list-style 级联)。
  final int depth;
  final Color color;

  /// 用于取行高/基线 metrics(应与 li 首行文本样式一致)。
  final TextStyle textStyle;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ListMarkerDotRender(depth, color, textStyle);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _ListMarkerDotRender)
      ..depth = depth
      ..color = color
      ..textStyle = textStyle;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(DiagnosticsProperty('depth', depth))
      ..add(DiagnosticsProperty('color', color))
      ..add(DiagnosticsProperty('textStyle', textStyle));
  }
}

class _ListMarkerDotRender extends RenderBox {
  _ListMarkerDotRender(this._depth, this._color, this._textStyle);

  /// 形状边长(旧版 _markerShape 的 6px)。
  static const double _shapeSize = 6.0;

  int _depth;
  set depth(int v) {
    if (v == _depth) return;
    _depth = v;
    markNeedsPaint();
  }

  Color _color;
  set color(Color v) {
    if (v == _color) return;
    _color = v;
    markNeedsPaint();
  }

  TextStyle _textStyle;
  set textStyle(TextStyle v) {
    if (v == _textStyle) return;
    _textStyle = v;
    _painter?.dispose();
    _painter = null;
    markNeedsLayout();
  }

  TextPainter? _painter;
  final _lineMetrics = <LineMetrics>[];

  TextPainter get _textPainter {
    final existing = _painter;
    if (existing != null) return existing;
    final painter = _painter = TextPainter(
      text: TextSpan(style: _textStyle, text: '1.'),
      textDirection: TextDirection.ltr,
    )..layout();
    _lineMetrics
      ..clear()
      ..addAll(painter.computeLineMetrics());
    return painter;
  }

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) =>
      _textPainter.computeDistanceToActualBaseline(baseline);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(_shapeSize, _textPainter.height));

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final m = _lineMetrics.isNotEmpty ? _lineMetrics.first : null;
    // 垂直:近似 x-height 中心(fwfh 同款公式);metrics 异常回退几何居中。
    final center =
        offset +
        Offset(
          size.width / 2,
          (m != null && m.descent.isFinite && m.unscaledAscent.isFinite)
              ? size.height -
                    m.descent -
                    m.unscaledAscent +
                    m.unscaledAscent * .7
              : size.height / 2,
        );

    const sz = _shapeSize;
    switch (_depth) {
      case 0: // disc 实心圆
        canvas.drawCircle(center, sz / 2, Paint()..color = _color);
      case 1: // circle 空心圆(外径对齐旧版 6px Container + 1.2 边框)
        canvas.drawCircle(
          center,
          (sz - 1.2) / 2,
          Paint()
            ..color = _color
            ..strokeWidth = 1.2
            ..style = PaintingStyle.stroke,
        );
      default: // square 实心方块
        canvas.drawRect(
          Rect.fromCenter(center: center, width: sz, height: sz),
          Paint()..color = _color,
        );
    }
  }

  @override
  void dispose() {
    _painter?.dispose();
    _painter = null;
    super.dispose();
  }
}

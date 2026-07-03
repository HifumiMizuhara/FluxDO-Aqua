import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

/// Material 3 Expressive LoadingIndicator(不定态)的 1:1 复刻。
///
/// 规格与动画节奏逐项对照 Compose material3 的 LoadingIndicator.kt:
/// - 7 个 MaterialShapes 循环 morph:
///   SoftBurst → Cookie9Sided → Pentagon → Pill → Sunny → Cookie4Sided → Oval → 闭环;
/// - 每 650ms 触发一次 morph,弹簧 spring(dampingRatio 0.6, stiffness 200,
///   visibilityThreshold 0.1),约 298ms 收敛后停在终点等待下个周期;
/// - 每次 morph 完成后形状指针步进,叠加 90° 步进旋转(初始 90°);
/// - 全局旋转 4666ms/圈,线性,与 morph 的 progress*90° 弹性旋转叠加;
/// - 形状缩放按"动画全程最大回转半径"精确计算,保证任意帧不画出 size 之外;
///   与规格的唯一偏差是不保留 38/48 的容器留白(调用方把 size 当可见尺寸,
///   详见 _Md3LoadingGeometry.scaleFactor)。
class LoadingSpinner extends StatefulWidget {
  final Color? color;
  final double size;

  const LoadingSpinner({super.key, this.color, this.size = 48});

  @override
  State<LoadingSpinner> createState() => _LoadingSpinnerState();
}

class _LoadingSpinnerState extends State<LoadingSpinner>
    with TickerProviderStateMixin {
  // 对应 Compose 的 MorphIntervalMillis 与 GlobalRotationDurationMillis。
  static const _morphInterval = Duration(milliseconds: _kMorphIntervalMs);
  static const _globalRotationPeriod = Duration(milliseconds: 4666);

  late final AnimationController _cycleController;
  late final AnimationController _rotationController;

  // 对应 Compose 的 remember { Path() }:每实例复用,避免每帧分配。
  final Path _path = Path();

  int _morphIndex = 0;
  // Compose: morphRotationTargetAngle 初始 QuarterRotation(90°),每次 +90°。
  double _morphRotationTargetAngle = 90;

  @override
  void initState() {
    super.initState();
    _cycleController =
        AnimationController(vsync: this, duration: _morphInterval)
          ..addStatusListener(_onCycleCompleted)
          ..forward();
    _rotationController =
        AnimationController(vsync: this, duration: _globalRotationPeriod)
          ..repeat();
  }

  void _onCycleCompleted(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    // 对应 Compose morph 动画 Finished 后:index 步进、progress 归零、目标角 +90°。
    // progress 1→0 的同时目标角 +90°,总旋转角保持连续。
    _morphIndex = (_morphIndex + 1) % _Md3LoadingGeometry.morphs.length;
    _morphRotationTargetAngle = (_morphRotationTargetAngle + 90) % 360;
    _cycleController.forward(from: 0);
  }

  @override
  void dispose() {
    _cycleController.dispose();
    _rotationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // LoadingIndicatorTokens.ActiveIndicatorColor = Primary。
    final color = widget.color ?? Theme.of(context).colorScheme.primary;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_cycleController, _rotationController]),
          builder: (context, child) {
            final progress =
                _MorphSpringCurve.instance.transform(_cycleController.value);
            return CustomPaint(
              painter: _LoadingIndicatorPainter(
                morphIndex: _morphIndex,
                morphProgress: progress,
                // Compose: rotate(progress * 90 + morphRotationTargetAngle +
                // globalRotation),弹簧过冲会带动旋转一起回弹。
                rotationDegrees: progress * 90 +
                    _morphRotationTargetAngle +
                    _rotationController.value * 360,
                color: color,
                path: _path,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// morph 周期时长(ms),对应 Compose 的 MorphIntervalMillis。
const int _kMorphIntervalMs = 650;

/// 把 650ms 周期映射为 morph 进度:前段是 Compose
/// spring(dampingRatio 0.6, stiffness 200) 的欠阻尼解析解(带过冲),
/// 到达 Compose 的时长估算点后 snap 到 1 并保持(Compose 动画结束值即目标值,
/// 之后等待周期剩余时间)。
class _MorphSpringCurve extends Curve {
  const _MorphSpringCurve._();

  static const instance = _MorphSpringCurve._();

  static const double _dampingRatio = 0.6;
  static const double _stiffness = 200;
  static const double _visibilityThreshold = 0.1;

  // 欠阻尼弹簧 x(t) = 1 + e^(-ζω₀t)·(c₁cos(ω_d t) + c₂sin(ω_d t)),
  // 初值 x(0)=0、v(0)=0 ⇒ c₁ = -1,c₂ = -ζ/√(1-ζ²)。
  static final double _omega0 = math.sqrt(_stiffness);
  static final double _omegaD =
      _omega0 * math.sqrt(1 - _dampingRatio * _dampingRatio);
  static const double _c1 = -1;
  static final double _c2 =
      _c1 * _dampingRatio / math.sqrt(1 - _dampingRatio * _dampingRatio);

  // Compose SpringEstimation.estimateUnderDamped:动画时长取包络
  // √(c₁²+c₂²)·e^(-ζω₀t) 衰减到 visibilityThreshold 的时刻(≈298ms)。
  static final double _springSeconds =
      math.log(math.sqrt(_c1 * _c1 + _c2 * _c2) / _visibilityThreshold) /
          (_dampingRatio * _omega0);

  /// 弹簧输出的最大进度(首个过冲峰,发生在时长截断之前):
  /// 1 + e^(-ζπ/√(1-ζ²)) ≈ 1.095。
  static final double peakProgress = 1 +
      math.exp(-_dampingRatio *
          math.pi /
          math.sqrt(1 - _dampingRatio * _dampingRatio));

  @override
  double transformInternal(double t) {
    final seconds = t * _kMorphIntervalMs / 1000;
    if (seconds >= _springSeconds) return 1;
    final decay = math.exp(-_dampingRatio * _omega0 * seconds);
    final phase = _omegaD * seconds;
    return 1 + decay * (_c1 * math.cos(phase) + _c2 * math.sin(phase));
  }
}

/// 全局缓存的形状序列与缩放因子:Morph 构造(曲线特征匹配)有成本,
/// 所有 LoadingSpinner 实例共享一份。
abstract final class _Md3LoadingGeometry {
  // LoadingIndicatorDefaults.IndeterminateIndicatorPolygons 的形状顺序。
  static final List<RoundedPolygon> _polygons = [
    MaterialShapes.softBurst,
    MaterialShapes.cookie9Sided,
    MaterialShapes.pentagon,
    MaterialShapes.pill,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.oval,
  ];

  /// 循环 morph 序列(含尾→首闭环),对应 morphSequence(circularSequence=true)。
  static final List<Morph> morphs = [
    for (var i = 0; i < _polygons.length; i++)
      Morph(
        _polygons[i].normalized(),
        _polygons[(i + 1) % _polygons.length].normalized(),
      ),
  ];

  /// 让形状尽量撑满 size、且保证动画全程不越界的缩放因子。
  ///
  /// M3E 规格是"静态 maxBounds 缩放 × 38/48 容器留白",留白顺带兜住了
  /// morph 中间态与弹簧过冲的外扩;项目调用方把 [LoadingSpinner.size]
  /// 当作可见尺寸,不保留 38/48 留白,因此这里改为直接对动画全程
  /// (每段 morph × progress ∈ [0, 过冲峰值])采样,按 painter 的实际口径
  /// (控制点包围盒中心对齐 + 绕中心旋转)求最大回转半径,反推出
  /// 任意帧都不会画出 size 之外的最大缩放。
  static final double scaleFactor = 0.5 / _maxAnimatedRadius();

  static double _maxAnimatedRadius() {
    var worst = 0.0;
    const samples = 48;
    for (final morph in morphs) {
      for (var s = 0; s <= samples; s++) {
        final cubics =
            morph.asCubics(_MorphSpringCurve.peakProgress * s / samples);
        // 与 Path.getBounds 口径一致:包围盒含控制点;painter 每帧按该
        // 包围盒中心对齐画布中心后旋转,约束量即各点到该中心的最大距离。
        var minX = double.infinity, minY = double.infinity;
        var maxX = -double.infinity, maxY = -double.infinity;
        for (final c in cubics) {
          minX = math.min(minX, math.min(c.anchor0X, c.control0X));
          minX = math.min(minX, math.min(c.control1X, c.anchor1X));
          maxX = math.max(maxX, math.max(c.anchor0X, c.control0X));
          maxX = math.max(maxX, math.max(c.control1X, c.anchor1X));
          minY = math.min(minY, math.min(c.anchor0Y, c.control0Y));
          minY = math.min(minY, math.min(c.control1Y, c.anchor1Y));
          maxY = math.max(maxY, math.max(c.anchor0Y, c.control0Y));
          maxY = math.max(maxY, math.max(c.control1Y, c.anchor1Y));
        }
        final cx = (minX + maxX) / 2;
        final cy = (minY + maxY) / 2;
        for (final c in cubics) {
          for (final (x, y) in [
            (c.anchor0X, c.anchor0Y),
            (c.control0X, c.control0Y),
            (c.control1X, c.control1Y),
            (c.anchor1X, c.anchor1Y),
          ]) {
            final dx = x - cx;
            final dy = y - cy;
            worst = math.max(worst, math.sqrt(dx * dx + dy * dy));
          }
        }
      }
    }
    return worst;
  }
}

class _LoadingIndicatorPainter extends CustomPainter {
  _LoadingIndicatorPainter({
    required this.morphIndex,
    required this.morphProgress,
    required this.rotationDegrees,
    required this.color,
    required this.path,
  });

  final int morphIndex;
  final double morphProgress;
  final double rotationDegrees;
  final Color color;

  /// State 持有的复用 Path,toPath 内部每次会 reset。
  final Path path;

  static final Paint _paint = Paint()..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    _Md3LoadingGeometry.morphs[morphIndex]
        .toPath(progress: morphProgress, path: path);

    // 对应 Compose processPath:normalized 形状(0..1 空间)按
    // size × scaleFactor 缩放,包围盒中心对齐画布中心,再绕画布中心旋转。
    final scale = size.shortestSide * _Md3LoadingGeometry.scaleFactor;
    final boundsCenter = path.getBounds().center;
    final center = size.center(Offset.zero);
    _paint.color = color;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotationDegrees * math.pi / 180);
    canvas.translate(-boundsCenter.dx * scale, -boundsCenter.dy * scale);
    canvas.scale(scale);
    canvas.drawPath(path, _paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoadingIndicatorPainter oldDelegate) {
    return oldDelegate.morphIndex != morphIndex ||
        oldDelegate.morphProgress != morphProgress ||
        oldDelegate.rotationDegrees != rotationDegrees ||
        oldDelegate.color != color;
  }
}

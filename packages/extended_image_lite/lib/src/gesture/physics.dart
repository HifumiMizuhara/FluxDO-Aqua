import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// 惯性滑动物理配置
class InertiaPhysicsConfig {
  const InertiaPhysicsConfig({
    this.friction = 0.02,
    this.minVelocity = 50.0,
  });

  /// 摩擦系数 - 值越小滑动越远
  /// 0.01 = 滑动很远（冰面感）
  /// 0.02 = 适中（默认）
  /// 0.05 = 较快停止
  final double friction;

  /// 最小启动速度 - 低于此速度不触发惯性
  final double minVelocity;

  static const smooth = InertiaPhysicsConfig(friction: 0.015);
  static const standard = InertiaPhysicsConfig(friction: 0.02);
  static const quick = InertiaPhysicsConfig(friction: 0.035);
}

/// 2D 惯性滑动模拟器
///
/// 由 GestureAnimation 以线性时间轴采样 [positionAt] 驱动
/// (不走 animateWith,见 utils.dart 的 _onOffsetAnimation)。
class Inertia2DSimulation {
  Inertia2DSimulation({
    required this.startPosition,
    required Offset velocity,
    required double friction,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  }) : _xSim = FrictionSimulation(friction, startPosition.dx, velocity.dx),
       _ySim = FrictionSimulation(friction, startPosition.dy, velocity.dy);

  final Offset startPosition;
  final FrictionSimulation _xSim;
  final FrictionSimulation _ySim;

  // 边界
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  /// 获取指定时间点的位置（带边界限制）
  Offset positionAt(double time) {
    double x = _xSim.x(time);
    double y = _ySim.x(time);

    // 边界限制
    x = x.clamp(minX, maxX);
    y = y.clamp(minY, maxY);

    return Offset(x, y);
  }
}

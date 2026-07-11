import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 顶栏渐变模糊(progressive blur):模糊与遮罩从顶部向下渐次消散到
/// 完全透明,内容从其下滚过时自然"溶解",没有均匀毛玻璃的硬下边。
///
/// 实现:多层阶梯 BackdropFilter(层高递减、sigma 递增)近似连续
/// 变力模糊 —— 越靠顶部叠加层数越多模糊越强,最底层下缘只剩极轻
/// 模糊(σ1.2)+ 近零遮罩,肉眼无边界;BackdropGroup 把各层合并为
/// 单次 backdrop 采样(Impeller 单 pass,避免多次 saveLayer);
/// 顶部再叠 surface→透明 渐变色罩,软化层阶并保证顶栏文字对比。
///
/// 用法:AppBar 设为纯透明(只承载返回/标题/按钮),本组件以
/// IgnorePointer 画在 body Stack 顶部,高度 = 状态栏 + AppBar +
/// 消散尾巴(尾巴伸出 AppBar 下缘,是"渐变到透明"的发生区)。
class ProgressiveTopBlur extends StatelessWidget {
  const ProgressiveTopBlur({super.key, required this.height});

  /// 总高(通常 = MediaQuery.padding.top + kToolbarHeight + 尾巴 ~36)
  final double height;

  /// (占总高比例, 模糊 sigma):自下而上层高递减、模糊递增
  static const List<(double, double)> _layers = [
    (1.00, 1.2),
    (0.78, 2.5),
    (0.58, 5.0),
    (0.40, 10.0),
  ];

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return IgnorePointer(
      child: SizedBox(
        height: height,
        child: BackdropGroup(
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final (fraction, sigma) in _layers)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: height * fraction,
                  child: ClipRect(
                    child: BackdropFilter.grouped(
                      filter: ui.ImageFilter.blur(
                        sigmaX: sigma,
                        sigmaY: sigma,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              // 渐变色罩:顶部保文字对比,向下软化层阶直至全透明
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      surface.withValues(alpha: 0.80),
                      surface.withValues(alpha: 0.35),
                      surface.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

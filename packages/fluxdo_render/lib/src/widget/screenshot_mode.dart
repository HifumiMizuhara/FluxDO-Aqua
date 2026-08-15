import 'package:flutter/widgets.dart';

/// 截图 / 离屏渲染作用域。
///
/// [FluxdoRender.screenshotMode] 为 true 时(分享成图等场景)包在渲染树顶层。
/// 主项目注入的**懒加载** builder(典型是 mermaid 图,靠 `VisibilityDetector`
/// 可见才加载)可通过 [ScreenshotMode.of] 感知:离屏截图时 widget 不在屏幕上、
/// `VisibilityDetector` 永不触发,读到 `true` 即应跳过懒加载直接出图,避免
/// 截图截到 shimmer 占位。
///
/// 子包内部的大表格行虚拟化不走这里(直接读 `NodeFactory.screenshotMode`);
/// 本 InheritedWidget 是给拿不到 NodeFactory 的主项目回调 builder 用的。
class ScreenshotMode extends InheritedWidget {
  const ScreenshotMode({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  /// 读当前是否处于截图模式(无 [ScreenshotMode] 祖先时返回 false)。
  static bool of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<ScreenshotMode>();
    return w?.enabled ?? false;
  }

  @override
  bool updateShouldNotify(ScreenshotMode oldWidget) =>
      enabled != oldWidget.enabled;
}

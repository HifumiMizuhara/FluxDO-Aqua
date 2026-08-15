/// 把 [SelectionController](registry + 当前选区)下传给子树里的 InlineSpanText
/// 和高亮层。FluxdoRender 顶层在 selectionEnabled 时包一层。
library;

import 'package:flutter/widgets.dart';

import 'selection_registry.dart';

class SelectionScope extends InheritedWidget {
  const SelectionScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final SelectionController controller;

  /// 取最近的 SelectionScope;不在选区树内(如 selectionEnabled=false /
  /// example gallery 未包)返回 null,调用方退化为不可选。
  static SelectionController? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SelectionScope>();
    return scope?.controller;
  }

  /// 不建立依赖关系的版本(注册/注销时用,避免无谓 rebuild)。
  static SelectionController? maybeOfNoDepend(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<SelectionScope>();
    return scope?.controller;
  }

  /// 清除 [context] 所在选区作用域的当前选区(无作用域时静默无操作)。
  ///
  /// 给主项目在「点图片打开大图」等会离开当前视图的 tap 里调用 —— 这类 tap
  /// 被子组件手势(HeroImage onTap)赢走,自研选区层收不到、不会自动清,需
  /// 显式清一下。
  static void clearAt(BuildContext context) =>
      maybeOfNoDepend(context)?.clear();

  @override
  bool updateShouldNotify(SelectionScope oldWidget) =>
      controller != oldWidget.controller;
}

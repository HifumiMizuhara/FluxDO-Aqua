/// 全局选区协调器 —— 保证全应用同时只有一个 SelectionController 持有选区。
///
/// 每个 FluxdoRender 仍有独立 SelectionController(选区限单帖内),但起选时
/// 通过本协调器把上一个活动 controller 清掉,实现「全局唯一活动选区」。
///
/// 单例,无状态依赖,跨整个 widget 树生效(不同 topic 页、回复弹窗皆共享)。
library;

import 'selection_registry.dart';

class SelectionCoordinator {
  SelectionCoordinator._();
  static final SelectionCoordinator instance = SelectionCoordinator._();

  SelectionController? _active;

  /// 某 controller 起选(选区变非空)时调:清掉上一个活动 controller。
  void activate(SelectionController controller) {
    if (identical(_active, controller)) return;
    final prev = _active;
    _active = controller;
    // 清上一个(它 clear → selection=null → 不会再回调 activate,无递归)。
    prev?.clear();
  }

  /// controller 自己清空选区时调:若它是当前活动者,置空。
  void deactivate(SelectionController controller) {
    if (identical(_active, controller)) _active = null;
  }

  /// 清掉当前活动选区(若有)。主项目在打开弹层/路由切换等场景兜底调用
  /// (常规路径靠选区层自身的失焦监听,见 SelectionContentLayer)。
  void clearActive() {
    final active = _active;
    _active = null;
    active?.clear();
  }
}

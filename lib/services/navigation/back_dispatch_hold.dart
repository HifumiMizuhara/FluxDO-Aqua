import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../widgets/common/predictive_back_cupertino_transitions.dart'
    show predictiveBackGestureActive;

/// Android 预测返回派发保持器。
///
/// 引擎收到 setFrameworkHandlesBack(false) 会立即从 OS dispatcher
/// **注销** OnBackInvokedCallback(FlutterActivity.java 730-734);注销
/// 状态下手势不进 Flutter,由系统按「关闭 Activity」接管 —— 整窗
/// 缩小、窗外黑底(黑在窗外,windowBackground 管不到)。三个保持窗:
///
/// 1. pop 退场动画存续期间(连划第二下要能进 Flutter);
/// 2. **预测返回手势进行中**(手势中途注销会把这条手势拦腰截断,
///    剩余 progress/commit 由系统接管当场出黑底 —— 手势期路由态
///    变化很常见:静默认领 commit 的排队 maybePop、上一路由退场
///    收尾等都会触发 NavigationNotification);
/// 3. resumed 无条件重发当前值(锁屏窗口内被翻错的注册态自愈)。
///
/// 双击退出模式下根路由 canPop 恒 false → canHandlePop 恒 true,
/// 保持窗自然无操作。
class BackDispatchHold extends NavigatorObserver with WidgetsBindingObserver {
  BackDispatchHold() {
    predictiveBackGestureActive.addListener(_onGestureActiveChanged);
  }

  bool _lastCanHandlePop = false;
  bool _everNotified = false;
  bool _attached = false;
  int _activeExitTransitions = 0;
  bool? _lastSent;
  AppLifecycleState? get _lifecycleState =>
      WidgetsBinding.instance.lifecycleState;

  /// 接到 NavigationNotification:记录真实值,合并 hold 后上报。
  /// 返回 true 拦截冒泡(语义同 WidgetsApp 默认实现)。
  bool onNavigationNotification(NavigationNotification notification) {
    if (!_attached) {
      _attached = true;
      WidgetsBinding.instance.addObserver(this);
    }
    _lastCanHandlePop = notification.canHandlePop;
    _everNotified = true;
    _push();
    return true;
  }

  void _onGestureActiveChanged() {
    // 手势结束:hold 解除,按真实值回写;手势开始:确保注册在位
    _push();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台:引擎注册态可能在锁屏窗口被翻错/丢失,按当前值重发对齐
    if (state == AppLifecycleState.resumed) {
      _lastSent = null; // 强制重发,不受去重挡路
      _push();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! ModalRoute<dynamic>) return;
    final animation = route.animation;
    if (animation == null || animation.isDismissed) return;
    _activeExitTransitions += 1;
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status == AnimationStatus.dismissed ||
          status == AnimationStatus.completed) {
        animation.removeStatusListener(listener);
        _activeExitTransitions -= 1;
        // 退场收尾在动画完成回调里,树可能处于锁定/构建阶段;
        // 帧后回写,与 vendored detector 的 dispose 清理同一口径。
        SchedulerBinding.instance.addPostFrameCallback((_) => _push());
      }
    };
    animation.addStatusListener(listener);
  }

  void _push() {
    if (!_everNotified) return;
    // 同 WidgetsApp 默认实现:app 未就绪时不去碰引擎
    switch (_lifecycleState) {
      case null:
      case AppLifecycleState.detached:
        return;
      case AppLifecycleState.inactive:
      case AppLifecycleState.resumed:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        final bool value =
            _lastCanHandlePop ||
            _activeExitTransitions > 0 ||
            predictiveBackGestureActive.value;
        if (value == _lastSent) return;
        _lastSent = value;
        assert(() {
          debugPrint(
            '[BackDispatch] setFrameworkHandlesBack($value) '
            'canPop=$_lastCanHandlePop exits=$_activeExitTransitions '
            'gesture=${predictiveBackGestureActive.value}',
          );
          return true;
        }());
        SystemNavigator.setFrameworkHandlesBack(value);
    }
  }
}

/// 全局单例(与 appRouteObserver 同模式,挂 MaterialApp 两个入口)
final BackDispatchHold backDispatchHold = BackDispatchHold();

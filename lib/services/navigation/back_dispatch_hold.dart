import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Android 预测返回派发保持器。
///
/// 修两个「系统层接管返回」病灶(均为 OnBackInvokedCallback 被注销
/// 或失效,手势根本不进 Flutter,vendored 转场的任何认领逻辑都轮
/// 不到执行):
///
/// 1. 连划黑边:单次返回模式下 pop 一启动被弹路由即出账,
///    navigator.canPop() 同帧翻 false,默认 onNavigationNotification
///    立刻 setFrameworkHandlesBack(false) → 引擎注销回调 → 退场动画
///    期间的第二划被系统当「关闭 Activity」接管,整窗缩小、窗外纯黑
///    (黑在窗外,windowBackground 管不到)。修法:退场动画存续期间
///    强制上报 canHandlePop=true,窗口结束按最后真实值回写。
/// 2. 锁屏后预测返回失效:paused 期间任何路由变动照常下发
///    setFrameworkHandlesBack,引擎侧注册态可能在锁屏窗口内被翻错
///    (Activity 重建等路径还会整个丢失),回前台无人补发。修法:
///    resumed 时无条件按当前值重发一次,注册态与框架对齐。
///
/// 双击退出模式下根路由 canPop 恒 false → canHandlePop 恒 true,
/// 病灶 1 自然不存在;病灶 2 的 resume 重发两种模式都受益。
class BackDispatchHold extends NavigatorObserver with WidgetsBindingObserver {
  bool _lastCanHandlePop = false;
  bool _everNotified = false;
  bool _attached = false;
  int _activeExitTransitions = 0;
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台:引擎注册态可能在锁屏窗口被翻错/丢失,按当前值重发对齐
    if (state == AppLifecycleState.resumed) {
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
        SystemNavigator.setFrameworkHandlesBack(
          _lastCanHandlePop || _activeExitTransitions > 0,
        );
    }
  }
}

/// 全局单例(与 appRouteObserver 同模式,挂 MaterialApp 两个入口)
final BackDispatchHold backDispatchHold = BackDispatchHold();

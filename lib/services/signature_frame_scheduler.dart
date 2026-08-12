import 'package:flutter/scheduler.dart';

import '../utils/scroll_busy_signal.dart';

class _SignatureFrameSubscriber {
  _SignatureFrameSubscriber({required this.onFrame, required this.adaptive});

  final void Function(int nowMicros) onFrame;
  final bool adaptive;
  int lastDispatchTickerMicros = -1;
}

/// 小尾巴动画共享帧调度器。
///
/// 所有签名共享一个与 Flutter 显示帧对齐的 [Ticker]。Ticker 本身只提供
/// 屏幕帧边界，真正的 SVG 采样按每个订阅者的目标帧率节流，因此不会把
/// 15/8/4fps 动画重新拉回 60/120fps，也不会像独立 Timer 那样在一帧
/// 中途唤醒 UI isolate。
///
/// adaptive=false 固定 15fps；adaptive=true 才参与 15/8/4fps 负载降档。
/// 时间轴由调用方按真实经过时间推进，降档只减少采样次数，不会让动画变慢。
class SignatureFrameScheduler {
  SignatureFrameScheduler._();

  static final instance = SignatureFrameScheduler._();

  static const _fpsTiers = <int>[15, 8, 4];
  static const _fixedFps = 15;
  static const _pressureThreshold = 2;
  static const _healthyThreshold = 120;

  final Map<Object, _SignatureFrameSubscriber> _subscribers = {};
  final Stopwatch _clock = Stopwatch()..start();

  Ticker? _ticker;
  bool _dispatching = false;
  bool _timingsAttached = false;
  int _tierIndex = 0;
  int _pressureStreak = 0;
  int _wakeLagStreak = 0;
  int _healthyStreak = 0;

  int get targetFps => _fpsTiers[_tierIndex];

  /// 滚动时 adaptive 订阅者固定最低档；固定帧率订阅者は 15fps のまま。
  int get effectiveFps => ScrollBusySignal.isBusy ? _fpsTiers.last : targetFps;

  int get debugSubscriberCount => _subscribers.length;

  void subscribe({
    required Object owner,
    required void Function(int nowMicros) onFrame,
    bool adaptive = true,
  }) {
    _subscribers[owner] = _SignatureFrameSubscriber(
      onFrame: onFrame,
      adaptive: adaptive,
    );
    _attachTimings();
    _ensureTickerRunning();
  }

  void unsubscribe(Object owner) {
    if (_subscribers.remove(owner) == null) return;
    if (_subscribers.isEmpty) {
      _ticker?.stop();
      _detachTimings();
    }
  }

  void _attachTimings() {
    if (_timingsAttached) return;
    _timingsAttached = true;
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  void _detachTimings() {
    if (!_timingsAttached) return;
    _timingsAttached = false;
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
  }

  int _intervalMicrosFor(_SignatureFrameSubscriber subscriber) {
    final fps = subscriber.adaptive ? effectiveFps : _fixedFps;
    return (Duration.microsecondsPerSecond / fps).ceil();
  }

  void _ensureTickerRunning() {
    if (_subscribers.isEmpty) return;
    _ticker ??= Ticker(
      _onTickerFrame,
      debugLabel: 'signature-svg-frame-scheduler',
    );
    if (!_ticker!.isActive) {
      for (final subscriber in _subscribers.values) {
        subscriber.lastDispatchTickerMicros = -1;
      }
      _ticker!.start();
    }
  }

  void _onTickerFrame(Duration elapsed) {
    if (_subscribers.isEmpty) {
      _ticker?.stop();
      return;
    }

    final elapsedMicros = elapsed.inMicroseconds;
    final nowMicros = _clock.elapsedMicroseconds;
    final dispatchWatch = Stopwatch()..start();
    var dispatched = false;
    _dispatching = true;
    try {
      // 回调中 unsubscribe しても遍历を壊さない。
      for (final subscriber in _subscribers.values.toList(growable: false)) {
        final last = subscriber.lastDispatchTickerMicros;
        if (last >= 0 &&
            elapsedMicros - last < _intervalMicrosFor(subscriber)) {
          continue;
        }
        subscriber.lastDispatchTickerMicros = elapsedMicros;
        dispatched = true;
        subscriber.onFrame(nowMicros);
      }
    } finally {
      dispatchWatch.stop();
      _dispatching = false;
      if (dispatched) {
        _recordLoad(workMicros: dispatchWatch.elapsedMicroseconds);
      }
    }
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _recordLoad(
        workMicros:
            timing.buildDuration.inMicroseconds +
            timing.rasterDuration.inMicroseconds,
      );
    }
  }

  /// [wakeLagMicros] は既存 deterministic test/debug 注入用に保持する。
  /// 実運用の Ticker 経路では表示フレーム境界への量子化を wake lag と誤認
  /// しないよう生成しない。負荷学習は dispatch 実時間と Flutter の
  /// build+raster timings を使用する。
  void _recordLoad({required int workMicros, int? wakeLagMicros}) {
    if (wakeLagMicros != null) {
      if (wakeLagMicros >= 8000) {
        _healthyStreak = 0;
        _wakeLagStreak++;
        if (_wakeLagStreak >= _pressureThreshold &&
            _tierIndex < _fpsTiers.length - 1) {
          _wakeLagStreak = 0;
          _tierIndex++;
          _rescheduleAdaptive();
          return;
        }
      } else {
        _wakeLagStreak = 0;
      }
    }

    final expensive = workMicros >= 12000;
    if (expensive) {
      _healthyStreak = 0;
      _pressureStreak++;
      if (_pressureStreak >= _pressureThreshold &&
          _tierIndex < _fpsTiers.length - 1) {
        _pressureStreak = 0;
        _tierIndex++;
        _rescheduleAdaptive();
      }
      return;
    }

    _pressureStreak = 0;
    if (workMicros <= 6000 &&
        (wakeLagMicros == null || wakeLagMicros < 3000) &&
        _tierIndex > 0) {
      _healthyStreak++;
      if (_healthyStreak >= _healthyThreshold) {
        _healthyStreak = 0;
        _tierIndex--;
        _rescheduleAdaptive();
      }
    } else {
      _healthyStreak = 0;
    }
  }

  /// 档位改变後 adaptive 订阅者だけ次の表示フレームから再採样する。
  void _rescheduleAdaptive() {
    for (final subscriber in _subscribers.values) {
      if (subscriber.adaptive) subscriber.lastDispatchTickerMicros = -1;
    }
    if (!_dispatching) _ensureTickerRunning();
  }

  /// 单元测试使用：喂入确定性负载样本。
  void debugRecordLoad({required int workMicros, int? wakeLagMicros}) {
    _recordLoad(workMicros: workMicros, wakeLagMicros: wakeLagMicros);
  }

  /// 单元测试使用：清理单例状态。
  void debugReset() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
    _subscribers.clear();
    _dispatching = false;
    _detachTimings();
    _tierIndex = 0;
    _pressureStreak = 0;
    _wakeLagStreak = 0;
    _healthyStreak = 0;
  }
}

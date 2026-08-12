import 'package:flutter/scheduler.dart';

import '../utils/scroll_busy_signal.dart';

/// 小尾巴动画共享自适应帧调度器。
///
/// 所有签名共享一个与 Flutter 显示帧对齐的 [Ticker]。Ticker 本身只负责
/// 提供屏幕帧边界，真正的 SVG 采样仍按 15/8/4fps 节流；因此不会把低帧率
/// 动画重新拉回 60/120fps，也不会像独立 Timer 那样在一帧中途唤醒 UI
/// isolate，与当前 build/raster 抢占执行时间。
///
/// 时间轴由调用方按真实经过时间推进，降档只减少采样次数，不会让动画变慢。
class SignatureFrameScheduler {
  SignatureFrameScheduler._();

  static final instance = SignatureFrameScheduler._();

  static const _fpsTiers = <int>[15, 8, 4];
  static const _pressureThreshold = 2;
  static const _healthyThreshold = 120;

  final Map<Object, void Function(int nowMicros)> _subscribers = {};
  final Stopwatch _clock = Stopwatch()..start();

  Ticker? _ticker;
  bool _dispatching = false;
  bool _timingsAttached = false;
  int _tierIndex = 0;
  int _pressureStreak = 0;
  int _wakeLagStreak = 0;
  int _healthyStreak = 0;
  int _lastDispatchTickerMicros = -1;

  int get targetFps => _fpsTiers[_tierIndex];

  /// 滚动时固定最低档；滚动结束后恢复到负载学习得到的档位。
  int get effectiveFps => ScrollBusySignal.isBusy ? _fpsTiers.last : targetFps;

  int get debugSubscriberCount => _subscribers.length;

  void subscribe({
    required Object owner,
    required void Function(int nowMicros) onFrame,
  }) {
    _subscribers[owner] = onFrame;
    _attachTimings();
    _ensureTickerRunning();
  }

  void unsubscribe(Object owner) {
    if (_subscribers.remove(owner) == null) return;
    if (_subscribers.isEmpty) {
      _ticker?.stop();
      _lastDispatchTickerMicros = -1;
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

  int get _intervalMicros =>
      (Duration.microsecondsPerSecond / effectiveFps).ceil();

  void _ensureTickerRunning() {
    if (_subscribers.isEmpty) return;
    _ticker ??= Ticker(
      _onTickerFrame,
      debugLabel: 'signature-svg-frame-scheduler',
    );
    if (!_ticker!.isActive) {
      _lastDispatchTickerMicros = -1;
      _ticker!.start();
    }
  }

  void _onTickerFrame(Duration elapsed) {
    if (_subscribers.isEmpty) {
      _ticker?.stop();
      _lastDispatchTickerMicros = -1;
      return;
    }

    final elapsedMicros = elapsed.inMicroseconds;
    final last = _lastDispatchTickerMicros;
    if (last >= 0 && elapsedMicros - last < _intervalMicros) return;
    _lastDispatchTickerMicros = elapsedMicros;

    final dispatchWatch = Stopwatch()..start();
    _dispatching = true;
    try {
      final nowMicros = _clock.elapsedMicroseconds;
      // 回调中 unsubscribe しても遍历を壊さない。
      for (final onFrame in _subscribers.values.toList(growable: false)) {
        onFrame(nowMicros);
      }
    } finally {
      dispatchWatch.stop();
      _dispatching = false;
      _recordLoad(workMicros: dispatchWatch.elapsedMicroseconds);
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

  /// [wakeLagMicros] は既存の deterministic test/debug 注入用に保持する。
  /// 実運用の Ticker 経路では表示フレーム境界への量子化を wake lag と誤認
  /// しないよう、この値を生成しない。負荷学習は dispatch 実時間と Flutter
  /// の build+raster timings を使用する。
  void _recordLoad({required int workMicros, int? wakeLagMicros}) {
    if (wakeLagMicros != null) {
      if (wakeLagMicros >= 8000) {
        _healthyStreak = 0;
        _wakeLagStreak++;
        if (_wakeLagStreak >= _pressureThreshold &&
            _tierIndex < _fpsTiers.length - 1) {
          _wakeLagStreak = 0;
          _tierIndex++;
          _reschedule();
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
        _reschedule();
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
        _reschedule();
      }
    } else {
      _healthyStreak = 0;
    }
  }

  /// 档位改变后从下一个显示帧重新开始采样，避免保留旧档位的相位。
  void _reschedule() {
    _lastDispatchTickerMicros = -1;
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
    _lastDispatchTickerMicros = -1;
  }
}

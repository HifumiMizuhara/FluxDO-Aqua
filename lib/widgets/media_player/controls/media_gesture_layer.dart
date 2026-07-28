import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

import '../../../utils/platform_utils.dart';

/// 播放器手势层(叠在控制条之下),按输入模态分两套语义:
///
/// **移动端(触摸)**:
/// - 单击:toggle 控制条
/// - 双击 左/中/右 1/3:-10s / 播放暂停 / +10s
/// - 长按:2x 快进(松手恢复)
/// - 竖滑:右半屏系统音量,左半屏 app 亮度
///
/// **桌面端(鼠标)**:
/// - 单击:播放/暂停(立即生效,无双击消歧延迟)
/// - 双击:切全屏(300ms 内第二击 → 撤销第一击的播/停再切,
///   主流桌面播放器同款,避免 onDoubleTap 给单击加延迟)
/// - 长按:2x 快进
/// - 控制条显隐完全交给鼠标悬停(控制层治理),点击不参与 ——
///   「点掉→鼠标一动又回来」的模态打架从根上消除。
class MediaGestureLayer extends StatefulWidget {
  const MediaGestureLayer({
    super.key,
    required this.onToggleControls,
    required this.onTogglePlay,
    required this.onSeekRelative,
    required this.onLongPressSpeedChanged,
    this.onDesktopDoubleTapFullscreen,
    this.onVerticalAdjust,
    this.enableVerticalGestures = false,
    this.child,
  });

  /// 移动端单击:toggle 控制条(桌面端不走此回调)。
  final VoidCallback onToggleControls;
  final VoidCallback onTogglePlay;

  /// 双击侧区 seek([forward]=true 为 +10s,仅移动端)。
  final void Function({required bool forward}) onSeekRelative;

  /// 长按 2x 状态变化(true=按下进入,false=松手退出)。
  final ValueChanged<bool> onLongPressSpeedChanged;

  /// 桌面端双击切全屏。
  final VoidCallback? onDesktopDoubleTapFullscreen;

  /// 竖滑手势 HUD 数据回调(isVolume, value, visible)。
  final void Function(bool isVolume, double value, bool visible)?
      onVerticalAdjust;

  /// 竖滑调音量/亮度,仅移动端开。
  final bool enableVerticalGestures;

  final Widget? child;

  @override
  State<MediaGestureLayer> createState() => _MediaGestureLayerState();
}

class _MediaGestureLayerState extends State<MediaGestureLayer> {
  static final bool _isMobile = !PlatformUtils.isDesktop;

  Offset? _doubleTapPosition;
  bool _longPressActive = false;

  /// 桌面端双击判定窗口:第一击已立即执行播/停,窗口内第二击到来
  /// 则撤销(再 toggle 一次)并切全屏。
  Timer? _desktopTapWindow;

  // 竖滑状态
  bool? _verticalIsVolume;
  double _verticalStartValue = 0;
  double _verticalAccum = 0;
  Timer? _hudHideTimer;

  bool get _verticalEnabled =>
      widget.enableVerticalGestures && _isMobile;

  @override
  void dispose() {
    _hudHideTimer?.cancel();
    _desktopTapWindow?.cancel();
    if (_longPressActive) widget.onLongPressSpeedChanged(false);
    super.dispose();
  }

  /// 桌面端单击:立即播/停(不等双击消歧);300ms 内第二击 = 双击 →
  /// 撤销第一击的播/停,切全屏。
  void _handleDesktopTap() {
    final pending = _desktopTapWindow;
    if (pending != null && pending.isActive) {
      pending.cancel();
      _desktopTapWindow = null;
      widget.onTogglePlay(); // 撤销第一击
      widget.onDesktopDoubleTapFullscreen?.call();
      return;
    }
    widget.onTogglePlay();
    _desktopTapWindow = Timer(const Duration(milliseconds: 300), () {});
  }

  void _handleDoubleTap() {
    final position = _doubleTapPosition;
    if (position == null) return;
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final third = position.dx / width;
    if (third < 1 / 3) {
      widget.onSeekRelative(forward: false);
    } else if (third > 2 / 3) {
      widget.onSeekRelative(forward: true);
    } else {
      widget.onTogglePlay();
    }
  }

  Future<void> _startVertical(DragStartDetails details) async {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final isVolume = details.localPosition.dx >= width / 2;
    _verticalAccum = 0;
    try {
      _verticalStartValue = isVolume
          ? await VolumeController.instance.getVolume()
          : await ScreenBrightness().application;
    } catch (_) {
      return; // 平台不支持(如模拟器)则本次手势静默失效
    }
    if (!mounted) return;
    _verticalIsVolume = isVolume;
    _hudHideTimer?.cancel();
    widget.onVerticalAdjust?.call(isVolume, _verticalStartValue, true);
  }

  void _updateVertical(DragUpdateDetails details) {
    final isVolume = _verticalIsVolume;
    if (isVolume == null) return;
    final height = context.size?.height ?? 0;
    if (height <= 0) return;
    // 上滑增大;整屏高度对应满量程
    _verticalAccum -= details.delta.dy / height;
    final value = (_verticalStartValue + _verticalAccum).clamp(0.0, 1.0);
    widget.onVerticalAdjust?.call(isVolume, value, true);
    if (isVolume) {
      VolumeController.instance.showSystemUI = false;
      unawaited(VolumeController.instance.setVolume(value));
    } else {
      unawaited(
          ScreenBrightness().setApplicationScreenBrightness(value));
    }
  }

  void _endVertical() {
    final isVolume = _verticalIsVolume;
    if (isVolume == null) return;
    _verticalIsVolume = null;
    final value = (_verticalStartValue + _verticalAccum).clamp(0.0, 1.0);
    // HUD 略作停留再隐藏
    _hudHideTimer?.cancel();
    _hudHideTimer = Timer(const Duration(milliseconds: 600), () {
      widget.onVerticalAdjust?.call(isVolume, value, false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isMobile) {
      // 桌面:单击播/停 + 手动双击判定切全屏 + 长按 2x。
      // 不挂 onDoubleTap(它会给单击加 300ms 消歧延迟,暂停不跟手);
      // 控制条显隐由控制层的 MouseRegion 悬停治理,点击不参与。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleDesktopTap,
        onLongPressStart: (_) {
          _longPressActive = true;
          widget.onLongPressSpeedChanged(true);
        },
        onLongPressEnd: (_) {
          _longPressActive = false;
          widget.onLongPressSpeedChanged(false);
        },
        onLongPressCancel: () {
          if (!_longPressActive) return;
          _longPressActive = false;
          widget.onLongPressSpeedChanged(false);
        },
        child: widget.child,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onToggleControls,
      onDoubleTapDown: (details) =>
          _doubleTapPosition = details.localPosition,
      onDoubleTap: _handleDoubleTap,
      onLongPressStart: (_) {
        _longPressActive = true;
        widget.onLongPressSpeedChanged(true);
      },
      onLongPressEnd: (_) {
        _longPressActive = false;
        widget.onLongPressSpeedChanged(false);
      },
      onLongPressCancel: () {
        if (!_longPressActive) return;
        _longPressActive = false;
        widget.onLongPressSpeedChanged(false);
      },
      onVerticalDragStart:
          _verticalEnabled ? (d) => unawaited(_startVertical(d)) : null,
      onVerticalDragUpdate: _verticalEnabled ? _updateVertical : null,
      onVerticalDragEnd: _verticalEnabled ? (_) => _endVertical() : null,
      onVerticalDragCancel: _verticalEnabled ? _endVertical : null,
      child: widget.child,
    );
  }
}

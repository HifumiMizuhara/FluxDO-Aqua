import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../l10n/s.dart';
import '../../../utils/platform_utils.dart';
import '../video/video_player_session.dart';
import 'double_tap_seek_indicator.dart';
import 'media_gesture_layer.dart';
import 'media_overlay_style.dart';
import 'media_progress_bar.dart';
import 'playback_speed_menu.dart';
import 'volume_brightness_indicator.dart';

/// 视频控制层总装(inline 与全屏共用):手势层 + 顶/底渐变控制条 +
/// 中央播放大按钮 + 双击 seek 提示 + 竖滑/滚轮 HUD + 长按 2x 角标 +
/// 续播提示胶囊。
///
/// 视觉:黑底白字 overlay 体系,浮层质感统一走 [MediaOverlayStyle]
/// (半透深底+发丝描边+投影,不用 BackdropFilter —— 视频纹理上每帧
/// 重做高斯模糊是已知卡顿源)。控制条出入场为滑入+淡入。
///
/// 音量的端别分工:
/// - 移动端:全屏竖滑调系统音量(手势层);控制条只留静音钮
///   (窗口态有硬件音量键,不摆滑条)。
/// - 桌面端:静音钮悬停展开音量滑条 + 悬停滚轮调音量(播放器级
///   controller.setVolume,不动系统音量)。
class MediaControlsOverlay extends StatefulWidget {
  const MediaControlsOverlay({
    super.key,
    required this.session,
    required this.isFullscreen,
    required this.onFullscreenToggle,
  });

  final VideoPlayerSession session;
  final bool isFullscreen;

  /// inline 请求进全屏 / 全屏页请求退出。
  final VoidCallback onFullscreenToggle;

  @override
  State<MediaControlsOverlay> createState() => _MediaControlsOverlayState();
}

class _MediaControlsOverlayState extends State<MediaControlsOverlay>
    with TickerProviderStateMixin {
  static final bool _isDesktop = PlatformUtils.isDesktop;
  static const Duration _autoHideDelay = Duration(seconds: 3);
  static const int _seekStepSeconds = 10;

  final GlobalKey<DoubleTapSeekIndicatorState> _seekIndicatorKey =
      GlobalKey();

  VideoPlayerController get _controller => widget.session.controller;

  bool _controlsVisible = true;
  bool _draggingProgress = false;
  bool _longPressBoost = false;
  bool _volumeExpanded = false;
  Timer? _hideTimer;
  Timer? _volumeCollapseTimer;

  /// 中央播放钮 play↔pause 图标形变(0=play,1=pause)。
  late final AnimationController _playPauseIcon = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: _controller.value.isPlaying ? 1 : 0,
  );

  // 竖滑/滚轮 HUD 状态
  bool _hudVisible = false;
  bool _hudIsVolume = true;
  double _hudValue = 0;
  Timer? _hudHideTimer;

  // 续播提示胶囊(「已从 xx:xx 继续播放」)
  Duration? _resumedHint;
  Timer? _resumedHintTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hudHideTimer?.cancel();
    _resumedHintTimer?.cancel();
    _volumeCollapseTimer?.cancel();
    _playPauseIcon.dispose();
    super.dispose();
  }

  // ---- 控制条显隐 ----
  //
  // 端别策略:
  // - 移动端:单击 toggle(手势层),播放中 3s 无交互自动隐藏。
  // - 桌面端:纯悬停驱动 —— 鼠标移动即显示、静止 3s 或移出播放器即
  //   隐藏;点击不参与显隐(点击=播/停),两种模态不再打架。

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHideDelay, () {
      if (!mounted) return;
      // 拖动中/暂停态不隐藏
      if (_draggingProgress || !_controller.value.isPlaying) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  /// 移动端单击 toggle(桌面端手势层不会调用)。
  void _toggleControls() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  /// 桌面端:鼠标移出播放器区域即隐藏(暂停/拖动中除外)。
  void _hideOnExit() {
    _hideTimer?.cancel();
    if (!mounted) return;
    if (_draggingProgress || !_controller.value.isPlaying) return;
    setState(() => _controlsVisible = false);
  }

  // ---- 播放操作 ----

  void _togglePlay() {
    final value = _controller.value;
    if (value.isPlaying) {
      _controller.pause();
    } else {
      _maybeShowResumedHint();
      if (value.isCompleted) {
        _controller.seekTo(Duration.zero);
      }
      _controller.play();
    }
    _showControls();
  }

  /// 首次点播放时在播放器内弹「已从 xx:xx 继续播放」胶囊
  /// (位置记忆命中的场景),短暂停留后淡出。
  void _maybeShowResumedHint() {
    final resumed = widget.session.resumedPosition;
    if (resumed == null) return;
    widget.session.resumedPosition = null;
    setState(() => _resumedHint = resumed);
    _resumedHintTimer?.cancel();
    _resumedHintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _resumedHint = null);
    });
  }

  void _seekRelative({required bool forward}) {
    final value = _controller.value;
    if (!value.isInitialized) return;
    final delta =
        Duration(seconds: forward ? _seekStepSeconds : -_seekStepSeconds);
    var target = value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > value.duration) target = value.duration;
    _controller.seekTo(target);
    _seekIndicatorKey.currentState
        ?.show(forward: forward, seconds: _seekStepSeconds);
  }

  void _onLongPressSpeed(bool active) {
    final session = widget.session;
    if (active) {
      if (!_controller.value.isPlaying) return;
      session.speedBeforeLongPress = _controller.value.playbackSpeed;
      _controller.setPlaybackSpeed(2.0);
      setState(() => _longPressBoost = true);
    } else {
      if (!_longPressBoost) return;
      _controller.setPlaybackSpeed(session.speedBeforeLongPress);
      setState(() => _longPressBoost = false);
    }
  }

  void _toggleMute() {
    final session = widget.session;
    final value = _controller.value;
    if (value.volume > 0) {
      session.volumeBeforeMute = value.volume;
      _controller.setVolume(0);
    } else {
      _controller.setVolume(
          session.volumeBeforeMute > 0 ? session.volumeBeforeMute : 1.0);
    }
    _showControls();
  }

  void _setPlayerVolume(double volume) {
    final clamped = volume.clamp(0.0, 1.0);
    if (clamped > 0) widget.session.volumeBeforeMute = clamped;
    _controller.setVolume(clamped);
  }

  /// 桌面端:悬停滚轮调音量(播放器级)+ HUD 反馈。
  void _handleScrollVolume(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    final volume =
        (_controller.value.volume + delta).clamp(0.0, 1.0).toDouble();
    _setPlayerVolume(volume);
    setState(() {
      _hudIsVolume = true;
      _hudValue = volume;
      _hudVisible = true;
    });
    _hudHideTimer?.cancel();
    _hudHideTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  /// 桌面端:静音钮/滑条区悬停展开,移出延迟收起(留出移动到滑条的空隙)。
  void _setVolumeHover(bool hovering) {
    _volumeCollapseTimer?.cancel();
    if (hovering) {
      if (!_volumeExpanded) setState(() => _volumeExpanded = true);
    } else {
      _volumeCollapseTimer = Timer(const Duration(milliseconds: 350), () {
        if (mounted) setState(() => _volumeExpanded = false);
      });
    }
  }

  Future<void> _pickSpeed(BuildContext anchorContext) async {
    _hideTimer?.cancel(); // 菜单开着不隐藏
    final speed = await showPlaybackSpeedMenu(
      anchorContext,
      current: _controller.value.playbackSpeed,
      darkOverlay: true,
    );
    if (speed != null) {
      await _controller.setPlaybackSpeed(speed);
    }
    if (mounted) _showControls();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        // play↔pause 图标形变跟随真实播放态
        if (value.isPlaying &&
            _playPauseIcon.status != AnimationStatus.forward &&
            _playPauseIcon.value != 1) {
          _playPauseIcon.forward();
        } else if (!value.isPlaying &&
            _playPauseIcon.status != AnimationStatus.reverse &&
            _playPauseIcon.value != 0) {
          _playPauseIcon.reverse();
        }

        final showLoading = !value.isInitialized ||
            (value.isBuffering && value.isPlaying);

        Widget overlay = Stack(
          fit: StackFit.expand,
          children: [
            // 手势层(最底,吃单击/双击/长按/竖滑)
            MediaGestureLayer(
              onToggleControls: _toggleControls,
              onTogglePlay: _togglePlay,
              onSeekRelative: _seekRelative,
              onLongPressSpeedChanged: _onLongPressSpeed,
              onDesktopDoubleTapFullscreen: widget.onFullscreenToggle,
              enableVerticalGestures: widget.isFullscreen,
              onVerticalAdjust: (isVolume, v, visible) {
                if (!mounted) return;
                _hudHideTimer?.cancel();
                setState(() {
                  _hudIsVolume = isVolume;
                  _hudValue = v;
                  _hudVisible = visible;
                });
              },
            ),
            // 双击 seek 提示
            DoubleTapSeekIndicator(key: _seekIndicatorKey),
            // 中央播放大按钮:只在暂停/播完时作为「可播放」召唤物出现,
            // 播放中画面保持完全干净(常驻会遮挡内容)
            if (!showLoading && !value.isPlaying)
              _CenterPlayButton(
                isCompleted: value.isCompleted,
                onTap: _togglePlay,
              ),
            // 竖滑/滚轮 HUD
            VolumeBrightnessIndicator(
              visible: _hudVisible,
              isVolume: _hudIsVolume,
              value: _hudValue,
            ),
            // 长按 2x 角标
            _FastForwardBadge(
              visible: _longPressBoost,
              top: widget.isFullscreen ? 48 : 8,
            ),
            // 续播提示胶囊(左下,控制条上方,播放器内替代全局 toast)
            if (_resumedHint != null)
              Positioned(
                left: 12,
                bottom: widget.isFullscreen ? 96 : 72,
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) => Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 8 * (1 - t)),
                        child: child,
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: MediaOverlayStyle.pill(radius: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.history_rounded,
                              color: Colors.white70, size: 15),
                          const SizedBox(width: 6),
                          Text(
                            S.current
                                .mediaPlayer_resumedFrom(_fmt(_resumedHint!)),
                            style: const TextStyle(
                              color: MediaOverlayStyle.foreground,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // 加载中转圈(圆底衬,初始化后 buffering 也显示)
            if (showLoading)
              IgnorePointer(
                child: Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Color(0x66000000),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(14),
                    child: const CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            // 顶部控制条(下沉入场)
            if (widget.isFullscreen)
              _SlidingBar(
                visible: _controlsVisible,
                alignment: Alignment.topCenter,
                child: _buildTopBar(),
              ),
            // 底部控制条(上浮入场)
            _SlidingBar(
              visible: _controlsVisible,
              alignment: Alignment.bottomCenter,
              child: _buildBottomBar(value),
            ),
          ],
        );
        // 桌面端:控制条纯悬停驱动(移动显示/静止 3s 隐藏/移出即隐藏);
        // 滚轮调音量只在全屏挂 —— inline 挂上会劫持列表滚动:
        // onPointerSignal 不参与手势仲裁,光标恰好停在正文视频上滚页面
        // 时音量会被一并改掉
        if (_isDesktop) {
          Widget wrapped = MouseRegion(
            onHover: (_) => _showControls(),
            onExit: (_) => _hideOnExit(),
            child: overlay,
          );
          if (widget.isFullscreen) {
            wrapped = Listener(
              onPointerSignal: _handleScrollVolume,
              child: wrapped,
            );
          }
          overlay = wrapped;
        }
        return overlay;
      },
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration:
          const BoxDecoration(gradient: MediaOverlayStyle.topScrim),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              color: MediaOverlayStyle.foreground,
              tooltip: S.current.mediaPlayer_exitFullscreen,
              onPressed: widget.onFullscreenToggle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(VideoPlayerValue value) {
    return Container(
      decoration:
          const BoxDecoration(gradient: MediaOverlayStyle.bottomScrim),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: MediaProgressBar(
                  value: value,
                  // 控制条隐藏时禁用悬停预览,并让进度条清掉悬停残留
                  // (IgnorePointer 下 onExit 不会派发,否则气泡卡死)
                  hoverPreviewEnabled: _controlsVisible,
                  onSeek: (target) {
                    // 手动 seek 视为用户已知位置,静默消费续播提示
                    widget.session.resumedPosition = null;
                    _controller.seekTo(target);
                  },
                  onDragActive: (active) {
                    _draggingProgress = active;
                    if (active) {
                      _hideTimer?.cancel();
                    } else {
                      _scheduleHide();
                    }
                  },
                ),
              ),
              Row(
                children: [
                  IconButton(
                    icon: value.isCompleted && !value.isPlaying
                        ? const Icon(Icons.replay_rounded)
                        : AnimatedIcon(
                            icon: AnimatedIcons.play_pause,
                            progress: _playPauseIcon,
                          ),
                    color: MediaOverlayStyle.foreground,
                    iconSize: 26,
                    visualDensity: VisualDensity.compact,
                    tooltip: value.isPlaying
                        ? S.current.mediaPlayer_pause
                        : S.current.mediaPlayer_play,
                    onPressed: _togglePlay,
                  ),
                  // 当前时间强、总时长弱,信息分层
                  Text.rich(
                    TextSpan(
                      text: _fmt(value.position),
                      style: const TextStyle(
                        color: MediaOverlayStyle.foreground,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      children: [
                        TextSpan(
                          text: '  /  ${_fmt(value.duration)}',
                          style: const TextStyle(
                            color: MediaOverlayStyle.foregroundDim,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // 倍速
                  Builder(
                    builder: (buttonContext) => TextButton(
                      onPressed: () => _pickSpeed(buttonContext),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 32),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: Text(
                        formatPlaybackSpeed(value.playbackSpeed),
                        style: TextStyle(
                          color: value.playbackSpeed == 1.0
                              ? MediaOverlayStyle.foreground
                              : MediaOverlayStyle.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  // 静音 + 桌面端悬停展开音量滑条
                  MouseRegion(
                    onEnter:
                        _isDesktop ? (_) => _setVolumeHover(true) : null,
                    onExit:
                        _isDesktop ? (_) => _setVolumeHover(false) : null,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            value.volume > 0
                                ? Icons.volume_up_rounded
                                : Icons.volume_off_rounded,
                          ),
                          color: MediaOverlayStyle.foreground,
                          iconSize: 22,
                          visualDensity: VisualDensity.compact,
                          tooltip: value.volume > 0
                              ? S.current.mediaPlayer_mute
                              : S.current.mediaPlayer_unmute,
                          onPressed: _toggleMute,
                        ),
                        if (_isDesktop)
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: _volumeExpanded ? 76 : 0,
                              child: _volumeExpanded
                                  ? SliderTheme(
                                      data: SliderThemeData(
                                        trackHeight: 3,
                                        activeTrackColor:
                                            MediaOverlayStyle.foreground,
                                        inactiveTrackColor: Colors.white
                                            .withValues(alpha: 0.3),
                                        thumbColor:
                                            MediaOverlayStyle.foreground,
                                        thumbShape:
                                            const RoundSliderThumbShape(
                                                enabledThumbRadius: 5),
                                        overlayShape:
                                            const RoundSliderOverlayShape(
                                                overlayRadius: 10),
                                      ),
                                      child: Slider(
                                        value:
                                            value.volume.clamp(0.0, 1.0),
                                        onChanged: _setPlayerVolume,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 全屏
                  IconButton(
                    icon: Icon(
                      widget.isFullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                    ),
                    color: MediaOverlayStyle.foreground,
                    iconSize: 24,
                    visualDensity: VisualDensity.compact,
                    tooltip: widget.isFullscreen
                        ? S.current.mediaPlayer_exitFullscreen
                        : S.current.mediaPlayer_fullscreen,
                    onPressed: widget.onFullscreenToggle,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 控制条容器:滑入 + 淡入出入场(顶栏下沉、底栏上浮)。
class _SlidingBar extends StatelessWidget {
  const _SlidingBar({
    required this.visible,
    required this.alignment,
    required this.child,
  });

  final bool visible;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fromTop = alignment == Alignment.topCenter;
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          offset: visible
              ? Offset.zero
              : Offset(0, fromTop ? -0.3 : 0.3),
          duration: MediaOverlayStyle.barDuration,
          curve: MediaOverlayStyle.barCurve,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: MediaOverlayStyle.barDuration,
            curve: Curves.easeOut,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 中央播放大按钮:圆形 scrim 底 + 播放/重播图标 + 出入场缩放 + 按压反馈。
/// 仅在暂停/播完时挂载(播放中不遮挡画面),入场自带缩放淡入。
class _CenterPlayButton extends StatefulWidget {
  const _CenterPlayButton({
    required this.isCompleted,
    required this.onTap,
  });

  final bool isCompleted;
  final VoidCallback onTap;

  @override
  State<_CenterPlayButton> createState() => _CenterPlayButtonState();
}

class _CenterPlayButtonState extends State<_CenterPlayButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: MediaOverlayStyle.barDuration,
        curve: MediaOverlayStyle.barCurve,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.scale(scale: 0.8 + 0.2 * t, child: child),
        ),
        child: AnimatedScale(
          scale: _pressed ? 0.88 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) {
              setState(() => _pressed = false);
              widget.onTap();
            },
            onTapCancel: () => setState(() => _pressed = false),
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0x8A000000),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x24FFFFFF)),
              ),
              child: Icon(
                widget.isCompleted
                    ? Icons.replay_rounded
                    : Icons.play_arrow_rounded,
                color: MediaOverlayStyle.foreground,
                size: 36,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 长按 2x 角标(带缩放淡入)。
class _FastForwardBadge extends StatelessWidget {
  const _FastForwardBadge({required this.visible, required this.top});

  final bool visible;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: AnimatedScale(
            scale: visible ? 1 : 0.85,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: MediaOverlayStyle.pill(radius: 14),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '2x ',
                      style: TextStyle(
                        color: MediaOverlayStyle.foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Icon(Icons.fast_forward_rounded,
                        color: MediaOverlayStyle.foreground, size: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

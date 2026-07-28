import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'media_overlay_style.dart';

/// 自绘视频进度条:轨道 / 缓冲段(可能多段)/ 已播三层 + 拖动把手。
///
/// 质感细节:
/// - 悬停(桌面)/拖动时轨道平滑变粗、把手放大并带柔光晕;
/// - 拖动中显示时间气泡;桌面端纯悬停也显示落点预览气泡;
/// - 所有形变走 [AnimationController] 插值,无状态硬切。
///
/// 交互正确性(修过的坑,别回退):
/// - 不挂 onTapDown/onTapCancel —— tap 与 horizontal drag 同场竞技时,
///   拖动胜出会先派发 tapCancel 再 dragStart,若 tapDown 已写入拖动态,
///   tapCancel 的清理会让进度条闪回真实位置一帧。纯点击只用 onTapUp。
/// - 松手提交后展示值不立即交还 controller:seekTo 是异步的,position
///   完成前仍回报旧值,立即交还会「弹回原位再跳目标」。pending 钉住
///   目标位,等 position 追上(差 < 800ms)或 2s 兜底再交还。
class MediaProgressBar extends StatefulWidget {
  const MediaProgressBar({
    super.key,
    required this.value,
    required this.onSeek,
    this.onDragActive,
    this.hoverPreviewEnabled = true,
  });

  final VideoPlayerValue value;
  final ValueChanged<Duration> onSeek;

  /// 拖动开始/结束回调(控制层用来暂停自动隐藏计时)。
  final ValueChanged<bool>? onDragActive;

  /// 悬停预览气泡开关。控制条隐藏(IgnorePointer)期间 MouseRegion 收
  /// 不到 onExit,悬停态会卡死残留 —— 控制层在隐藏时传 false,本组件
  /// 借 didUpdateWidget 强制清理。
  final bool hoverPreviewEnabled;

  @override
  State<MediaProgressBar> createState() => _MediaProgressBarState();
}

class _MediaProgressBarState extends State<MediaProgressBar>
    with SingleTickerProviderStateMixin {
  /// 拖动中的预览进度(0-1),null = 未在拖动。
  double? _dragFraction;

  /// 已提交 seek、等待 position 追上目标期间的展示保持值(0-1)。
  double? _pendingFraction;
  Timer? _pendingTimeout;

  /// 桌面端悬停落点(0-1),驱动预览气泡;null = 未悬停。
  double? _hoverFraction;

  /// 0 → 1:静息 → 强调(变粗/把手放大),悬停或拖动时正向。
  late final AnimationController _emphasis = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  );

  Duration get _duration => widget.value.duration;

  double get _playedFraction {
    final total = _duration.inMilliseconds;
    if (total == 0) return 0;
    return (widget.value.position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration _fractionToPosition(double fraction) => Duration(
        milliseconds: (_duration.inMilliseconds * fraction).round(),
      );

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void didUpdateWidget(covariant MediaProgressBar old) {
    super.didUpdateWidget(old);
    // 控制条隐藏 → 清理悬停残留(onExit 在 IgnorePointer 下不会来)
    if (!widget.hoverPreviewEnabled && _hoverFraction != null) {
      _hoverFraction = null;
      _syncEmphasis();
    }
    // position 追上 seek 目标 → pending 使命完成,交还给实时值
    final pending = _pendingFraction;
    if (pending != null) {
      final target = _fractionToPosition(pending);
      final diffMs =
          (widget.value.position - target).inMilliseconds.abs();
      if (diffMs < 800) {
        _pendingTimeout?.cancel();
        _pendingTimeout = null;
        setState(() => _pendingFraction = null);
      }
    }
  }

  @override
  void dispose() {
    _pendingTimeout?.cancel();
    _emphasis.dispose();
    super.dispose();
  }

  void _updateDrag(Offset localPosition, double width) {
    setState(() {
      _dragFraction = (localPosition.dx / width).clamp(0.0, 1.0);
    });
  }

  void _commitSeek(double fraction) {
    _pendingTimeout?.cancel();
    setState(() {
      _dragFraction = null;
      _pendingFraction = fraction;
    });
    // 兜底:后端迟迟不回报新位置(或 seek 静默失败)也不能永远钉住展示
    _pendingTimeout = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _pendingFraction = null);
    });
    widget.onSeek(_fractionToPosition(fraction));
  }

  void _syncEmphasis() {
    final active = _dragFraction != null || _hoverFraction != null;
    if (active) {
      _emphasis.forward();
    } else {
      _emphasis.reverse();
    }
  }

  Widget _timeBubble(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: MediaOverlayStyle.pill(radius: 6),
      child: Text(
        text,
        style: const TextStyle(
          color: MediaOverlayStyle.foreground,
          fontSize: 12,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final fraction =
            _dragFraction ?? _pendingFraction ?? _playedFraction;
        // 气泡:拖动中显示拖动位置;否则(桌面)悬停显示落点预览
        final bubbleFraction = _dragFraction ??
            (widget.hoverPreviewEnabled ? _hoverFraction : null);
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (event) {
            if (!widget.hoverPreviewEnabled) return;
            setState(() {
              _hoverFraction =
                  (event.localPosition.dx / width).clamp(0.0, 1.0);
            });
            _syncEmphasis();
          },
          onExit: (_) {
            setState(() => _hoverFraction = null);
            _syncEmphasis();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (details) {
              widget.onDragActive?.call(true);
              _updateDrag(details.localPosition, width);
              _syncEmphasis();
            },
            onHorizontalDragUpdate: (details) =>
                _updateDrag(details.localPosition, width),
            onHorizontalDragEnd: (_) {
              final fraction = _dragFraction;
              if (fraction != null) _commitSeek(fraction);
              widget.onDragActive?.call(false);
              _syncEmphasis();
            },
            onHorizontalDragCancel: () {
              setState(() => _dragFraction = null);
              widget.onDragActive?.call(false);
              _syncEmphasis();
            },
            onTapUp: (details) {
              _commitSeek(
                  (details.localPosition.dx / width).clamp(0.0, 1.0));
              widget.onDragActive?.call(false);
            },
            child: SizedBox(
              height: 28,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  AnimatedBuilder(
                    animation: _emphasis,
                    builder: (context, _) => CustomPaint(
                      size: Size(width, 28),
                      painter: _ProgressPainter(
                        played: fraction,
                        buffered: widget.value.buffered,
                        duration: _duration,
                        emphasis: Curves.easeOut.transform(_emphasis.value),
                      ),
                    ),
                  ),
                  if (bubbleFraction != null)
                    Positioned(
                      left:
                          (bubbleFraction * width - 28).clamp(0.0, width - 56),
                      bottom: 26,
                      child: _timeBubble(
                          _fmt(_fractionToPosition(bubbleFraction))),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProgressPainter extends CustomPainter {
  const _ProgressPainter({
    required this.played,
    required this.buffered,
    required this.duration,
    required this.emphasis,
  });

  final double played;
  final List<DurationRange> buffered;
  final Duration duration;

  /// 0 = 静息,1 = 悬停/拖动强调态,中间值为过渡帧。
  final double emphasis;

  static const _trackColor = Color(0x42FFFFFF);
  static const _bufferColor = Color(0x73FFFFFF);
  static const _playedColor = Colors.white;

  @override
  void paint(Canvas canvas, Size size) {
    final trackHeight = 2.5 + 1.5 * emphasis;
    final centerY = size.height / 2;
    final radius = Radius.circular(trackHeight / 2);
    final paint = Paint();

    RRect trackRect(double startFraction, double endFraction) =>
        RRect.fromLTRBR(
          size.width * startFraction,
          centerY - trackHeight / 2,
          size.width * endFraction,
          centerY + trackHeight / 2,
          radius,
        );

    // 轨道
    paint.color = _trackColor;
    canvas.drawRRect(trackRect(0, 1), paint);

    // 缓冲段(可能多段)
    final totalMs = duration.inMilliseconds;
    if (totalMs > 0) {
      paint.color = _bufferColor;
      for (final range in buffered) {
        final start = (range.start.inMilliseconds / totalMs).clamp(0.0, 1.0);
        final end = (range.end.inMilliseconds / totalMs).clamp(0.0, 1.0);
        if (end > start) {
          canvas.drawRRect(trackRect(start, end), paint);
        }
      }
    }

    // 已播
    paint.color = _playedColor;
    canvas.drawRRect(trackRect(0, played), paint);

    // 把手:柔光晕(强调态渐显)+ 实心圆
    final thumbCenter = Offset(size.width * played, centerY);
    if (emphasis > 0) {
      paint
        ..color = Colors.white.withValues(alpha: 0.22 * emphasis)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(thumbCenter, 10 * emphasis, paint);
      paint.maskFilter = null;
    }
    paint.color = _playedColor;
    canvas.drawCircle(thumbCenter, 5 + 2.5 * emphasis, paint);
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.played != played ||
      old.buffered != buffered ||
      old.duration != duration ||
      old.emphasis != emphasis;
}

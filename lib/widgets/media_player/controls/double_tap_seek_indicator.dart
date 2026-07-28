import 'package:flutter/material.dart';

import '../../../l10n/s.dart';

/// 双击 ±10s 的侧边提示:半月形高亮 + 三枚追逐流动的箭头 + 累计秒数。
/// 连续双击刷新累计(+10 → +20 …),换向清零重计。
class DoubleTapSeekIndicator extends StatefulWidget {
  const DoubleTapSeekIndicator({super.key});

  @override
  State<DoubleTapSeekIndicator> createState() => DoubleTapSeekIndicatorState();
}

class DoubleTapSeekIndicatorState extends State<DoubleTapSeekIndicator>
    with TickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// 三箭头的流动相位(循环)。仅在提示可见期间跑,平时停表零开销。
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  bool _forward = true;
  int _accumSeconds = 0;

  /// 触发一次提示。[forward] 换向时累计清零重计。
  void show({required bool forward, required int seconds}) {
    setState(() {
      if (forward != _forward) _accumSeconds = 0;
      _forward = forward;
      _accumSeconds += seconds;
    });
    _flow.repeat();
    _fade.forward();
    // 停留后淡出;期间再次触发会重置(forward 会重新走到 1.0)
    _fade.animateTo(1.0).then((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted || _fade.status != AnimationStatus.completed) return;
      await _fade.reverse();
      if (!mounted) return;
      _flow.stop();
      setState(() => _accumSeconds = 0);
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    _flow.dispose();
    super.dispose();
  }

  /// 三枚箭头依相位错峰亮起,形成向 seek 方向流动的追逐感。
  Widget _buildArrows() {
    return AnimatedBuilder(
      animation: _flow,
      builder: (context, _) {
        final phase = _flow.value;
        final children = List<Widget>.generate(3, (i) {
          // 每枚箭头相位错开 1/3 周期;透明度在 0.25-1 间往复
          final local = ((phase - i / 3) % 1 + 1) % 1;
          final alpha = 0.25 + 0.75 * (1 - (local * 2 - 1).abs());
          return Icon(
            _forward
                ? Icons.play_arrow_rounded
                : Icons.play_arrow_rounded,
            color: Colors.white.withValues(alpha: alpha),
            size: 22,
          );
        });
        return Row(
          mainAxisSize: MainAxisSize.min,
          textDirection: _forward ? TextDirection.ltr : TextDirection.rtl,
          children: [
            for (final (i, child) in children.indexed)
              Transform.translate(
                // 三枚微错位重叠,更接近「箭头串」而不是三个独立图标
                offset: Offset(_forward ? -6.0 * i : 6.0 * i, 0),
                child: _forward
                    ? child
                    : Transform.flip(flipX: true, child: child),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: FadeTransition(
        opacity: _fade,
        child: Align(
          alignment:
              _forward ? Alignment.centerRight : Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: 0.35,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // 侧缘向内的柔和径向高亮,替代纯色平涂
                gradient: RadialGradient(
                  center: _forward
                      ? const Alignment(1.2, 0)
                      : const Alignment(-1.2, 0),
                  radius: 1.6,
                  colors: [
                    Colors.white.withValues(alpha: 0.20),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                ),
                borderRadius: _forward
                    ? const BorderRadius.horizontal(
                        left: Radius.elliptical(120, 400))
                    : const BorderRadius.horizontal(
                        right: Radius.elliptical(120, 400)),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildArrows(),
                    const SizedBox(height: 2),
                    Text(
                      _forward
                          ? S.current
                              .mediaPlayer_seekForward(_accumSeconds)
                          : S.current
                              .mediaPlayer_seekBackward(_accumSeconds),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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

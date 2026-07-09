import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// Discourse 上传音频播放条(替代 legacy 的 fwfh_just_audio 默认条)。
///
/// 用 just_audio 加载 [url],显示 播放/暂停 按钮 + 进度条 + 当前/总时长。
/// 视觉:灰底圆角卡,横排紧凑(高约 56)。
///
/// 由主项目 FluxdoRenderCallbacks.forPost 的 audioBuilder 注入;子包不绑
/// just_audio(平台插件 + 体积)。
class DiscourseAudioPlayer extends StatefulWidget {
  const DiscourseAudioPlayer({super.key, required this.url});

  /// 已解析好的真实音频 URL(非 upload:// 短链)。
  final String url;

  @override
  State<DiscourseAudioPlayer> createState() => _DiscourseAudioPlayerState();
}

class _DiscourseAudioPlayerState extends State<DiscourseAudioPlayer> {
  final AudioPlayer _player = AudioPlayer();
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      await _player.setUrl(widget.url);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      // 平台差异排查的关键线索:AVFoundation 对容器/扩展名远比
      // ExoPlayer 挑剔,失败原因只在这里可见(对齐 DiscourseVideoPlayer)
      debugPrint('[Audio] 加载失败 url=${widget.url} error=$e');
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void didUpdateWidget(covariant DiscourseAudioPlayer old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _ready = false;
      _error = null;
      unawaited(_init());
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant, width: 1),
        ),
        child: _error != null
            ? Row(children: [
                Icon(Icons.error_outline_rounded,
                    size: 20, color: scheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('音频加载失败',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              ])
            : StreamBuilder<PlayerState>(
                stream: _player.playerStateStream,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? false;
                  return Row(
                    children: [
                      IconButton(
                        icon: Icon(playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                        color: scheme.primary,
                        onPressed: !_ready
                            ? null
                            : () => playing ? _player.pause() : _player.play(),
                      ),
                      Expanded(
                        child: StreamBuilder<Duration>(
                          stream: _player.positionStream,
                          builder: (context, posSnap) {
                            final pos = posSnap.data ?? Duration.zero;
                            final total = _player.duration ?? Duration.zero;
                            final maxMs = total.inMilliseconds == 0
                                ? 1.0
                                : total.inMilliseconds.toDouble();
                            final value = pos.inMilliseconds
                                .clamp(0, maxMs.toInt())
                                .toDouble();
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 2,
                                    thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6),
                                    overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 12),
                                  ),
                                  child: Slider(
                                    value: value,
                                    max: maxMs,
                                    onChanged: !_ready
                                        ? null
                                        : (v) => _player.seek(
                                            Duration(milliseconds: v.round())),
                                  ),
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(_fmt(pos),
                                          style: theme.textTheme.bodySmall),
                                      Text(_fmt(_player.duration),
                                          style: theme.textTheme.bodySmall),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

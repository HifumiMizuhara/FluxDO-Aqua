// 离屏首帧管线と native SVG player は full_svg_flutter 内部 API を使う。
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:full_svg_flutter/full_svg_flutter.dart';
import 'package:full_svg_flutter/src/animation/animated_svg_painter.dart';
import 'package:full_svg_flutter/src/animation/smil/smil_animation.dart';
import 'package:full_svg_flutter/src/animation/smil/smil_parser.dart';
import 'package:full_svg_flutter/src/animation/smil/smil_timeline.dart';
import 'package:full_svg_flutter/src/animation/svg_dom.dart';
import 'package:full_svg_flutter/src/animation/svg_parser.dart';
import 'package:full_svg_flutter/src/animation/svg_theme_apply.dart';
import 'package:path_provider/path_provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../services/signature_frame_scheduler.dart';
import '../../utils/svg_utils.dart';
import 'signature_animation_scope.dart';
import 'signature_svg_player.dart';

class AnimatedSvgView extends StatefulWidget {
  final String svgSource;
  final BoxFit fit;
  final Alignment alignment;
  final bool autoPlay;

  const AnimatedSvgView({
    super.key,
    required this.svgSource,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.centerLeft,
    this.autoPlay = false,
  });

  static bool hasAnimations(String svgSource) =>
      AnimationDetector.hasAnimations(svgSource);

  static ({double aspect, double? naturalW, double? naturalH, bool stretch})
  rootGeometryOf(String svgSource) =>
      _AnimatedSvgViewState._rootGeometryOf(svgSource);

  @override
  State<AnimatedSvgView> createState() => _AnimatedSvgViewState();
}

class _BumpNotifier extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// 同一 key の first-frame master を共有する小さな LRU。
class _SvgFirstFrameCache {
  static final Map<int, ui.Image> _images = <int, ui.Image>{};
  static final Map<int, Object> _renderer = <int, Object>{};
  static final Map<int, _BumpNotifier> _notifiers = <int, _BumpNotifier>{};
  static const int _cap = 12;
  static const int _diskCap = 32;
  static Future<Directory>? _dirFuture;

  static ui.Image? peek(int key) {
    final image = _images.remove(key);
    if (image != null) _images[key] = image;
    return image;
  }

  static bool tryElect(int key, Object token) {
    if (_images.containsKey(key)) return false;
    final current = _renderer[key];
    if (current == null) {
      _renderer[key] = token;
      return true;
    }
    return identical(current, token);
  }

  static void resign(int key, Object token) {
    if (!identical(_renderer[key], token)) return;
    _renderer.remove(key);
    _notifiers[key]?.bump();
  }

  static void put(int key, ui.Image master) {
    _renderer.remove(key);
    _images.remove(key)?.dispose();
    _images[key] = master;
    while (_images.length > _cap) {
      _images.remove(_images.keys.first)?.dispose();
    }
    _notifiers[key]?.bump();
  }

  static _BumpNotifier notifierFor(int key) =>
      _notifiers[key] ??= _BumpNotifier();

  static Future<Directory> _dir() => _dirFuture ??= () async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/animated_svg_frames');
    await dir.create(recursive: true);
    return dir;
  }();

  static Future<File> _fileFor(String digest) async =>
      File('${(await _dir()).path}/$digest.png');

  static Future<ui.Image?> loadFromDisk(String digest) async {
    try {
      final file = await _fileFor(digest);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      unawaited(
        file.setLastModified(DateTime.now()).then((_) {}, onError: (_) {}),
      );
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveToDisk(String digest, ui.Image image) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final file = await _fileFor(digest);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: false);
      unawaited(_prune());
    } catch (_) {
      // Disk cache is best-effort.
    } finally {
      image.dispose();
    }
  }

  static Future<void> _prune() async {
    try {
      final files = <(File, DateTime)>[];
      await for (final entity in (await _dir()).list()) {
        if (entity is File && entity.path.endsWith('.png')) {
          files.add((entity, (await entity.stat()).modified));
        }
      }
      if (files.length <= _diskCap) return;
      files.sort((a, b) => b.$2.compareTo(a.$2));
      for (final (file, _) in files.skip(_diskCap)) {
        unawaited(file.delete().then((_) {}, onError: (_) {}));
      }
    } catch (_) {}
  }
}

/// 異なる SVG key の UI-isolate Picture 録画を直列化する。
/// parse は各 isolate で並行してよいが、数十 ms の Canvas 記録が同時に
/// UI isolate へ戻ってくる「warmup storm」だけを防ぐ。
class _SvgWarmupQueue {
  static Future<void> _tail = Future<void>.value();

  static Future<T> run<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      await SchedulerBinding.instance.endOfFrame;
      try {
        completer.complete(await task());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}

class _AnimatedSvgViewState extends State<AnimatedSvgView> {
  static _AnimatedSvgViewState? _playing;
  static final Map<int, bool> _snapshotVisibleByKey = <int, bool>{};
  static const int _bigSourceBytes = 256 << 10;

  final Object _token = Object();
  final Object _frameOwner = Object();
  final _BumpNotifier _frameBump = _BumpNotifier();
  final Stopwatch _playClock = Stopwatch();

  late int _cacheKey;
  late double _aspect;
  double? _naturalWidth;
  double? _naturalHeight;
  bool _stretchContent = false;
  String? _digest;

  ui.Image? _snapshot;
  _BumpNotifier? _waitNotifier;
  Timer? _armTimer;
  bool _electArmed = false;
  bool _offscreenRunning = false;
  bool _offscreenFailed = false;
  bool _pendingPlay = false;
  bool _isPlaying = false;
  bool _adaptiveFrameRate = false;

  SvgDocument? _playerDoc;
  SvgTimeline? _playerTimeline;
  SignatureSvgPlaybackPlan? _playerPlan;

  bool get _playerMounted =>
      _playerDoc != null && _playerTimeline != null && _playerPlan != null;

  @override
  void initState() {
    super.initState();
    _initSource();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final adaptive =
        !widget.autoPlay &&
        SignatureAnimationScope.adaptiveFrameRateOf(context);
    if (_adaptiveFrameRate == adaptive) return;
    _adaptiveFrameRate = adaptive;
    if (_isPlaying) _subscribePlayback();
  }

  void _initSource() {
    final source = widget.svgSource;
    _cacheKey = Object.hash(source.length, source.hashCode);
    final geometry = _rootGeometryOf(source);
    _aspect = geometry.aspect;
    _naturalWidth =
        geometry.naturalW ??
        (geometry.naturalH != null
            ? geometry.naturalH! * geometry.aspect
            : null);
    _naturalHeight =
        geometry.naturalH ??
        (geometry.naturalW != null
            ? geometry.naturalW! / geometry.aspect
            : null);
    _stretchContent = geometry.stretch;

    if (widget.autoPlay) {
      _playing?._pause();
      _playing = this;
      _pendingPlay = true;
      unawaited(_mountPlayer());
      return;
    }

    final master = _SvgFirstFrameCache.peek(_cacheKey);
    if (master != null) {
      _snapshot = master.clone();
      return;
    }

    _listenForSnapshot();
    _scheduleArm(const Duration(milliseconds: 300));
    unawaited(_loadFromDiskFlow());
  }

  void _listenForSnapshot() {
    _waitNotifier ??= _SvgFirstFrameCache.notifierFor(_cacheKey)
      ..addListener(_onCacheBump);
  }

  void _onCacheBump() {
    if (!mounted) return;
    final master = _SvgFirstFrameCache.peek(_cacheKey);
    if (master != null) {
      if (_snapshot == null) setState(() => _snapshot = master.clone());
      return;
    }
    if (_electArmed &&
        !_offscreenRunning &&
        !_offscreenFailed &&
        _SvgFirstFrameCache.tryElect(_cacheKey, _token)) {
      unawaited(_runOffscreenPipeline());
    }
  }

  Future<void> _loadFromDiskFlow() async {
    final key = _cacheKey;
    final digest = await _computeDigest();
    if (!mounted || key != _cacheKey) return;
    _digest = digest;
    final image = await _SvgFirstFrameCache.loadFromDisk(digest);
    if (image == null) return;
    if (!mounted || key != _cacheKey || _snapshot != null) {
      image.dispose();
      return;
    }
    _SvgFirstFrameCache.put(key, image);
    _scheduleVisibilityProbe(key, image.clone());
  }

  void _scheduleArm(Duration delay) {
    _armTimer?.cancel();
    _armTimer = Timer(delay, () {
      if (!mounted || _snapshot != null || _electArmed) return;
      if (Scrollable.recommendDeferredLoadingForContext(context)) {
        _scheduleArm(const Duration(milliseconds: 250));
        return;
      }
      _electArmed = true;
      if (_SvgFirstFrameCache.tryElect(_cacheKey, _token)) {
        unawaited(_runOffscreenPipeline());
      }
      setState(() {});
    });
  }

  Future<void> _runOffscreenPipeline() async {
    if (_offscreenRunning) return;
    _offscreenRunning = true;
    final key = _cacheKey;
    try {
      final (document, hasAnimations) = await _parseFirstFrameInBg(
        widget.svgSource,
      );
      if (!mounted || key != _cacheKey || _snapshot != null) return;

      var guard = 0;
      while (mounted &&
          guard++ < 8 &&
          Scrollable.recommendDeferredLoadingForContext(context)) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (!mounted || key != _cacheKey || _snapshot != null) return;

      final size = svgIntrinsicSize(document);
      if (size.width <= 0 || size.height <= 0) {
        throw StateError('invalid intrinsic size');
      }

      final image = await _SvgWarmupQueue.run<ui.Image?>(() async {
        if (!mounted || key != _cacheKey || _snapshot != null) return null;
        if (Scrollable.recommendDeferredLoadingForContext(context)) return null;

        final dpr = MediaQuery.of(context).devicePixelRatio;
        final scale = dpr.clamp(1.0, 2048 / size.longestSide);
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)..scale(scale);
        AnimatedSvgPainter(
          document: document,
          hasAnimations: hasAnimations,
          animationTime: 0.0,
        ).paint(canvas, size);
        final picture = recorder.endRecording();
        try {
          return await picture.toImage(
            (size.width * scale).round().clamp(1, 4096),
            (size.height * scale).round().clamp(1, 4096),
          );
        } finally {
          picture.dispose();
        }
      });

      if (image == null) {
        if (mounted && key == _cacheKey && _snapshot == null) {
          _offscreenRunning = false;
          _scheduleArm(const Duration(milliseconds: 180));
        }
        return;
      }
      if (!mounted || key != _cacheKey) {
        image.dispose();
        return;
      }

      _SvgFirstFrameCache.put(key, image);
      _scheduleSnapshotMaintenance(key, image);
    } catch (_) {
      if (mounted && key == _cacheKey) {
        setState(() => _offscreenFailed = true);
      }
    } finally {
      _offscreenRunning = false;
    }
  }

  /// alpha probe と PNG encode/write は表示のクリティカルパスから外す。
  void _scheduleSnapshotMaintenance(int key, ui.Image master) {
    _scheduleVisibilityProbe(key, master.clone());
    final diskClone = master.clone();
    unawaited(
      SchedulerBinding.instance.scheduleTask<void>(
        () => _persistSnapshot(diskClone),
        Priority.idle,
      ),
    );
  }

  void _scheduleVisibilityProbe(int key, ui.Image image) {
    unawaited(
      SchedulerBinding.instance.scheduleTask<void>(
        () => _probeSnapshotVisible(key, image),
        Priority.idle,
      ),
    );
  }

  Future<void> _probeSnapshotVisible(int key, ui.Image image) async {
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) return;
      final bytes = data.buffer.asUint8List();
      final pixelCount = bytes.length ~/ 4;
      final step = (pixelCount / 4096).ceil().clamp(1, 1 << 20);
      var visible = false;
      for (var i = 3; i < bytes.length; i += 4 * step) {
        if (bytes[i] > 8) {
          visible = true;
          break;
        }
      }
      _snapshotVisibleByKey[key] = visible;
      if (mounted && key == _cacheKey && !visible) setState(() {});
    } catch (_) {
      // Probe failure is treated as visible.
    } finally {
      image.dispose();
    }
  }

  Future<void> _persistSnapshot(ui.Image image) async {
    try {
      final digest = _digest ??= await _computeDigest();
      await _SvgFirstFrameCache.saveToDisk(digest, image);
    } catch (_) {
      image.dispose();
    }
  }

  Future<String> _computeDigest() async {
    if (_digest != null) return _digest!;
    final source = widget.svgSource;
    return source.length > _bigSourceBytes
        ? await compute(_contentDigestTask, source)
        : _contentDigestTask(source);
  }

  Future<void> _mountPlayer() async {
    final key = _cacheKey;
    try {
      final (document, animations) = await _parsePlaybackInBg(widget.svgSource);
      if (!mounted || key != _cacheKey) return;
      if (animations.isEmpty) {
        setState(() {
          _pendingPlay = false;
          _isPlaying = false;
        });
        return;
      }

      _playerPlan?.dispose();
      final plan = SignatureSvgPlaybackPlan(
        document: document,
        animations: animations,
      );
      final timeline = SvgTimeline(
        animations: animations,
        rootNode: document.root,
      )..seek(Duration.zero);
      plan.syncAfterSeek();

      _playerDoc = document;
      _playerTimeline = timeline;
      _playerPlan = plan;
      _playClock.reset();
      _playClock.start();
      setState(() {
        _pendingPlay = false;
        _isPlaying = true;
      });
      _subscribePlayback();
    } catch (_) {
      if (!mounted || key != _cacheKey) return;
      setState(() {
        _pendingPlay = false;
        _isPlaying = false;
      });
    }
  }

  void _subscribePlayback() {
    SignatureFrameScheduler.instance.unsubscribe(_frameOwner);
    if (!_isPlaying) return;
    SignatureFrameScheduler.instance.subscribe(
      owner: _frameOwner,
      adaptive: _adaptiveFrameRate,
      onFrame: _onPlaybackFrame,
    );
  }

  void _onPlaybackFrame(int _) {
    if (!mounted || !_isPlaying) {
      SignatureFrameScheduler.instance.unsubscribe(_frameOwner);
      return;
    }
    if (Scrollable.recommendDeferredLoadingForContext(context)) return;

    final timeline = _playerTimeline;
    final plan = _playerPlan;
    if (timeline == null || plan == null) return;
    timeline.seek(_playClock.elapsed);
    plan.syncAfterSeek();
    _frameBump.bump();
  }

  Future<void> _togglePlay() async {
    if (_pendingPlay) return;
    if (_isPlaying) {
      _pause();
      return;
    }
    if (_playing != null && _playing != this) _playing!._pause();
    _playing = this;

    if (_playerMounted) {
      _playClock.start();
      setState(() => _isPlaying = true);
      _subscribePlayback();
      return;
    }

    setState(() => _pendingPlay = true);
    unawaited(_mountPlayer());
  }

  void _pause() {
    SignatureFrameScheduler.instance.unsubscribe(_frameOwner);
    _playClock.stop();
    if (_playing == this) _playing = null;
    if (mounted) {
      setState(() => _isPlaying = false);
    } else {
      _isPlaying = false;
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedSvgView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.svgSource != widget.svgSource) {
      _teardownSource();
      _initSource();
    }
  }

  void _teardownSource() {
    SignatureFrameScheduler.instance.unsubscribe(_frameOwner);
    _SvgFirstFrameCache.resign(_cacheKey, _token);
    _waitNotifier?.removeListener(_onCacheBump);
    _waitNotifier = null;
    _armTimer?.cancel();
    _armTimer = null;
    _playClock.stop();
    _playClock.reset();
    _playerPlan?.dispose();
    _playerPlan = null;
    _playerTimeline = null;
    _playerDoc = null;
    _snapshot?.dispose();
    _snapshot = null;
    _digest = null;
    _electArmed = false;
    _offscreenRunning = false;
    _offscreenFailed = false;
    _pendingPlay = false;
    _isPlaying = false;
  }

  @override
  void dispose() {
    if (_playing == this) _playing = null;
    _teardownSource();
    _frameBump.dispose();
    super.dispose();
  }

  Widget _buildPlayer() {
    return RepaintBoundary(
      child: ClipRect(
        child: CustomPaint(
          painter: SignatureSvgPlayerPainter(
            document: _playerDoc!,
            plan: _playerPlan!,
            repaint: _frameBump,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }

  Widget _buildFallback() {
    return ClipRect(
      child: AnimatedSvgPicture.string(
        SvgUtils.stripActiveContent(widget.svgSource),
        fit: BoxFit.contain,
        alignment: Alignment.center,
        autoPlay: false,
        clipToViewBox: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget body;
    var showBadge = true;

    if (_playerMounted) {
      body = _buildPlayer();
    } else if (_snapshot != null) {
      body = RawImage(
        image: _snapshot,
        fit: _stretchContent ? BoxFit.fill : BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
      if (_snapshotVisibleByKey[_cacheKey] == false) showBadge = false;
    } else if (_offscreenFailed) {
      body = _buildFallback();
    } else {
      showBadge = false;
      body = DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.3,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }

    final content = Stack(
      children: [
        Positioned.fill(child: body),
        if (showBadge) Positioned(right: 8, bottom: 8, child: _buildBadge()),
      ],
    );

    Widget framed = AspectRatio(
      aspectRatio: (_naturalWidth != null && _naturalHeight != null)
          ? _naturalWidth! / _naturalHeight!
          : _aspect,
      child: content,
    );
    if (_naturalWidth != null) {
      framed = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _naturalWidth!),
        child: framed,
      );
    }
    framed = Align(
      alignment: widget.alignment,
      heightFactor: 1.0,
      child: framed,
    );

    return VisibilityDetector(
      key: ValueKey('animated-svg-$hashCode'),
      onVisibilityChanged: (info) {
        if (_isPlaying && info.visibleFraction < 0.5) _pause();
      },
      child: framed,
    );
  }

  Widget _buildBadge() {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _togglePlay,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: _pendingPlay
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    _isPlaying
                        ? Symbols.pause_rounded
                        : Symbols.play_arrow_rounded,
                    size: 20,
                    color: Colors.white,
                  ),
          ),
        ),
      ),
    );
  }

  static final RegExp _rootSvgTagRe = RegExp(r'<svg\b[^>]*>');
  static final RegExp _attrViewBoxRe = RegExp(
    r'viewBox\s*=\s*"[\d.eE+-]+[\s,]+[\d.eE+-]+[\s,]+([\d.eE+-]+)[\s,]+([\d.eE+-]+)"',
  );
  static final RegExp _attrWidthRe = RegExp(
    r'\swidth\s*=\s*"([\d.]+)(?:px)?\s*"',
  );
  static final RegExp _attrHeightRe = RegExp(
    r'\sheight\s*=\s*"([\d.]+)(?:px)?\s*"',
  );
  static final RegExp _parNoneRe = RegExp(
    r'preserveAspectRatio\s*=\s*"\s*none\s*"',
  );

  static ({double aspect, double? naturalW, double? naturalH, bool stretch})
  _rootGeometryOf(String source) {
    final tag = _rootSvgTagRe.firstMatch(source)?.group(0);
    if (tag == null) {
      return (aspect: 16 / 9, naturalW: null, naturalH: null, stretch: false);
    }

    final width = double.tryParse(
      _attrWidthRe.firstMatch(tag)?.group(1) ?? '',
    );
    final height = double.tryParse(
      _attrHeightRe.firstMatch(tag)?.group(1) ?? '',
    );
    final naturalW = (width != null && width > 0) ? width : null;
    final naturalH = (height != null && height > 0) ? height : null;

    double aspect = 16 / 9;
    final viewBox = _attrViewBoxRe.firstMatch(tag);
    if (viewBox != null) {
      final viewWidth = double.tryParse(viewBox.group(1)!);
      final viewHeight = double.tryParse(viewBox.group(2)!);
      if (viewWidth != null &&
          viewHeight != null &&
          viewWidth > 0 &&
          viewHeight > 0) {
        aspect = viewWidth / viewHeight;
      }
    } else if (naturalW != null && naturalH != null) {
      aspect = naturalW / naturalH;
    }

    return (
      aspect: aspect,
      naturalW: naturalW,
      naturalH: naturalH,
      stretch: _parNoneRe.hasMatch(tag),
    );
  }
}

String _contentDigestTask(String source) {
  const salt = 0x76332e; // v3: native playback/warmup pipeline revision.
  var h1 = 0x811c9dc5 ^ salt;
  var h2 = 0x01935c1f ^ salt;
  for (var i = 0; i < source.length; i++) {
    final c = source.codeUnitAt(i);
    h1 = ((h1 ^ c) * 0x01000193) & 0xFFFFFFFF;
    h2 = ((h2 ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return '${h1.toRadixString(16).padLeft(8, '0')}'
      '${h2.toRadixString(16).padLeft(8, '0')}'
      '-${source.length}';
}

(SvgDocument, bool) _parseFirstFrameTask(String rawSource) {
  final safe = SvgUtils.stripActiveContent(rawSource);
  final document = SvgParser.parse(safe);
  applySvgTheme(document);
  final animations = SmilParser.parseAnimations(document);
  if (animations.isNotEmpty) {
    SvgTimeline(
      animations: animations,
      rootNode: document.root,
    ).seek(_representativeTime(animations));
    _pruneInvisible(document.root);
    _unwrapCssPathValues(document.root);
  }
  return (document, animations.isNotEmpty);
}

Duration _representativeTime(List<SmilAnimation> animations) {
  Duration shortest = Duration.zero;
  for (final animation in animations) {
    if (animation.dur > Duration.zero &&
        (shortest == Duration.zero || animation.dur < shortest)) {
      shortest = animation.dur;
    }
  }
  return shortest == Duration.zero
      ? Duration.zero
      : Duration(microseconds: shortest.inMicroseconds ~/ 2);
}

final RegExp _cssPathFnRe = RegExp(r'''^path\(\s*["']([\s\S]*)["']\s*\)$''');

void _unwrapCssPathValues(SvgNode node) {
  final attr = node.getAttribute('d');
  final value = attr?.effectiveValue;
  if (value is String) {
    final match = _cssPathFnRe.firstMatch(value.trim());
    if (match != null) attr!.setAnimatedValue(match.group(1)!);
  }
  for (final child in node.children) {
    _unwrapCssPathValues(child);
  }
}

void _pruneInvisible(SvgNode node) {
  node.children.removeWhere((child) {
    final value = child.getAttributeValue('opacity');
    final opacity = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return opacity != null && opacity <= 0.01;
  });
  for (final child in node.children) {
    _pruneInvisible(child);
  }
}

Future<(SvgDocument, bool)> _parseFirstFrameInBg(String source) =>
    Isolate.run<(SvgDocument, bool)>(() => _parseFirstFrameTask(source));

(SvgDocument, List<SmilAnimation>) _parsePlaybackTask(String rawSource) {
  final safe = SvgUtils.stripActiveContent(rawSource);
  final document = SvgParser.parse(safe);
  applySvgTheme(document);
  return (document, SmilParser.parseAnimations(document));
}

Future<(SvgDocument, List<SmilAnimation>)> _parsePlaybackInBg(String source) =>
    Isolate.run<(SvgDocument, List<SmilAnimation>)>(
      () => _parsePlaybackTask(source),
    );

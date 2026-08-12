import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../constants.dart';
import '../../services/app_logger.dart';
import '../../services/svg_webview_controller_pool.dart';
import '../../services/webview_settings.dart';
import '../../services/windows_webview_environment_service.dart';
import '../../utils/svg_utils.dart';
import 'animated_svg_view.dart';
import 'signature_svg_host.dart';

/// 用系统 WebView 绘制一个 SVG 文档。
///
/// 该组件只由签名 SVG 的显式设置开关接入，不改变正文和查看器的默认
/// SVG 管线。WebView 保留浏览器的 CSS / SMIL 动画行为，
/// 但使用了平台视图，因此只在可见区域取得受限的活体槽位；离开视口后
/// 保存一张有界的快照，并在再次可见时恢复 WebView。
class SvgWebView extends StatefulWidget {
  final String svgSource;
  final double? width;
  final double? height;
  final Alignment alignment;

  const SvgWebView({
    super.key,
    required this.svgSource,
    this.width,
    this.height,
    this.alignment = Alignment.centerLeft,
  });

  @override
  State<SvgWebView> createState() => _SvgWebViewState();
}

class _SvgWebViewState extends State<SvgWebView> {
  static const _visibilityThreshold = 0.01;
  static const _acquireDelay = Duration(milliseconds: 80);

  final Object _visibilityKey = Object();
  static int _nextSlotId = 0;

  final GlobalKey _layoutKey = GlobalKey();
  final _pool = SvgWebViewControllerPool.instance;

  late final String _slotId = 'signature-svg-slot-${_nextSlotId++}';

  SvgWebViewLease? _lease;
  InAppWebViewController? _controller;
  Timer? _acquireTimer;
  MemoryImage? _snapshotImage;
  ScalableImage? _fallbackImage;
  bool _fallbackInitialized = false;
  bool _visible = false;
  bool _loaded = false;
  int _generation = 0;
  DateTime? _webViewStartedAt;
  SignatureSvgHostController? _host;
  bool _hostRegistered = false;
  bool _hostRegistrationScheduled = false;

  String get _snapshotKey =>
      '${widget.svgSource.length}:${widget.svgSource.hashCode}:'
      '${widget.width}:${widget.height}';

  Map<String, dynamic> get _logFields => {
    'sourceLength': widget.svgSource.length,
    'sourceHash': widget.svgSource.hashCode,
    'width': widget.width,
    'height': widget.height,
    'generation': _generation,
    'poolActive': _pool.activeCount,
    'poolMax': SvgWebViewControllerPool.maxControllers,
  };

  void _logDebug(String message, {Map<String, dynamic>? fields}) {
    AppLogger.debug(
      message,
      tag: 'SvgWebView',
      fields: {..._logFields, ...?fields},
    );
  }

  void _logWarning(
    String message, {
    Object? error,
    Map<String, dynamic>? fields,
  }) {
    AppLogger.warning(
      message,
      tag: 'SvgWebView',
      fields: {
        ..._logFields,
        if (error != null) 'error': error.toString(),
        ...?fields,
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _restoreSnapshot();
    _pool.revision.addListener(_onPoolRevision);
    _logDebug('state_init', fields: {'snapshotHit': _snapshotImage != null});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = SignatureSvgHostScope.maybeOf(context);
    if (identical(host, _host)) return;

    _unregisterFromHost();
    _host = host;
    _host?.addListener(_onHostChanged);
    _scheduleHostRegistration();
  }

  @override
  void didUpdateWidget(covariant SvgWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.svgSource != widget.svgSource ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _logDebug('source_updated');
      _unregisterFromHost();
      _resetForNewSource();
    }
  }

  @override
  void dispose() {
    _logDebug(
      'state_dispose',
      fields: {'hadLease': _lease != null, 'loaded': _loaded},
    );
    _generation++;
    _acquireTimer?.cancel();
    _host?.removeListener(_onHostChanged);
    _unregisterFromHost();
    _host = null;
    _pool.revision.removeListener(_onPoolRevision);
    _lease?.release();
    _lease = null;
    _controller = null;
    super.dispose();
  }

  void _onHostChanged() {
    if (!mounted) return;
    if (_host != null && !_host!.isFailed) {
      _releaseLegacyLeaseForSharedHost();
    }
    _scheduleHostRegistration();
    if (_host?.isFailed == true && _visible) {
      _scheduleAcquire();
    }
    setState(() {});
  }

  void _releaseLegacyLeaseForSharedHost() {
    _generation++;
    _acquireTimer?.cancel();
    _acquireTimer = null;
    _controller = null;
    _loaded = false;
    _lease?.release();
    _lease = null;
  }

  void _scheduleHostRegistration() {
    if (!mounted || _host == null || _hostRegistrationScheduled) return;
    _hostRegistrationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hostRegistrationScheduled = false;
      if (mounted) _registerWithHost();
    });
  }

  void _registerWithHost() {
    final host = _host;
    if (host == null) return;
    final renderObject = _layoutKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      _scheduleHostRegistration();
      return;
    }
    host.registerSlot(
      id: _slotId,
      source: widget.svgSource,
      renderBox: renderObject,
      visible: _visible,
    );
    _hostRegistered = true;
  }

  void _unregisterFromHost() {
    final host = _host;
    if (host == null || !_hostRegistered) return;
    host.unregisterSlot(_slotId);
    _hostRegistered = false;
  }

  void _restoreSnapshot() {
    final bytes = _SvgWebViewSnapshotCache.peek(_snapshotKey);
    if (bytes != null) {
      _snapshotImage = MemoryImage(bytes);
      _logDebug('snapshot_cache_hit', fields: {'snapshotBytes': bytes.length});
    }
  }

  void _resetForNewSource() {
    _generation++;
    _acquireTimer?.cancel();
    _fallbackImage = null;
    _fallbackInitialized = false;
    _snapshotImage = null;
    _loaded = false;
    _controller = null;
    _lease?.release();
    _lease = null;
    _restoreSnapshot();
    if (mounted) setState(() {});
    _scheduleHostRegistration();
    if (_visible && _host == null) _scheduleAcquire();
  }

  void _onPoolRevision() {
    if (!_visible || _lease != null || (_host != null && !_host!.isFailed)) {
      return;
    }
    _scheduleAcquire();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;
    final visible = info.visibleFraction >= _visibilityThreshold;
    if (_visible == visible) return;
    _visible = visible;
    _host?.updateSlotVisibility(_slotId, visible);
    _logDebug(
      'visibility_changed',
      fields: {'visible': visible, 'visibleFraction': info.visibleFraction},
    );
    if (visible) {
      if (_host == null) _scheduleAcquire();
      _scheduleHostRegistration();
    } else {
      _acquireTimer?.cancel();
      unawaited(_deactivate());
    }
  }

  void _scheduleAcquire() {
    if (!mounted ||
        !_visible ||
        _lease != null ||
        (_host != null && !_host!.isFailed)) {
      return;
    }
    _acquireTimer?.cancel();
    _acquireTimer = Timer(_acquireDelay, _tryAcquire);
  }

  void _tryAcquire() {
    _acquireTimer = null;
    if (!mounted ||
        !_visible ||
        _lease != null ||
        (_host != null && !_host!.isFailed)) {
      return;
    }

    // Avoid starting a native controller while a fling is asking all lazy
    // content to defer work. The pool revision will retry after another
    // controller is released, and this timer handles a long fling.
    if (Scrollable.recommendDeferredLoadingForContext(context)) {
      _acquireTimer = Timer(const Duration(milliseconds: 180), _tryAcquire);
      return;
    }

    final lease = _pool.tryAcquire();
    if (lease == null) {
      _logDebug('slot_unavailable');
      return;
    }
    if (!mounted || !_visible) {
      lease.release();
      return;
    }
    _lease = lease;
    _webViewStartedAt = DateTime.now();
    _logDebug('webview_start');
    setState(() {});
  }

  Future<void> _deactivate() async {
    final lease = _lease;
    if (lease == null) return;

    _logDebug('webview_deactivate_start');
    final generation = _generation;
    Uint8List? snapshot;
    final controller = _controller;
    if (controller != null && _loaded) {
      try {
        snapshot = await controller.takeScreenshot();
        _logDebug(
          'snapshot_capture_success',
          fields: {'snapshotBytes': snapshot?.length ?? 0},
        );
      } catch (error) {
        // The controller may already be in its native teardown path.
        _logWarning('snapshot_capture_failed', error: error);
      }
    }

    if (!mounted || generation != _generation) {
      lease.release();
      return;
    }
    // The user scrolled back while the screenshot was being captured. Keep
    // the live WebView in that case instead of replacing it with a stale PNG.
    if (_visible || !identical(_lease, lease)) return;

    _lease = null;
    _controller = null;
    _loaded = false;
    if (snapshot != null && snapshot.isNotEmpty) {
      _SvgWebViewSnapshotCache.put(_snapshotKey, snapshot);
      _snapshotImage = MemoryImage(snapshot);
    }
    _logDebug(
      'webview_deactivate_complete',
      fields: {
        'snapshotSaved': snapshot != null && snapshot.isNotEmpty,
        'snapshotBytes': snapshot?.length ?? 0,
        'snapshotCacheEntries': _SvgWebViewSnapshotCache.entryCount,
        'snapshotCacheBytes': _SvgWebViewSnapshotCache.bytes,
      },
    );
    lease.release();
    if (mounted) setState(() {});
  }

  Widget _buildFallback() {
    if (AnimatedSvgView.hasAnimations(widget.svgSource)) {
      return AnimatedSvgView(
        svgSource: widget.svgSource,
        alignment: widget.alignment,
      );
    }

    if (!_fallbackInitialized) {
      _fallbackInitialized = true;
      try {
        _fallbackImage = ScalableImage.fromSvgString(
          SvgUtils.sanitize(widget.svgSource),
          warnF: (_) {},
        );
      } catch (_) {
        _fallbackImage = null;
      }
    }
    final image = _fallbackImage;
    if (image == null) return const SizedBox.expand();
    return ScalableImageWidget(si: image, fit: BoxFit.contain);
  }

  Widget _buildLegacyBody() {
    final image = _snapshotImage;
    if (_lease == null) {
      if (image != null) return _buildSnapshot(image);
      return _buildFallback();
    }

    final windowsWebView =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final safeSource = SvgUtils.stripActiveContent(widget.svgSource);
    return InAppWebView(
      webViewEnvironment: windowsWebView
          ? WindowsWebViewEnvironmentService.instance.environment
          : null,
      initialData: InAppWebViewInitialData(
        data: _buildDocument(safeSource),
        baseUrl: WebUri(AppConstants.baseUrl),
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        // SVG署名はCSS/SMILだけを許可する。script・on*イベント属性は
        // WebViewへ渡すソースの生成時にも除去する。
        javaScriptEnabled: false,
        domStorageEnabled: false,
        transparentBackground: true,
        cacheEnabled: false,
        sharedCookiesEnabled: false,
        thirdPartyCookiesEnabled: false,
        userAgent: AppConstants.webViewUserAgentOverride,
        supportZoom: false,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        allowsInlineMediaPlayback: false,
        useHybridComposition: true,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (controller) {
        _controller = controller;
        WebViewSettings.registerJsErrorReporter(controller);
        _logDebug('webview_created');
      },
      onLoadStop: (_, _) {
        _loaded = true;
        _logDebug(
          'webview_load_stop',
          fields: {
            'loadMs': _webViewStartedAt == null
                ? null
                : DateTime.now().difference(_webViewStartedAt!).inMilliseconds,
          },
        );
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true) {
          _logWarning(
            'webview_load_error',
            error: error,
            fields: {'url': request.url.toString()},
          );
        }
      },
      onReceivedHttpError: (_, request, response) {
        if (request.isForMainFrame == true) {
          _logWarning(
            'webview_http_error',
            fields: {
              'statusCode': response.statusCode,
              'url': request.url.toString(),
            },
          );
        }
      },
      onRenderProcessGone: (_, detail) {
        _logWarning(
          'webview_render_process_gone',
          fields: {'detail': detail.toString()},
        );
      },
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
      shouldOverrideUrlLoading: (_, action) async {
        if (action.isForMainFrame == true) {
          return NavigationActionPolicy.CANCEL;
        }
        return NavigationActionPolicy.ALLOW;
      },
    );
  }

  Widget _buildBody() {
    // A pane host owns the native controller. During host initialization and
    // while the pane is inactive, retain only the Flutter-sized transparent
    // slot. A failed/absent host deliberately takes the legacy path below.
    final host = _host;
    if (host != null && !host.isFailed) {
      return const SizedBox.expand();
    }
    return _buildLegacyBody();
  }

  Widget _buildSnapshot(MemoryImage image) {
    return Image(
      image: image,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  Widget build(BuildContext context) {
    final geometry = AnimatedSvgView.rootGeometryOf(widget.svgSource);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fallbackWidth = MediaQuery.sizeOf(context).width;
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : fallbackWidth;
        final availableWidth = widget.width ?? maxWidth;

        double displayWidth;
        double displayHeight;
        if (widget.width != null && widget.height != null) {
          displayWidth = widget.width!;
          displayHeight = widget.height!;
        } else if (widget.height != null) {
          displayHeight = widget.height!;
          displayWidth = displayHeight * geometry.aspect;
        } else {
          // <img> の置換要素と同じく、height だけ指定された SVG は
          // 比率から不足する自然幅を補う。
          final naturalWidth =
              geometry.naturalW ??
              (geometry.naturalH != null
                  ? geometry.naturalH! * geometry.aspect
                  : null);
          displayWidth = naturalWidth == null
              ? availableWidth
              : math.min(availableWidth, naturalWidth);
          if (!displayWidth.isFinite || displayWidth <= 0) {
            displayWidth = fallbackWidth;
          }
          displayHeight = displayWidth / geometry.aspect;
        }

        if (constraints.maxHeight.isFinite &&
            displayHeight > constraints.maxHeight &&
            displayHeight > 0) {
          final scale = constraints.maxHeight / displayHeight;
          displayWidth *= scale;
          displayHeight = constraints.maxHeight;
        }
        if (!displayWidth.isFinite || displayWidth <= 0) displayWidth = 1;
        if (!displayHeight.isFinite || displayHeight <= 0) displayHeight = 1;

        return VisibilityDetector(
          key: ValueKey(_visibilityKey),
          onVisibilityChanged: _onVisibilityChanged,
          child: Align(
            alignment: widget.alignment,
            heightFactor: 1,
            child: SizedBox(
              key: _layoutKey,
              width: displayWidth,
              height: displayHeight,
              child: _buildBody(),
            ),
          ),
        );
      },
    );
  }
}

class _SvgWebViewSnapshotCache {
  static const _maxEntries = 16;
  static const _maxBytes = 12 << 20;

  static final Map<String, Uint8List> _entries = <String, Uint8List>{};
  static int _bytes = 0;

  static int get entryCount => _entries.length;

  static int get bytes => _bytes;

  static Uint8List? peek(String key) {
    final bytes = _entries.remove(key);
    if (bytes == null) return null;
    _entries[key] = bytes;
    return bytes;
  }

  static void put(String key, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.length;

    _entries[key] = bytes;
    _bytes += bytes.length;
    while (_entries.length > _maxEntries || _bytes > _maxBytes) {
      final oldestKey = _entries.keys.first;
      _bytes -= _entries.remove(oldestKey)!.length;
    }
  }
}

String _buildDocument(String source) {
  final withoutXmlDeclaration = source.replaceFirst(
    RegExp(r'^\s*<\?xml[^>]*\?>', caseSensitive: false),
    '',
  );
  return '''<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<style>
html, body { width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; background: transparent; }
body { display: flex; align-items: stretch; justify-content: stretch; }
svg { display: block; width: 100% !important; height: 100% !important; }
</style>
</head>
<body>$withoutXmlDeclaration</body>
</html>''';
}

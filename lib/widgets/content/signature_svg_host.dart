import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../constants.dart';
import '../../services/app_logger.dart';
import '../../services/svg_webview_controller_pool.dart';
import '../../services/webview_settings.dart';
import '../../services/windows_webview_environment_service.dart';
import '../../utils/svg_utils.dart';

/// The lifecycle of one pane's shared signature renderer.
enum SignatureSvgHostStatus { inactive, loading, ready, failed }

/// A serializable snapshot used by the host synchronizer.
@visibleForTesting
class SignatureSvgSlotSnapshot {
  const SignatureSvgSlotSnapshot({
    required this.id,
    required this.source,
    required this.rect,
    required this.visible,
  });

  final String id;
  final String source;
  final Rect rect;
  final bool visible;
}

/// One coalesced update sent to the WebView.
@visibleForTesting
class SignatureSvgSyncPayload {
  const SignatureSvgSyncPayload({
    required this.upserts,
    required this.rects,
    required this.removed,
    required this.revisions,
  });

  final List<Map<String, dynamic>> upserts;
  final List<Map<String, dynamic>> rects;
  final List<String> removed;

  /// Revisions are kept outside the JS argument. They make committing a
  /// completed bridge call safe when a newer layout arrived while it was in
  /// flight.
  final Map<String, int> revisions;

  bool get isEmpty => upserts.isEmpty && rects.isEmpty && removed.isEmpty;

  Map<String, dynamic> toJson() => {
    'upserts': upserts,
    'rects': rects,
    'removed': removed,
  };
}

class _TrackedSlot {
  _TrackedSlot({
    required this.id,
    required this.source,
    required this.rect,
    required this.visible,
    required this.revision,
  });

  final String id;
  String source;
  Rect rect;
  bool visible;
  int revision;

  SignatureSvgSlotSnapshot snapshot() => SignatureSvgSlotSnapshot(
    id: id,
    source: source,
    rect: rect,
    visible: visible,
  );
}

class _SentSlot {
  const _SentSlot({
    required this.source,
    required this.rect,
    required this.visible,
  });

  final String source;
  final Rect rect;
  final bool visible;
}

/// The pure slot/blob-reference ledger used by one shared host.
///
/// Keeping this separate from the platform WebView makes the important
/// lifecycle rules deterministic and testable: replacing a source decrements
/// the old source exactly once, removing the final slot drops its reference,
/// and geometry-only updates never resend SVG source text.
@visibleForTesting
class SignatureSvgSlotRegistry {
  final Map<String, _TrackedSlot> _slots = <String, _TrackedSlot>{};
  final Map<String, int> _sourceRefs = <String, int>{};
  final Map<String, _SentSlot> _sent = <String, _SentSlot>{};
  int _revisionCounter = 0;

  int get length => _slots.length;

  bool get isEmpty => _slots.isEmpty;

  int sourceReferenceCount(String source) => _sourceRefs[source] ?? 0;

  Iterable<SignatureSvgSlotSnapshot> get snapshots sync* {
    for (final slot in _slots.values) {
      yield slot.snapshot();
    }
  }

  SignatureSvgSlotSnapshot? snapshotFor(String id) => _slots[id]?.snapshot();

  void upsert({
    required String id,
    required String source,
    required Rect rect,
    required bool visible,
  }) {
    final old = _slots[id];
    if (old == null) {
      _retain(source);
      _slots[id] = _TrackedSlot(
        id: id,
        source: source,
        rect: rect,
        visible: visible,
        revision: _revisionCounter++,
      );
      return;
    }

    if (old.source != source) {
      _release(old.source);
      _retain(source);
      old.source = source;
      old.revision = _revisionCounter++;
    }
    if (old.rect != rect || old.visible != visible) {
      old.rect = rect;
      old.visible = visible;
      old.revision = _revisionCounter++;
    }
  }

  void updateGeometry({
    required String id,
    required Rect rect,
    required bool visible,
  }) {
    final slot = _slots[id];
    if (slot == null || (slot.rect == rect && slot.visible == visible)) {
      return;
    }
    slot.rect = rect;
    slot.visible = visible;
    slot.revision = _revisionCounter++;
  }

  void remove(String id) {
    final old = _slots.remove(id);
    if (old == null) return;
    _release(old.source);
  }

  void resetSentState() => _sent.clear();

  bool get hasPendingChanges => !buildPayload().isEmpty;

  SignatureSvgSyncPayload buildPayload() {
    final upserts = <Map<String, dynamic>>[];
    final rects = <Map<String, dynamic>>[];
    final removed = <String>[];
    final revisions = <String, int>{};

    for (final slot in _slots.values) {
      final sent = _sent[slot.id];
      if (sent == null || sent.source != slot.source) {
        upserts.add(_slotJson(slot, includeSource: true));
        revisions[slot.id] = slot.revision;
      } else if (sent.rect != slot.rect || sent.visible != slot.visible) {
        rects.add(_slotJson(slot, includeSource: false));
        revisions[slot.id] = slot.revision;
      }
    }

    for (final id in _sent.keys) {
      if (!_slots.containsKey(id)) removed.add(id);
    }

    return SignatureSvgSyncPayload(
      upserts: upserts,
      rects: rects,
      removed: removed,
      revisions: revisions,
    );
  }

  void commit(SignatureSvgSyncPayload payload) {
    final payloadUpdates = <String, Map<String, dynamic>>{
      for (final update in [...payload.upserts, ...payload.rects])
        update['id'] as String: update,
    };
    for (final entry in payload.revisions.entries) {
      final slot = _slots[entry.key];
      if (slot != null) {
        if (slot.revision != entry.value) continue;
        _sent[entry.key] = _SentSlot(
          source: slot.source,
          rect: slot.rect,
          visible: slot.visible,
        );
        continue;
      }

      // The slot may have been unmounted while the bridge call was in
      // flight. Remember the successfully sent DOM state once so the next
      // payload can remove that DOM node and revoke its Blob URL.
      final update = payloadUpdates[entry.key];
      if (update == null) continue;
      final oldSent = _sent[entry.key];
      _sent[entry.key] = _SentSlot(
        source: update['source'] as String? ?? oldSent?.source ?? '',
        rect: _rectFromJson(update, oldSent?.rect ?? Rect.zero),
        visible: update['visible'] as bool? ?? oldSent?.visible ?? false,
      );
    }
    for (final id in payload.removed) {
      if (!_slots.containsKey(id)) _sent.remove(id);
    }
  }

  Rect _rectFromJson(Map<String, dynamic> update, Rect fallback) {
    final x = update['x'];
    final y = update['y'];
    final width = update['width'];
    final height = update['height'];
    if (x is! num || y is! num || width is! num || height is! num) {
      return fallback;
    }
    return Rect.fromLTWH(
      x.toDouble(),
      y.toDouble(),
      width.toDouble(),
      height.toDouble(),
    );
  }

  Map<String, dynamic> _slotJson(
    _TrackedSlot slot, {
    required bool includeSource,
  }) {
    return {
      'id': slot.id,
      if (includeSource) 'source': slot.source,
      'x': slot.rect.left,
      'y': slot.rect.top,
      'width': slot.rect.width,
      'height': slot.rect.height,
      'visible': slot.visible,
    };
  }

  void _retain(String source) {
    _sourceRefs[source] = (_sourceRefs[source] ?? 0) + 1;
  }

  void _release(String source) {
    final count = (_sourceRefs[source] ?? 1) - 1;
    if (count <= 0) {
      _sourceRefs.remove(source);
    } else {
      _sourceRefs[source] = count;
    }
  }
}

/// Controller shared by every signature SVG in one topic pane.
class SignatureSvgHostController extends ChangeNotifier {
  final SignatureSvgSlotRegistry registry = SignatureSvgSlotRegistry();
  final Map<String, RenderBox> _boxes = <String, RenderBox>{};

  SignatureSvgHostStatus _status = SignatureSvgHostStatus.inactive;
  int _consecutiveSyncFailures = 0;
  bool _isScrolling = false;
  bool _showFlutterSnapshot = false;
  VoidCallback? _layoutSyncRequester;

  SignatureSvgHostStatus get status => _status;

  bool get isFailed => _status == SignatureSvgHostStatus.failed;

  bool get hasSlots => !registry.isEmpty;

  bool get hasPendingSync => registry.hasPendingChanges;

  int get consecutiveSyncFailures => _consecutiveSyncFailures;

  bool get isScrolling => _isScrolling;

  /// While true, every slot paints its Flutter first-frame fallback and the
  /// shared WebView is kept transparent. It remains true after scrolling ends
  /// until the final WebView geometry has been acknowledged.
  bool get showFlutterSnapshot => _showFlutterSnapshot;

  void beginSession() {
    if (_status == SignatureSvgHostStatus.loading ||
        _status == SignatureSvgHostStatus.ready) {
      return;
    }
    _status = SignatureSvgHostStatus.loading;
    _consecutiveSyncFailures = 0;
    registry.resetSentState();
    notifyListeners();
  }

  void deactivateSession() {
    if (_status == SignatureSvgHostStatus.inactive &&
        _consecutiveSyncFailures == 0 &&
        !_isScrolling &&
        !_showFlutterSnapshot) {
      return;
    }
    _status = SignatureSvgHostStatus.inactive;
    _consecutiveSyncFailures = 0;
    _isScrolling = false;
    _showFlutterSnapshot = false;
    registry.resetSentState();
    notifyListeners();
  }

  void markReady() {
    if (_status == SignatureSvgHostStatus.ready) return;
    _status = SignatureSvgHostStatus.ready;
    _consecutiveSyncFailures = 0;
    notifyListeners();
  }

  void markFailed() {
    if (_status == SignatureSvgHostStatus.failed) return;
    _status = SignatureSvgHostStatus.failed;
    _isScrolling = false;
    _showFlutterSnapshot = false;
    notifyListeners();
  }

  /// Switches all slots to Flutter-rendered first frames before their layout
  /// begins moving. WebView geometry updates are deliberately suspended until
  /// [endScroll] so the bridge cannot trail the Flutter viewport.
  void beginScroll() {
    if (_isScrolling && _showFlutterSnapshot) return;
    _isScrolling = true;
    _showFlutterSnapshot = true;
    notifyListeners();
  }

  /// Keeps the Flutter snapshots visible while requesting one final geometry
  /// synchronization. The WebView is revealed only by
  /// [markViewportSynchronized].
  void endScroll() {
    if (!_isScrolling) return;
    _isScrolling = false;
    notifyListeners();
    requestLayoutSync();
  }

  void markViewportSynchronized() {
    if (_isScrolling || !_showFlutterSnapshot) return;
    _showFlutterSnapshot = false;
    notifyListeners();
  }

  void recordSyncSuccess() {
    _consecutiveSyncFailures = 0;
  }

  bool recordSyncFailure() {
    _consecutiveSyncFailures++;
    if (_consecutiveSyncFailures < 3) return false;
    markFailed();
    return true;
  }

  void attachLayoutSyncRequester(VoidCallback requester) {
    _layoutSyncRequester = requester;
  }

  void detachLayoutSyncRequester(VoidCallback requester) {
    if (identical(_layoutSyncRequester, requester)) {
      _layoutSyncRequester = null;
    }
  }

  void requestLayoutSync() => _layoutSyncRequester?.call();

  void registerSlot({
    required String id,
    required String source,
    required RenderBox renderBox,
    required bool visible,
  }) {
    final oldBox = _boxes[id];
    final old = registry.snapshotFor(id);
    final safeSource = SvgUtils.sanitizeForSecureWebView(source);
    if (_status == SignatureSvgHostStatus.failed &&
        (old == null || old.source != safeSource)) {
      // A newly generated pane or a newly loaded signature starts a fresh
      // session. Existing slots remain registered and the platform host will
      // be rebuilt from this registry on the next frame.
      deactivateSession();
    }
    _boxes[id] = renderBox;
    registry.upsert(
      id: id,
      source: safeSource,
      rect: old?.rect ?? Rect.zero,
      visible: visible,
    );
    if (old == null ||
        old.source != safeSource ||
        old.visible != visible ||
        !identical(oldBox, renderBox)) {
      notifyListeners();
    }
    requestLayoutSync();
  }

  void updateSlotVisibility(String id, bool visible) {
    final old = registry.snapshotFor(id);
    if (old == null || old.visible == visible) return;
    registry.upsert(
      id: id,
      source: old.source,
      rect: old.rect,
      visible: visible,
    );
    notifyListeners();
    requestLayoutSync();
  }

  void unregisterSlot(String id) {
    _boxes.remove(id);
    registry.remove(id);
    notifyListeners();
    requestLayoutSync();
  }

  /// Converts every mounted slot into host-local coordinates in one pass.
  void syncLayout(RenderBox hostBox) {
    if (!hostBox.attached) return;
    final hostOrigin = hostBox.localToGlobal(Offset.zero);
    for (final entry in _boxes.entries) {
      final box = entry.value;
      if (!box.attached || !box.hasSize) continue;
      final origin = box.localToGlobal(Offset.zero);
      final snapshot = registry.snapshotFor(entry.key);
      if (snapshot == null) continue;
      registry.updateGeometry(
        id: entry.key,
        rect: Rect.fromLTWH(
          origin.dx - hostOrigin.dx,
          origin.dy - hostOrigin.dy,
          box.size.width,
          box.size.height,
        ),
        visible: snapshot.visible,
      );
    }
  }

  SignatureSvgSyncPayload buildSyncPayload() => registry.buildPayload();

  void commitSyncPayload(SignatureSvgSyncPayload payload) {
    registry.commit(payload);
  }
}

class SignatureSvgHostScope extends InheritedWidget {
  const SignatureSvgHostScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final SignatureSvgHostController controller;

  static SignatureSvgHostController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<SignatureSvgHostScope>()
        ?.controller;
  }

  @override
  bool updateShouldNotify(SignatureSvgHostScope oldWidget) =>
      controller != oldWidget.controller;
}

/// One transparent platform WebView for all signature SVG slots in a pane.
class SignatureSvgHost extends StatefulWidget {
  const SignatureSvgHost({
    super.key,
    required this.controller,
    required this.active,
  });

  final SignatureSvgHostController controller;
  final bool active;

  @override
  State<SignatureSvgHost> createState() => _SignatureSvgHostState();
}

class _SignatureSvgHostState extends State<SignatureSvgHost> {
  static const _prepareTimeout = Duration(seconds: 8);
  static const _retryDelay = Duration(milliseconds: 180);

  final GlobalKey _hostKey = GlobalKey();
  final _pool = SvgWebViewControllerPool.instance;

  InAppWebViewController? _webViewController;
  SvgWebViewLease? _lease;
  Timer? _prepareTimer;
  Timer? _acquireTimer;
  bool _syncScheduled = false;
  bool _syncInFlight = false;
  bool _syncDirty = false;
  int _generation = 0;

  SignatureSvgHostController get _host => widget.controller;

  @override
  void initState() {
    super.initState();
    _host.addListener(_onHostChanged);
    _host.attachLayoutSyncRequester(_scheduleSync);
    if (widget.active && _host.hasSlots) _startSession();
  }

  @override
  void didUpdateWidget(covariant SignatureSvgHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onHostChanged);
      oldWidget.controller.detachLayoutSyncRequester(_scheduleSync);
      _disposeWebView();
      _host.addListener(_onHostChanged);
      _host.attachLayoutSyncRequester(_scheduleSync);
    }
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        if (_host.hasSlots) _startSession();
      } else {
        _stopSession();
      }
    }
  }

  @override
  void dispose() {
    _host.removeListener(_onHostChanged);
    _host.detachLayoutSyncRequester(_scheduleSync);
    _stopSession();
    super.dispose();
  }

  void _onHostChanged() {
    if (!mounted) return;
    if (!widget.active) return;

    if (!_host.hasSlots) {
      _stopSession();
      setState(() {});
      return;
    }
    if (_host.status == SignatureSvgHostStatus.inactive) {
      _startSession();
      return;
    }
    if (_host.isFailed) {
      _disposeWebView();
      setState(() {});
      return;
    }
    _ensureWebView();
    if (_host.status == SignatureSvgHostStatus.ready) _scheduleSync();
    setState(() {});
  }

  void _startSession() {
    if (!widget.active || !_host.hasSlots) return;
    if (_host.status == SignatureSvgHostStatus.failed) {
      // A failed session is retried only after the pane becomes active again.
      return;
    }
    _host.beginSession();
    _prepareTimer?.cancel();
    _prepareTimer = Timer(_prepareTimeout, () {
      if (_host.status == SignatureSvgHostStatus.loading) {
        _fail('prepare_timeout');
      }
    });
    _ensureWebView();
  }

  void _stopSession() {
    _prepareTimer?.cancel();
    _prepareTimer = null;
    _acquireTimer?.cancel();
    _acquireTimer = null;
    _disposeWebView();
    _host.deactivateSession();
  }

  void _ensureWebView() {
    if (!mounted ||
        !widget.active ||
        !_host.hasSlots ||
        _host.isFailed ||
        _webViewController != null ||
        _lease != null) {
      return;
    }
    final lease = _pool.tryAcquire();
    if (lease == null) {
      _acquireTimer ??= Timer(_retryDelay, () {
        _acquireTimer = null;
        _ensureWebView();
      });
      return;
    }
    _lease = lease;
    _generation++;
    setState(() {});
  }

  void _disposeWebView() {
    _generation++;
    _prepareTimer?.cancel();
    _prepareTimer = null;
    _syncDirty = false;
    _webViewController = null;
    final lease = _lease;
    _lease = null;
    lease?.release();
  }

  void _fail(String reason, [Object? error]) {
    AppLogger.warning(
      'signature_svg_host_failed',
      tag: 'SignatureSvgHost',
      fields: {
        'reason': reason,
        if (error != null) 'error': error.toString(),
        'slotCount': _host.registry.length,
      },
    );
    _acquireTimer?.cancel();
    _acquireTimer = null;
    _host.markFailed();
    _disposeWebView();
    if (mounted) setState(() {});
  }

  void _scheduleSync() {
    if (!mounted || !widget.active || _host.isScrolling) {
      return;
    }

    // Scroll notifications can arrive while the previous JavaScript call is
    // still in flight. Remember that work instead of dropping the final
    // viewport position when scrolling stops before that call completes.
    _syncDirty = true;
    if (_host.status != SignatureSvgHostStatus.ready ||
        _webViewController == null ||
        _syncScheduled ||
        _syncInFlight) {
      return;
    }
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) unawaited(_flushSync());
    });
  }

  Future<void> _flushSync() async {
    if (_syncInFlight ||
        !mounted ||
        !widget.active ||
        _host.status != SignatureSvgHostStatus.ready) {
      return;
    }
    final controller = _webViewController;
    if (controller == null) return;
    _syncDirty = false;
    final syncGeneration = _generation;
    final hostRenderBox = _hostKey.currentContext?.findRenderObject();
    if (hostRenderBox is! RenderBox || !hostRenderBox.hasSize) {
      _scheduleSync();
      return;
    }

    _host.syncLayout(hostRenderBox);
    final payload = _host.buildSyncPayload();
    if (payload.isEmpty) {
      _revealWebViewIfSettled();
      return;
    }

    _syncInFlight = true;
    try {
      final result = await controller.callAsyncJavaScript(
        functionBody: 'return window.__fluxdoSyncSignatureSlots(payload);',
        arguments: <String, dynamic>{'payload': payload.toJson()},
      );
      if (!mounted ||
          syncGeneration != _generation ||
          !identical(controller, _webViewController)) {
        return;
      }
      if (result?.error != null) {
        throw StateError(result!.error!);
      }
      _host.commitSyncPayload(payload);
      _host.recordSyncSuccess();
      _revealWebViewIfSettled();
    } catch (error) {
      if (syncGeneration != _generation ||
          !identical(controller, _webViewController)) {
        return;
      }
      if (_host.recordSyncFailure()) {
        _fail('sync_failed_three_times', error);
      } else {
        AppLogger.debug(
          'signature_svg_host_sync_failed',
          tag: 'SignatureSvgHost',
          fields: {'error': error.toString()},
        );
      }
    } finally {
      _syncInFlight = false;
      if (mounted && (_syncDirty || _host.hasPendingSync)) {
        _scheduleSync();
      }
    }
  }

  void _revealWebViewIfSettled() {
    if (_host.isScrolling || _syncDirty || _host.hasPendingSync) return;
    _host.markViewportSynchronized();
  }

  @override
  Widget build(BuildContext context) {
    final showWebView =
        widget.active && _host.hasSlots && !_host.isFailed && _lease != null;

    final webViewGeneration = _generation;
    final child = showWebView
        ? InAppWebView(
            key: ValueKey(_generation),
            webViewEnvironment:
                !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
                ? WindowsWebViewEnvironmentService.instance.environment
                : null,
            initialData: InAppWebViewInitialData(
              data: signatureSvgHostDocument,
              baseUrl: WebUri(AppConstants.baseUrl),
              mimeType: 'text/html',
              encoding: 'utf-8',
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: false,
              databaseEnabled: false,
              transparentBackground: true,
              cacheEnabled: false,
              incognito: true,
              sharedCookiesEnabled: false,
              thirdPartyCookiesEnabled: false,
              userAgent: AppConstants.webViewUserAgentOverride,
              supportZoom: false,
              pinchZoomEnabled: false,
              disableVerticalScroll: true,
              disableHorizontalScroll: true,
              javaScriptCanOpenWindowsAutomatically: false,
              supportMultipleWindows: false,
              allowFileAccess: false,
              allowContentAccess: false,
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
              blockNetworkLoads: true,
              mediaPlaybackRequiresUserGesture: true,
              allowsInlineMediaPlayback: false,
              useHybridComposition: true,
              useShouldOverrideUrlLoading: true,
              isInspectable: false,
            ),
            onWebViewCreated: (controller) {
              _webViewController = controller;
              WebViewSettings.registerJsErrorReporter(controller);
            },
            onLoadStop: (_, _) {
              if (!mounted ||
                  webViewGeneration != _generation ||
                  !widget.active) {
                return;
              }
              _prepareTimer?.cancel();
              _prepareTimer = null;
              _host.markReady();
              _scheduleSync();
            },
            onReceivedError: (_, request, error) {
              if (webViewGeneration == _generation &&
                  request.isForMainFrame == true) {
                _fail('main_frame_error', error);
              }
            },
            onReceivedHttpError: (_, request, response) {
              if (webViewGeneration == _generation &&
                  request.isForMainFrame == true) {
                _fail('main_frame_http_error', response.statusCode);
              }
            },
            onRenderProcessGone: (_, detail) {
              if (webViewGeneration == _generation) {
                _fail('render_process_gone', detail);
              }
            },
            shouldOverrideUrlLoading: (_, action) async {
              return NavigationActionPolicy.CANCEL;
            },
          )
        : const SizedBox.expand();

    return IgnorePointer(
      ignoring: true,
      child: SizedBox.expand(
        key: _hostKey,
        child: Opacity(
          opacity: _host.showFlutterSnapshot ? 0 : 1,
          child: child,
        ),
      ),
    );
  }
}

/// Static host document. SVG source is intentionally absent: it enters only
/// through the structured bridge argument and is converted to a Blob-backed
/// image, never assigned to innerHTML.
const String signatureSvgHostDocument = '''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src blob: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; object-src 'none'; frame-src 'none'; connect-src 'none'; font-src 'none';">
<style>
html, body, #root { width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; background: transparent; }
#root { position: relative; pointer-events: none; }
.signature-svg-slot { position: absolute; display: block; margin: 0; padding: 0; border: 0; pointer-events: none; transform-origin: 0 0; }
</style>
</head>
<body><div id="root"></div>
<script>
(function () {
  'use strict';
  const root = document.getElementById('root');
  const slots = new Map();
  const blobs = new Map();

  function retainBlob(source) {
    let entry = blobs.get(source);
    if (!entry) {
      entry = { url: URL.createObjectURL(new Blob([source], { type: 'image/svg+xml' })), refs: 0 };
      blobs.set(source, entry);
    }
    entry.refs += 1;
    return entry.url;
  }

  function releaseBlob(source) {
    const entry = blobs.get(source);
    if (!entry) return;
    entry.refs -= 1;
    if (entry.refs <= 0) {
      URL.revokeObjectURL(entry.url);
      blobs.delete(source);
    }
  }

  function applyRect(slot, update) {
    const image = slot.image;
    image.style.left = String(update.x) + 'px';
    image.style.top = String(update.y) + 'px';
    image.style.width = Math.max(0, update.width) + 'px';
    image.style.height = Math.max(0, update.height) + 'px';
    image.style.display = update.visible ? 'block' : 'none';
  }

  function addOrUpdate(update) {
    let slot = slots.get(update.id);
    if (!slot) {
      const image = document.createElement('img');
      image.className = 'signature-svg-slot';
      image.alt = '';
      image.draggable = false;
      image.setAttribute('aria-hidden', 'true');
      image.style.pointerEvents = 'none';
      root.appendChild(image);
      slot = { image: image, source: update.source };
      slot.url = retainBlob(update.source);
      image.src = slot.url;
      slots.set(update.id, slot);
    } else if (Object.prototype.hasOwnProperty.call(update, 'source') && slot.source !== update.source) {
      releaseBlob(slot.source);
      slot.source = update.source;
      slot.url = retainBlob(update.source);
      slot.image.src = slot.url;
    }
    applyRect(slot, update);
  }

  window.__fluxdoSyncSignatureSlots = async function (payload) {
    const upserts = Array.isArray(payload && payload.upserts) ? payload.upserts : [];
    const rects = Array.isArray(payload && payload.rects) ? payload.rects : [];
    const removed = Array.isArray(payload && payload.removed) ? payload.removed : [];
    for (const update of upserts) addOrUpdate(update);
    for (const update of rects) {
      const slot = slots.get(update.id);
      if (slot) applyRect(slot, update);
    }
    for (const id of removed) {
      const slot = slots.get(id);
      if (!slot) continue;
      releaseBlob(slot.source);
      slot.image.remove();
      slots.delete(id);
    }
    return { slots: slots.size, blobs: blobs.size };
  };
}());
</script>
</body>
</html>''';

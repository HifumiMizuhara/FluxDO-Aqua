import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'dynamic_content_suspension_service.dart';

/// Runtime policy for the crash/jank mitigation safeguards (image cache
/// limits, decode-size clamping, memory-pressure trimming, CF WebView
/// critical section). Always active on every platform; there is no opt-out
/// toggle. Originally Android-only (LMKD OOM kills), but Windows reports the
/// same raster-contention jank from unbounded decode sizes and concurrent
/// WebView churn, so the policy now applies everywhere.
class CrashMitigationService {
  CrashMitigationService._();

  static bool _observerAttached = false;
  static bool _cfWebViewCriticalSectionActive = false;
  static Completer<void>? _cfWebViewCriticalSectionCompleter;
  static final _memoryPressureObserver = _MemoryPressureObserver();

  static bool get enabled => true;

  /// Runs a Cloudflare WebView insertion/disposal window under the Aqua
  /// memory policy. This is intentionally separate from route transitions:
  /// CF handoff must not inherit route animation semantics or overlap another
  /// native WebView lifecycle operation.
  static Future<T> runCfWebViewCriticalSection<T>({
    required String reason,
    required Future<T> Function() action,
  }) async {
    if (!enabled) return action();

    while (_cfWebViewCriticalSectionActive) {
      await (_cfWebViewCriticalSectionCompleter?.future ??
          Future<void>.value());
    }

    final lease = DynamicContentSuspensionService.instance.acquire(
      reason: 'cf_webview:$reason',
    );
    _cfWebViewCriticalSectionActive = true;
    _cfWebViewCriticalSectionCompleter = Completer<void>();
    trimImageMemory(includeLiveImages: true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      return await action();
    } finally {
      // Let the platform view transaction submit before dynamic content is
      // allowed to resume on the same frame boundary.
      await WidgetsBinding.instance.endOfFrame;
      lease.release();
      _cfWebViewCriticalSectionActive = false;
      final completer = _cfWebViewCriticalSectionCompleter;
      _cfWebViewCriticalSectionCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
  }

  static bool get cfWebViewCriticalSectionActive =>
      _cfWebViewCriticalSectionActive;

  /// Kept as a no-op compatibility barrier for decode scheduling callers.
  /// Route transitions no longer add a global protected window.
  static Future<void> waitForRouteTransition() => Future<void>.value();

  /// Pushes a route using the app's normal page transition theme. Resource
  /// owners stop their own animation/video sessions when their route leaves;
  /// no global image-cache flush is needed before navigation.
  static Future<T?> pushRoute<T>({
    required NavigatorState navigator,
    required WidgetBuilder builder,
    RouteSettings? settings,
  }) async {
    return navigator.push(
      MaterialPageRoute<T>(builder: builder, settings: settings),
    );
  }

  /// Hard ceiling for standard Flutter image decodes while the experiment is
  /// enabled. This also covers providers that omit ResizeImage entirely.
  static const int maxDecodedDimension = 4096;
  static const int maxDecodedPixels = 8 * 1000 * 1000;

  /// Applies the crash mitigation cache policy. Call once at startup.
  static void init() {
    final cache = PaintingBinding.instance.imageCache;
    if (enabled) {
      if (!_observerAttached) {
        WidgetsBinding.instance.addObserver(_memoryPressureObserver);
        _observerAttached = true;
      }
      cache.maximumSizeBytes = 80 * 1024 * 1024;
      cache.maximumSize = 4000;
      return;
    }
    cache.maximumSizeBytes = 256 * 1024 * 1024;
    cache.maximumSize = 30000;
  }

  /// Releases image cache entries after a route with many images is closed or
  /// when the platform reports memory pressure. When [includeLiveImages] is true,
  /// entries still referenced by a mounted widget are also dropped from the
  /// live-image bookkeeping so they stop being held for potential reuse.
  static void trimImageMemory({bool includeLiveImages = false}) {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    if (includeLiveImages) {
      cache.clearLiveImages();
    }
  }

  /// Applies a conservative decode-time cap while preserving the source
  /// aspect ratio. The requested target is returned unchanged when it is
  /// already within the limits.
  static ui.TargetImageSize clampTargetSize(
    int intrinsicWidth,
    int intrinsicHeight,
    ui.TargetImageSize requested,
  ) {
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
      return requested;
    }

    final requestedWidth = requested.width;
    final requestedHeight = requested.height;
    final double targetWidth;
    final double targetHeight;

    if (requestedWidth != null && requestedHeight != null) {
      targetWidth = math.min(requestedWidth, intrinsicWidth).toDouble();
      targetHeight = math.min(requestedHeight, intrinsicHeight).toDouble();
    } else if (requestedWidth != null) {
      targetWidth = math.min(requestedWidth, intrinsicWidth).toDouble();
      targetHeight = intrinsicHeight * targetWidth / intrinsicWidth;
    } else if (requestedHeight != null) {
      targetHeight = math.min(requestedHeight, intrinsicHeight).toDouble();
      targetWidth = intrinsicWidth * targetHeight / intrinsicHeight;
    } else {
      targetWidth = intrinsicWidth.toDouble();
      targetHeight = intrinsicHeight.toDouble();
    }

    if (targetWidth <= 0 || targetHeight <= 0) return requested;
    final pixels = targetWidth * targetHeight;
    final scale = math.min(
      1.0,
      math.min(
        maxDecodedDimension / math.max(targetWidth, targetHeight),
        math.sqrt(maxDecodedPixels / pixels),
      ),
    );
    if (scale >= 1.0) return requested;

    return ui.TargetImageSize(
      width: math.max(1, (targetWidth * scale).round()),
      height: math.max(1, (targetHeight * scale).round()),
    );
  }

  /// Caps custom providers that accept a long-edge limit separately from the
  /// framework's standard ImageDecoderCallback.
  static int? effectiveMaxDimension(int? requested) {
    if (!enabled) return requested;
    if (requested == null) return maxDecodedDimension;
    return math.min(requested, maxDecodedDimension);
  }

  /// Limits only untrusted remote image payloads. Decoded pixels are larger,
  /// so these conservative transfer caps leave headroom for the raster cache.
  static int? imageDownloadLimit(String bucket) {
    if (!enabled) return null;
    return switch (bucket) {
      'original' => 20 * 1024 * 1024,
      'stickerOriginal' => 12 * 1024 * 1024,
      _ => 8 * 1024 * 1024,
    };
  }

  static const int maxTouchedImagePaths = 4096;
}

class _MemoryPressureObserver extends WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    CrashMitigationService.trimImageMemory(includeLiveImages: true);
  }
}

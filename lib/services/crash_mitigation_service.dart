import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'dynamic_content_suspension_service.dart';

/// Runtime policy for the opt-in Android crash mitigation experiment.
class CrashMitigationService {
  CrashMitigationService._();

  static bool _enabled = false;
  static bool _observerAttached = false;
  static bool _routeTransitionActive = false;
  static Completer<void>? _routeTransitionCompleter;
  static bool _cfWebViewCriticalSectionActive = false;
  static Completer<void>? _cfWebViewCriticalSectionCompleter;
  static final _memoryPressureObserver = _MemoryPressureObserver();

  static bool get enabled => _enabled && Platform.isAndroid;

  /// True while an Aqua-lab protected route is being prepared or animated in.
  /// Large image uploads wait for this window to close.
  static bool get routeTransitionActive => _routeTransitionActive;

  /// Completes when the current protected route transition has settled.
  static Future<void> waitForRouteTransition() {
    return _routeTransitionCompleter?.future ?? Future<void>.value();
  }

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

  /// Pushes a route with the memory-safe transition policy when the Android
  /// mitigation experiment is enabled. Other platforms retain the standard
  /// Material route and incur no extra scheduling delay.
  static Future<T?> pushRoute<T>({
    required NavigatorState navigator,
    required WidgetBuilder builder,
    RouteSettings? settings,
  }) async {
    if (!enabled) {
      return navigator.push(
        MaterialPageRoute<T>(builder: builder, settings: settings),
      );
    }

    // Do not let two taps overlap their outgoing and incoming resource
    // windows. The second request waits for the first route's animation to
    // settle, then gets its own protected transition.
    while (_routeTransitionActive) {
      await waitForRouteTransition();
    }

    final lease = DynamicContentSuspensionService.instance.acquire(
      reason: 'protected_route_transition',
    );
    _beginRouteTransition();
    trimImageMemory(includeLiveImages: true);
    try {
      // Give the outgoing route two frame boundaries to detach overlays,
      // rebuild the layer tree, and submit pending native disposals.
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;

      final route = _AquaProtectedPageRoute<T>(
        builder: builder,
        settings: settings,
        onTransitionComplete: () {
          lease.release();
          _endRouteTransition();
        },
      );
      final result = navigator.push<T>(route);
      // Covers routes that are popped or removed before their forward
      // animation reports completed.
      result.whenComplete(() {
        lease.release();
        _endRouteTransition();
      });
      return result;
    } catch (_) {
      lease.release();
      _endRouteTransition();
      rethrow;
    }
  }

  static void _beginRouteTransition() {
    if (_routeTransitionActive) return;
    _routeTransitionActive = true;
    _routeTransitionCompleter = Completer<void>();
  }

  static void _endRouteTransition() {
    if (!_routeTransitionActive) return;
    _routeTransitionActive = false;
    final completer = _routeTransitionCompleter;
    _routeTransitionCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Hard ceiling for standard Flutter image decodes while the experiment is
  /// enabled. This also covers providers that omit ResizeImage entirely.
  static const int maxDecodedDimension = 4096;
  static const int maxDecodedPixels = 8 * 1000 * 1000;

  static void configure(bool value) {
    _enabled = value;
    final cache = PaintingBinding.instance.imageCache;
    if (enabled) {
      if (!_observerAttached) {
        WidgetsBinding.instance.addObserver(_memoryPressureObserver);
        _observerAttached = true;
      }
      cache.maximumSizeBytes = 80 * 1024 * 1024;
      cache.maximumSize = 4000;
      // Enabling the experiment at runtime must also trim entries that were
      // created before the tighter limits took effect.
      trimImageMemory(includeLiveImages: true);
      return;
    }
    if (_observerAttached) {
      WidgetsBinding.instance.removeObserver(_memoryPressureObserver);
      _observerAttached = false;
    }
    cache.maximumSizeBytes = 256 * 1024 * 1024;
    cache.maximumSize = 30000;
  }

  /// Releases image cache entries after a route with many images is closed or
  /// when Android reports memory pressure. Live images still referenced by a
  /// mounted widget cannot be reclaimed here, but their cache bookkeeping is
  /// released and all disposable entries are removed.
  static void trimImageMemory({bool includeLiveImages = false}) {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    if (includeLiveImages) cache.clearLiveImages();
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

/// Memory-safe route used only by the opt-in Android mitigation experiment.
/// A short fade avoids the default route transform while the outgoing page is
/// still holding its images and native textures.
class _AquaProtectedPageRoute<T> extends MaterialPageRoute<T> {
  _AquaProtectedPageRoute({
    required super.builder,
    super.settings,
    required this.onTransitionComplete,
  });

  final VoidCallback onTransitionComplete;
  bool _transitionCompleted = false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  void _handleAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _transitionCompleted) return;
    _transitionCompleted = true;
    animation?.removeStatusListener(_handleAnimationStatus);
    onTransitionComplete();
  }

  @override
  TickerFuture didPush() {
    final routeAnimation = animation;
    routeAnimation?.addStatusListener(_handleAnimationStatus);
    final result = super.didPush();
    if (routeAnimation == null ||
        routeAnimation.status == AnimationStatus.completed) {
      _handleAnimationStatus(AnimationStatus.completed);
    }
    return result;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    );
  }

  @override
  void dispose() {
    animation?.removeStatusListener(_handleAnimationStatus);
    super.dispose();
  }
}

class _MemoryPressureObserver extends WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    CrashMitigationService.trimImageMemory(includeLiveImages: true);
  }
}

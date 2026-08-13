import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Runtime policy for the opt-in Android crash mitigation experiment.
class CrashMitigationService {
  CrashMitigationService._();

  static bool _enabled = false;
  static bool _observerAttached = false;
  static final _memoryPressureObserver = _MemoryPressureObserver();

  static bool get enabled => _enabled && Platform.isAndroid;

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

class _MemoryPressureObserver extends WidgetsBindingObserver {
  @override
  void didHaveMemoryPressure() {
    CrashMitigationService.trimImageMemory(includeLiveImages: true);
  }
}

import 'dart:io';

import 'package:flutter/painting.dart';

/// Runtime policy for the opt-in Android crash mitigation experiment.
class CrashMitigationService {
  CrashMitigationService._();

  static bool _enabled = false;

  static bool get enabled => _enabled && Platform.isAndroid;

  static void configure(bool value) {
    _enabled = value;
    final cache = PaintingBinding.instance.imageCache;
    if (enabled) {
      cache.maximumSizeBytes = 80 * 1024 * 1024;
      cache.maximumSize = 4000;
      return;
    }
    cache.maximumSizeBytes = 256 * 1024 * 1024;
    cache.maximumSize = 30000;
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

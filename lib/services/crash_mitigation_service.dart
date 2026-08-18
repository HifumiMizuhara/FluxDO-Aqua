import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'dynamic_content_suspension_service.dart';
import 'memory_pressure_registry.dart';

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
    // ここは以前 imageCache の全消し（live 画像込み）だった。CF 検証は
    // 通常のブラウジング中に何度も走るので、そのたびに表示中の画像まで
    // 捨てると「CF を抜けた直後に全部再デコード」という自作のジャンクを
    // 生む。ネイティブ WebView 挿入のために空けたいのは *余剰* であって
    // 表示中の分ではないので soft トリムに落とす。
    trimMemory(MemoryPressureLevel.soft);
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

  /// 画像キャッシュの通常上限。全プラットフォーム共通 —— Android の
  /// LMKD kill だけでなく Windows の raster 競合ジャンクも同じ原因
  /// （デコード量が青天井）なので、プラットフォーム分岐はしない。
  ///
  /// この値の設定は [init] が唯一の持ち主。以前は main() 側にも同じ
  /// フィールドへの代入があり、`init()` の直後に Android 以外を 256MB へ
  /// 戻していた（= 非 Android では対策が丸ごと無効だった）。
  static const int imageCacheMaxBytes = 80 * 1024 * 1024;
  static const int imageCacheMaxEntries = 4000;

  /// soft トリムで一時的に適用する上限（通常の 1/4）。
  ///
  /// `maximumSizeBytes` の setter は代入時点で LRU 追い出しを走らせる。
  /// 下げてから戻すことで「余剰エントリだけ捨てて上限は元のまま」を
  /// 副作用なしに実現できる。表示中の画像は live 参照が生きているので
  /// 追い出されず、再デコードも起きない。
  static const int _softTrimBytes = imageCacheMaxBytes ~/ 4;
  static const int _softTrimEntries = imageCacheMaxEntries ~/ 4;

  /// Applies the crash mitigation cache policy. Call once at startup.
  static void init() {
    if (!_observerAttached) {
      WidgetsBinding.instance.addObserver(_memoryPressureObserver);
      _observerAttached = true;
    }
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = imageCacheMaxBytes;
    cache.maximumSize = imageCacheMaxEntries;
  }

  /// 段階付きのメモリ解放。画像キャッシュと、[MemoryPressureRegistry] に
  /// 登録された自作キャッシュ群の両方に効く。
  ///
  /// - [MemoryPressureLevel.soft]：余剰エントリだけ落とす。表示中の
  ///   画像には触らないので体感変化なし。CF WebView 挿入前など、
  ///   「一時的にヘッドルームが欲しい」場面用。
  /// - [MemoryPressureLevel.hard]：システムからの圧。キャッシュ済み分は
  ///   捨てるが、**live 画像は落とさない** —— 圧が来ている最中に表示中の
  ///   画像を再デコードさせるのは最悪手。
  ///
  /// [includeLiveImages] はバックグラウンド遷移専用の例外。描画が止まって
  /// いるので再デコードの即時コストがなく、常駐量を下げて LMKD の
  /// 撃ち殺しを避ける方が得になる（[trimForBackground] 参照）。
  static void trimMemory(
    MemoryPressureLevel level, {
    bool includeLiveImages = false,
  }) {
    final cache = PaintingBinding.instance.imageCache;
    switch (level) {
      case MemoryPressureLevel.soft:
        cache.maximumSizeBytes = _softTrimBytes;
        cache.maximumSize = _softTrimEntries;
        cache.maximumSizeBytes = imageCacheMaxBytes;
        cache.maximumSize = imageCacheMaxEntries;
      case MemoryPressureLevel.hard:
        cache.clear();
        if (includeLiveImages) {
          cache.clearLiveImages();
        }
    }
    MemoryPressureRegistry.dispatch(level);
  }

  /// システムのメモリ圧（iOS メモリ警告 / Android onTrimMemory /
  /// 金標連盟の公平メモリ TRIM 放送）の唯一の入口。
  static void handleSystemMemoryPressure() {
    trimMemory(MemoryPressureLevel.hard);
  }

  /// バックグラウンド遷移時の解放（モバイルのみ呼ばれる想定）。
  /// 画面が止まっているので live 画像まで手放す。
  static void trimForBackground() {
    trimMemory(MemoryPressureLevel.hard, includeLiveImages: true);
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
    CrashMitigationService.handleSystemMemoryPressure();
  }
}

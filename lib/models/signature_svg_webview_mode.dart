/// Renderer used for SVG content inside post signatures.
enum SignatureSvgWebViewMode {
  /// Use the Flutter SVG renderer and do not create a platform WebView.
  native,

  /// Give every mounted SVG signature its own platform WebView.
  singleWebView,

  /// Limit live platform WebViews to a small, shared pool.
  webViewPool;

  bool get usesWebView => this != SignatureSvgWebViewMode.native;

  static SignatureSvgWebViewMode fromString(
    String? value, {
    bool legacyWebViewEnabled = false,
  }) {
    return SignatureSvgWebViewMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => legacyWebViewEnabled
          ? SignatureSvgWebViewMode.webViewPool
          : SignatureSvgWebViewMode.native,
    );
  }
}

const int kSignatureSvgWebViewPoolMinSize = 1;
const int kSignatureSvgWebViewPoolMaxSize = 3;
const int kSignatureSvgWebViewPoolDefaultSize = 2;

int clampSignatureSvgWebViewPoolSize(int value) {
  if (value < kSignatureSvgWebViewPoolMinSize) {
    return kSignatureSvgWebViewPoolMinSize;
  }
  if (value > kSignatureSvgWebViewPoolMaxSize) {
    return kSignatureSvgWebViewPoolMaxSize;
  }
  return value;
}

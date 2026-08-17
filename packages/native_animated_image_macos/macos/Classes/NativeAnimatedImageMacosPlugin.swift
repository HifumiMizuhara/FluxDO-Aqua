import Cocoa
import FlutterMacOS

/// macOS plugin entry point.
///
/// Sole responsibility: package `libnative_animated_image_codec.dylib` so
/// `DynamicLibrary.process()` on the Dart side can resolve symbols for
/// GIF/APNG/WebP decoding.
///
/// **v0.3.0 change**: AVIF method channel + ImageIO bridge removed. The Rust
/// pipeline no longer supports AVIF. Use `flutter_avif` package for AVIF
/// in your app.
public class NativeAnimatedImageMacosPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // No method channel needed — Rust FFI is the entire surface.
  }
}

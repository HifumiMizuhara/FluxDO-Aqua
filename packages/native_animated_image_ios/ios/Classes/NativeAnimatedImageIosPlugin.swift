import Flutter
import UIKit

/// iOS plugin entry point.
///
/// Sole responsibility: package the Rust dylib (via the bundled xcframework)
/// so `DynamicLibrary.process()` on the Dart side can resolve symbols from
/// `native_animated_image_codec` for GIF/APNG/WebP decoding.
///
/// **v0.3.0 change**: AVIF method channel + ImageIO bridge removed. The Rust
/// pipeline no longer supports AVIF (zenavif/rav1d had ARM SIMD crash bugs,
/// see CHANGELOG). Use `flutter_avif` package for AVIF in your app.
public class NativeAnimatedImageIosPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // No method channel needed — Rust FFI is the entire surface.
  }
}

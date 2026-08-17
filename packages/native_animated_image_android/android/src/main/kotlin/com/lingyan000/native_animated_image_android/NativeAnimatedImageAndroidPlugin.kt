package com.lingyan000.native_animated_image_android

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Android plugin entry point.
 *
 * Sole responsibility: package the Rust shared libraries (under `jniLibs/{abi}/`)
 * so `DynamicLibrary.open('libnative_animated_image_codec.so')` on the Dart
 * side can resolve symbols for GIF/APNG/WebP decoding.
 *
 * **v0.3.0 change**: AVIF method channel + ImageDecoder bridge removed.
 * The Rust pipeline no longer supports AVIF (zenavif/rav1d had ARM SIMD
 * crash bugs). Use `flutter_avif` package for AVIF in your app.
 */
class NativeAnimatedImageAndroidPlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // No method channel needed — Rust FFI is the entire surface.
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // No-op
  }
}

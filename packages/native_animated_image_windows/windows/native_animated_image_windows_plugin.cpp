// FFI-only plugin: this C++ stub exists solely because Flutter's Windows
// plugin tooling requires a SHARED library target. All actual functionality
// lives in `native_animated_image_codec.dll` (Rust), accessed from Dart via
// dart:ffi.
//
// No method channel handlers, no plugin registration logic.

#include <flutter/plugin_registrar_windows.h>

extern "C" __declspec(dllexport) void NativeAnimatedImageWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef /*registrar*/) {
  // No registration needed.
}

// FFI-only plugin: this C++ stub exists solely because Flutter's Linux plugin
// tooling requires a SHARED library target. All actual functionality lives in
// `libnative_animated_image_codec.so` (Rust), accessed from Dart via dart:ffi.
//
// No method channel handlers, no plugin registration logic.

#include <flutter_linux/flutter_linux.h>

G_DECLARE_FINAL_TYPE(NativeAnimatedImageLinuxPlugin,
                     native_animated_image_linux_plugin,
                     NATIVE_ANIMATED_IMAGE_LINUX,
                     PLUGIN,
                     GObject)

struct _NativeAnimatedImageLinuxPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(NativeAnimatedImageLinuxPlugin,
              native_animated_image_linux_plugin,
              g_object_get_type())

static void native_animated_image_linux_plugin_class_init(
    NativeAnimatedImageLinuxPluginClass* klass) {}

static void native_animated_image_linux_plugin_init(
    NativeAnimatedImageLinuxPlugin* self) {}

void native_animated_image_linux_plugin_register_with_registrar(
    FlPluginRegistrar* /*registrar*/) {
  // No registration needed - FFI plugin.
}

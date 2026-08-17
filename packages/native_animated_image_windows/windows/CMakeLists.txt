# native_animated_image_windows — FFI plugin scaffold
#
# Native binary (native_animated_image_codec.dll) is built by CI from
# `crates/native_animated_image_codec/` (see .github/workflows/release.yml)
# and committed to `windows/native_animated_image_codec.dll` before publish.
#
# This CMakeLists wires the prebuilt DLL into the host app's runtime
# directory so dart:ffi `DynamicLibrary.open('native_animated_image_codec.dll')`
# can find it.

cmake_minimum_required(VERSION 3.14)
project(native_animated_image_windows_library VERSION 0.1.0 LANGUAGES CXX)

set(PROJECT_VERSION 0.1.0)
set(CMAKE_CXX_STANDARD 17)

# Plugin name (used by Flutter tooling)
set(PLUGIN_NAME "native_animated_image_windows_plugin")

# Empty placeholder source to satisfy add_library; real functionality is the
# bundled DLL.
add_library(${PLUGIN_NAME} SHARED
  "native_animated_image_windows_plugin.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of bundled files for Flutter tooling to copy to app's runner output dir.
# native_animated_image_codec.dll is the Rust-built shared library.
set(native_animated_image_windows_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/native_animated_image_codec.dll"
  PARENT_SCOPE
)

# native_animated_image_linux — FFI plugin scaffold
#
# Native binary (libnative_animated_image_codec.so) is built by CI from
# `crates/native_animated_image_codec/` (see .github/workflows/release.yml)
# and committed to `linux/libnative_animated_image_codec.so` before publish.

cmake_minimum_required(VERSION 3.13)
set(PROJECT_NAME "native_animated_image_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "native_animated_image_linux_plugin")

list(APPEND PLUGIN_SOURCES
  "native_animated_image_linux_plugin.cc"
)

add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# Bundled shared library: libnative_animated_image_codec.so (Rust)
set(native_animated_image_linux_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/libnative_animated_image_codec.so"
  PARENT_SCOPE
)

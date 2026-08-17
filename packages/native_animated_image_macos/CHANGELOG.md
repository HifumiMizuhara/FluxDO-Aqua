# Changelog

## 0.3.2 - 2026-06-12

Native binary is now a **universal (arm64 + x86_64)** dylib. Earlier releases
shipped an arm64-only `libnative_animated_image_codec.dylib`, so building the
x86_64 slice of a macOS app dropped the codec at link time
(`ld: ignoring file ... required architecture x86_64`), leaving animated
GIF/APNG/WebP decoding unavailable on Intel Macs. The macOS build script now
cross-compiles both Apple targets and `lipo`s them into one fat dylib. No Dart
code change.

## 0.3.1 - 2026-06-10

Native binary rebuilt with a WebP decode fix: opaque (no-alpha) animated WebP no
longer crashes the app. `image-webp` expects a `w*h*3` (RGB) buffer for images
without an alpha channel, but the decoder always allocated `w*h*4`, tripping an
`assert_eq!` in `read_frame` and aborting the process. Decoder panics are now
also caught at the FFI boundary instead of aborting. See the main package
CHANGELOG for details.

## 0.3.0 - 2026-06-08

**BREAKING:** AVIF support removed from `native_animated_image`. See main package
CHANGELOG. Binary rebuilt without zenavif (rav1d), much smaller and no longer
requires nightly Rust on armv7.

## 0.2.2 - 2026-06-05

Native binary rebuilt — no code change in this platform package. Bumped
to stay in sync with `native_animated_image` 0.2.2 which adds Flutter
built-in codec fallback for static webp/png in NativeAnimatedImageProvider.

## 0.2.1 - 2026-06-05

- Version bump alongside main package 0.2.1. Native binary now includes
  pure-Rust AVIF decoder (`zenavif`) — covers AVIF fallback when this
  platform's system decoder isn't available (older OS versions, etc.).


## 0.2.0 - 2026-06-05

- Added Swift bridge to system ImageIO for AVIF decoding (static + animated
  on macOS 13.4+).
  Used by main package's `NativeAvifPlatform`. Matches Safari performance.
- Registered as both `ffiPlugin` (Rust codec) and `pluginClass`
  (AVIF method channel).


## 0.1.0 - 2026-06-04

Initial release. macos platform implementation of `native_animated_image` (ships the Rust-built native binary).

# Changelog

## 0.3.2 - 2026-06-12

Version bump only, to stay aligned with the monorepo (0.3.2 ships a macOS
universal-binary fix). No code or native binary change on this platform.

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

- Native binary now includes pure-Rust AVIF decoder (`zenavif` =
  rav1d + zenavif-parse). Animated AVIF on Android, which Android's
  system `ImageDecoder` can decode but doesn't expose per-frame access
  for, now works via the Rust path.
- `tool/build_native.dart android` splits build: stable Rust for
  arm64-v8a / x86_64 / x86, nightly Rust for armeabi-v7a (rav1d needs
  nightly on arm32 due to unstable `stdarch_arm_feature_detection`).


## 0.2.0 - 2026-06-05

- Added Kotlin bridge to system `ImageDecoder` for **static AVIF** on
  Android API 31+. Used by main package's `NativeAvifPlatform`.
- Animated AVIF currently throws `UnsupportedOperationException` —
  callers should fall back to their own backend (e.g. flutter_avif).
- Registered as both `ffiPlugin` (Rust codec) and `pluginClass`
  (AVIF method channel).


## 0.1.0 - 2026-06-04

Initial release. android platform implementation of `native_animated_image` (ships the Rust-built native binary).

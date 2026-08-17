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

- Version bump alongside main package 0.2.1. Native binary now includes
  pure-Rust AVIF decoder (`zenavif`) — covers AVIF fallback when this
  platform's system decoder isn't available (older OS versions, etc.).


## 0.2.0 - 2026-06-05

- Added Swift bridge to system ImageIO for AVIF decoding (static + animated
  on iOS 16.4+).
  Used by main package's `NativeAvifPlatform`. Matches Safari performance.
- Registered as both `ffiPlugin` (Rust codec) and `pluginClass`
  (AVIF method channel).


## 0.1.2 - 2026-06-05

- Switch the bundled Rust binary from static `.a` to dynamic framework
  (cdylib in a `.framework` bundle, packed into an xcframework with
  ios-arm64 + ios-arm64-simulator slices).
- Why: static-lib FFI symbols get dead-stripped (no compile-time
  caller); `-force_load` workarounds break in Xcode 16's strict
  build-input validation. Dylib is loaded by dyld at app launch and
  every symbol is immediately visible to `DynamicLibrary.process()`.
- Podspec simplified: just `vendored_frameworks` on the xcframework,
  no more SDK-conditional LIBRARY_SEARCH_PATHS / OTHER_LDFLAGS hacks.

## 0.1.1 - 2026-06-05

- Switch from separate `Libs/{device,simulator}/*.a` + SDK-conditional
  `LIBRARY_SEARCH_PATHS` to a single `Libs/native_animated_image_codec.xcframework`.
- Fixes "Library 'native_animated_image_codec' not found" linker error
  when consumed via pub.dev (the old podspec used a monorepo-relative
  path that didn't survive packaging).

## 0.1.0 - 2026-06-04

Initial release. ios platform implementation of `native_animated_image` (ships the Rust-built native binary).

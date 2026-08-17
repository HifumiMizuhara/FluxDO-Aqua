# native_animated_image

Native (Rust) decoder & renderer for animated GIF / APNG / WebP in Flutter.

Bypasses Flutter's built-in Skia `multi_frame_codec` to avoid long-standing
upstream bugs:

- [flutter/flutter#85831 — `Could not getPixels for frame N`](https://github.com/flutter/flutter/issues/85831) (open 4+ years)
- [flutter/flutter#94205 — Some frames of gif are decoded incorrectly](https://github.com/flutter/flutter/issues/94205) (open 4+ years)

## Usage

```dart
import 'package:native_animated_image/native_animated_image.dart';

// From bytes (e.g. via your own cache manager / network client)
Image(
  image: NativeAnimatedImageProvider.memory(gifBytes, tag: 'unique-key'),
)

// From a custom byte loader (recommended for production — bring your own
// HTTP client / cache layer)
Image(
  image: NativeAnimatedImageProvider.fromBytesProvider(
    loader: () async => myCacheManager.getBytes(url),
    tag: url,
  ),
)
```

## Install

```yaml
dependencies:
  native_animated_image: ^0.3.3
```

`flutter pub get` will automatically pull the right platform plugin
(`native_animated_image_macos` / `_ios` / `_android` / `_windows` / `_linux`)
for your target.

## Supported formats

| Format | Status | Notes |
|---|---|---|
| GIF | ✅ | Full disposal/transparency handling |
| APNG | ✅ | All blend & dispose ops |
| Animated WebP | ✅ | Lossy + lossless |
| Static PNG / WebP / JPEG | (handled by Flutter built-in) | Provider falls through to `CachedNetworkImageProvider` style flow |

## Platforms

| Platform | Architecture | Status |
|---|---|---|
| macOS | arm64 | ✅ |
| iOS | arm64 (device + simulator) | ✅ |
| Android | arm64-v8a / armeabi-v7a / x86_64 / x86 | ✅ |
| Windows | x86_64 | ✅ |
| Linux | x86_64 | ✅ |
| Web | — | Not supported (Skia path on web works fine) |

## License

MIT — see [LICENSE](../../LICENSE).

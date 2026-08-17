# native_animated_image_linux

The linux platform implementation of [`native_animated_image`](https://pub.dev/packages/native_animated_image).

This is an FFI plugin — it carries the prebuilt Rust binary
`native_animated_image_codec` and does not expose any direct API. Use the
main [`native_animated_image`](https://pub.dev/packages/native_animated_image)
package, which depends on this one transitively.

## License

MIT — see [LICENSE](../../LICENSE).

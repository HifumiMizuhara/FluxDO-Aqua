//! animage_codec - 动图解码 (GIF / APNG / animated WebP) 通过 FFI 暴露给 Flutter
//!
//! 设计目标:绕开 Flutter Skia multi_frame_codec 的解码 bug
//! (如 #85831 - "Could not getPixels for frame N"),提供稳定的跨平台动图解码。
//!
//! 调用流程(C FFI):
//!   1. animage_decode(bytes, len, &out_handle) -> handle
//!   2. animage_get_metadata_json(handle) -> JSON 字符串 (width/height/loop_count/frames)
//!   3. animage_get_frame_rgba(handle, idx, &out_ptr, &out_len) -> 零拷贝 RGBA 数据指针
//!   4. animage_release(handle) -> 释放整个解码结果
//!   5. animage_free_string(s) -> 释放 metadata 字符串

use parking_lot::Mutex;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::OnceLock;
use thiserror::Error;

pub mod apng_decoder;
pub mod ffi;
pub mod gif_decoder;
pub mod webp_decoder;
pub mod streaming;

/// 解码后的动图(全帧 RGBA + 元数据)
pub struct DecodedImage {
    pub width: u32,
    pub height: u32,
    /// GIF NETSCAPE2.0 loop count: 0 = 无限循环, N = 播放 N+1 次
    pub loop_count: u32,
    pub frames: Vec<Frame>,
}

pub struct Frame {
    /// 全尺寸 RGBA(已合成 disposal/transparency),长度 = width * height * 4
    pub rgba: Vec<u8>,
    /// 该帧的展示时长(毫秒)
    pub delay_ms: u32,
}

#[derive(Debug, Serialize)]
pub struct MetadataJson {
    pub width: u32,
    pub height: u32,
    pub loop_count: u32,
    pub frame_count: u32,
    pub frames: Vec<FrameMetadata>,
}

#[derive(Debug, Serialize)]
pub struct FrameMetadata {
    pub delay_ms: u32,
}

#[derive(Debug, Error)]
pub enum DecodeError {
    #[error("input bytes too short or null")]
    InvalidInput,

    #[error("unsupported format (magic bytes not recognized)")]
    UnsupportedFormat,

    #[error("GIF decode error: {0}")]
    Gif(String),

    #[error("PNG/APNG decode error: {0}")]
    Png(String),

    #[error("WebP decode error: {0}")]
    Webp(String),

    #[error("decoded result has zero frames")]
    EmptyFrames,
}

/// 根据 magic bytes 分发到对应解码器
///
/// 静态 PNG / 静态 WebP 会返回 [DecodeError::UnsupportedFormat],由 dart 端 fallback
/// 到 Flutter 内置 codec(静态格式 Flutter Skia 解码稳定,无需 Rust)。
pub fn decode_bytes(bytes: &[u8]) -> Result<DecodedImage, DecodeError> {
    if bytes.len() < 12 {
        return Err(DecodeError::InvalidInput);
    }

    // GIF: "GIF87a" / "GIF89a"
    if &bytes[0..6] == b"GIF87a" || &bytes[0..6] == b"GIF89a" {
        return gif_decoder::decode(bytes);
    }

    // PNG/APNG: 0x89 'P' 'N' 'G' \r \n \x1a \n
    if bytes[0..8] == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] {
        // apng_decoder 会检查是否有 acTL chunk,如果是静态 PNG 返回 UnsupportedFormat
        return apng_decoder::decode(bytes);
    }

    // WebP: "RIFF" .... "WEBP"
    if &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        // webp_decoder 会检查是否有 ANIM chunk,如果是静态 WebP 返回 UnsupportedFormat
        return webp_decoder::decode(bytes);
    }

    // AVIF (ISO BMFF ftyp box) 在 v0.3.0 后明确不在此包范围内。
    // v0.2.x 曾用 zenavif(rav1d-safe)做 fallback,但 rav1d 在 ARM SIMD path
    // 有 panic crash bug(mc_arm.rs 越界)+ armv7 需要 nightly toolchain,
    // 综合判断不适合作为生产依赖。AVIF 解码请使用 `flutter_avif` 包
    // (libavif + dav1d C 库,工业标准,稳定)。
    //
    // 这里直接返 UnsupportedFormat,dart 端 [NativeAnimatedImageProvider] 内的
    // Flutter codec fallback 会兜底(Skia 在 iOS 16.4+ / Android 14+ 支持 AVIF
    // 静态解码);完整动画 AVIF 调用方应该自己 router 走 flutter_avif。

    Err(DecodeError::UnsupportedFormat)
}

impl DecodedImage {
    pub fn to_metadata(&self) -> MetadataJson {
        MetadataJson {
            width: self.width,
            height: self.height,
            loop_count: self.loop_count,
            frame_count: self.frames.len() as u32,
            frames: self
                .frames
                .iter()
                .map(|f| FrameMetadata {
                    delay_ms: f.delay_ms,
                })
                .collect(),
        }
    }
}

// ============== Handle Registry (用于 FFI 跨调用持有解码结果) ==============

/// 全局 handle -> DecodedImage 映射
fn registry() -> &'static Mutex<HashMap<u64, DecodedImage>> {
    static REG: OnceLock<Mutex<HashMap<u64, DecodedImage>>> = OnceLock::new();
    REG.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 自增 handle 计数器
fn next_handle() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

pub(crate) fn register(image: DecodedImage) -> u64 {
    let handle = next_handle();
    registry().lock().insert(handle, image);
    handle
}

pub(crate) fn release(handle: u64) {
    registry().lock().remove(&handle);
}

/// 对 handle 对应的 DecodedImage 执行只读访问
pub(crate) fn with_image<F, R>(handle: u64, f: F) -> Option<R>
where
    F: FnOnce(&DecodedImage) -> R,
{
    let guard = registry().lock();
    guard.get(&handle).map(f)
}

// ============== 测试 ==============

#[cfg(test)]
mod tests {
    use super::*;

    /// 最小 GIF89a:1x1 单帧透明 GIF
    /// 这是个最小 valid GIF,用于冒烟测试
    const TINY_GIF: &[u8] = &[
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // "GIF89a"
        0x01, 0x00, 0x01, 0x00, // 1x1
        0x80, 0x00, 0x00, // global color table flag + bg color index
        0x00, 0x00, 0x00, 0xff, 0xff, 0xff, // 2-entry palette (black + white)
        0x21, 0xf9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, // GCE
        0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // image desc
        0x02, 0x02, 0x4c, 0x01, 0x00, // image data
        0x3b, // trailer
    ];

    #[test]
    fn test_decode_tiny_gif() {
        let img = decode_bytes(TINY_GIF).expect("decode tiny GIF");
        assert_eq!(img.width, 1);
        assert_eq!(img.height, 1);
        assert_eq!(img.frames.len(), 1);
        assert_eq!(img.frames[0].rgba.len(), 4); // 1*1*4
    }

    #[test]
    fn test_unsupported_format() {
        // JPEG magic bytes — dispatcher 不识别,直接返 UnsupportedFormat
        let jpeg_bytes = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01"; // JPEG signature + JFIF
        let result = decode_bytes(jpeg_bytes);
        assert!(matches!(result, Err(DecodeError::UnsupportedFormat)));
    }

    #[test]
    fn test_invalid_input() {
        assert!(matches!(decode_bytes(&[]), Err(DecodeError::InvalidInput)));
        assert!(matches!(
            decode_bytes(b"abc"),
            Err(DecodeError::InvalidInput)
        ));
    }

    #[test]
    fn test_metadata_json_serializable() {
        let img = decode_bytes(TINY_GIF).unwrap();
        let meta = img.to_metadata();
        let json = serde_json::to_string(&meta).expect("serialize metadata");
        assert!(json.contains("\"width\":1"));
        assert!(json.contains("\"height\":1"));
        assert!(json.contains("\"frame_count\":1"));
    }

    #[test]
    fn test_handle_registry() {
        let img = decode_bytes(TINY_GIF).unwrap();
        let h = register(img);
        assert!(h > 0);
        let width = with_image(h, |i| i.width);
        assert_eq!(width, Some(1));
        release(h);
        assert!(with_image(h, |i| i.width).is_none());
    }
}

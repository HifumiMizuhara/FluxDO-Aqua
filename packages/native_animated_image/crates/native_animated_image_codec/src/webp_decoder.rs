//! Animated WebP 解码器
//!
//! 用 `image-webp` crate 解,支持动画 WebP(VP8X + ANIM + ANMF chunks)和
//! 静态 WebP(VP8/VP8L)。
//!
//! 与 GIF/APNG 不同,image-webp 内部已处理 dispose/blend,直接给我们出每帧的
//! 全尺寸像素(用 `read_frame` API)。注意 image-webp 对无 alpha 通道的图输出的是
//! 紧密 RGB(3B/px),只有带 alpha 时才是 RGBA(4B/px);我们统一展开成 Flutter 需要
//! 的 RGBA8888。

use crate::{DecodeError, DecodedImage, Frame};
use image_webp::WebPDecoder;
use std::io::Cursor;

pub fn decode(bytes: &[u8]) -> Result<DecodedImage, DecodeError> {
    let cursor = Cursor::new(bytes);
    let mut decoder = WebPDecoder::new(cursor)
        .map_err(|e| DecodeError::Webp(format!("WebPDecoder::new: {}", e)))?;

    let (width, height) = decoder.dimensions();
    if width == 0 || height == 0 {
        return Err(DecodeError::Webp(format!(
            "invalid dimensions: {}x{}",
            width, height
        )));
    }

    // image-webp 0.2 通过 num_frames > 1 判断是否动画(没有专门 has_animation 方法)
    let frame_count_raw = decoder.num_frames();
    if frame_count_raw <= 1 {
        // 静态 WebP: 我们不处理(交给 Flutter 内置 codec)
        return Err(DecodeError::UnsupportedFormat);
    }

    // 设置背景色(0 = 透明)
    decoder.set_background_color([0, 0, 0, 0]).ok();

    // image-webp 0.2: LoopCount::Times 是 NonZero<u16>,要 .get() 取值
    let loop_count: u32 = match decoder.loop_count() {
        image_webp::LoopCount::Forever => 0,
        image_webp::LoopCount::Times(n) => n.get() as u32,
    };

    let frame_count = frame_count_raw as usize;
    if frame_count == 0 {
        return Err(DecodeError::EmptyFrames);
    }

    // 关键:read_frame 要求 buf.len() == decoder.output_buffer_size(),后者在
    // 无 alpha 通道时是 w*h*3(RGB),有 alpha 时才是 w*h*4(RGBA)。早期硬编码
    // w*h*4,导致所有无 alpha(不透明 RGB)动画 WebP 触发 image-webp
    // decoder.rs:754 的 assert_eq! panic(线上 crash:left Some(w*h*4),
    // right Some(w*h*3))。这里改用库自报的尺寸,从根本上消除不匹配。
    let has_alpha = decoder.has_alpha();
    let frame_buf_size = decoder
        .output_buffer_size()
        .ok_or_else(|| DecodeError::Webp("output_buffer_size overflow".to_string()))?;

    // Flutter 端 ui.decodeImageFromPixels 需要 RGBA8888,Frame.rgba 统一为 w*h*4。
    let rgba_size = (width as usize) * (height as usize) * 4;
    let mut frames: Vec<Frame> = Vec::with_capacity(frame_count);

    for idx in 0..frame_count {
        let mut buf = vec![0u8; frame_buf_size];

        // 仍保留逐帧 catch_unwind 作为第二道防线:image-webp forbid(unsafe),面对
        // 其它畸形动画输入仍可能在内部 panic(而非返回 Err)。已解出 ≥1 帧就截断
        // 保留(动图少几帧 > 整图失败)。AssertUnwindSafe:闭包捕获 &mut decoder /
        // &mut buf;panic 后立即 break、不再触碰 decoder,被污染的状态不会被读到。
        let read = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            decoder.read_frame(&mut buf)
        }));

        let delay_ms = match read {
            // image-webp 0.2 read_frame 返回 delay_ms (u32)
            Ok(Ok(d)) => d,
            // read_frame 显式返回 Err
            Ok(Err(e)) => {
                if frames.is_empty() {
                    return Err(DecodeError::Webp(format!("read_frame[{}]: {}", idx, e)));
                }
                break;
            }
            // read_frame 内部 panic(其它畸形动画输入)
            Err(_) => {
                if frames.is_empty() {
                    return Err(DecodeError::Webp(format!(
                        "read_frame[{}] panicked: malformed animated WebP",
                        idx
                    )));
                }
                break;
            }
        };

        // 统一成 RGBA8888:无 alpha 时 image-webp 输出紧密 RGB(3B/px),补 alpha=255
        // 展开;有 alpha 时本就是 RGBA,直接用。
        let rgba = if has_alpha {
            buf
        } else {
            rgb_to_rgba(&buf, rgba_size)
        };

        let delay_ms_u32 = delay_ms as u32;
        frames.push(Frame {
            rgba,
            delay_ms: if delay_ms_u32 == 0 { 100 } else { delay_ms_u32 },
        });
    }

    // 截断后兜底:一帧都没成功解出则报空帧(正常情况下前面已 return)
    if frames.is_empty() {
        return Err(DecodeError::EmptyFrames);
    }

    Ok(DecodedImage {
        width,
        height,
        loop_count,
        frames,
    })
}

/// 把紧密排列的 RGB(3 字节/像素)展开成 RGBA(4 字节/像素),alpha 固定 255(不透明)。
/// 用于 image-webp 对无 alpha 通道的 WebP 输出 RGB 的情形。
fn rgb_to_rgba(rgb: &[u8], rgba_size: usize) -> Vec<u8> {
    let mut rgba = vec![0u8; rgba_size];
    for (src, dst) in rgb.chunks_exact(3).zip(rgba.chunks_exact_mut(4)) {
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = 255;
    }
    rgba
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_invalid_webp_data() {
        // 不是合法 WebP → 报错
        let bad = b"not a webp";
        assert!(decode(bad).is_err());
    }

    #[test]
    fn test_rgb_to_rgba_expands_with_opaque_alpha() {
        // 2 像素 RGB → RGBA,alpha 补 255。这是无 alpha 动画 WebP 的关键转换:
        // image-webp 对无 alpha 图输出紧密 RGB(w*h*3),我们展开成 Flutter 要的
        // RGBA8888(w*h*4) —— 既满足 read_frame 的 w*h*3 buffer 尺寸契约(避开
        // decoder.rs:754 的 assert panic),又满足 ui.decodeImageFromPixels。
        let rgb = [10u8, 20, 30, 40, 50, 60];
        let rgba = rgb_to_rgba(&rgb, 2 * 4);
        assert_eq!(rgba, [10, 20, 30, 255, 40, 50, 60, 255]);
    }

    // 真实 WebP fixture(静态/动画各一)由后续 build 准备阶段添加
}

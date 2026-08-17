//! APNG 解码器(Animated PNG)
//!
//! APNG 是 PNG 的动画扩展,通过 `acTL` / `fcTL` / `fdAT` chunk 实现。
//! 静态 PNG(无 `acTL`)由 Flutter 内置 codec 处理,这里只处理动画 PNG。
//!
//! 用 `png` crate 解,按 dispose_op / blend_op 规范合成全尺寸 RGBA。

use crate::{DecodeError, DecodedImage, Frame};
use png::{BlendOp, ColorType, DisposeOp, Transformations};
use std::io::Cursor;

pub fn decode(bytes: &[u8]) -> Result<DecodedImage, DecodeError> {
    // png 0.18 要求 Seek trait,&[u8] 没实现,包一层 Cursor
    let mut decoder = png::Decoder::new(Cursor::new(bytes));
    decoder.set_ignore_text_chunk(true);
    // 让 png crate 自动把 indexed / grayscale / 16-bit 转成 8-bit RGB/RGBA
    decoder.set_transformations(
        Transformations::EXPAND | Transformations::STRIP_16 | Transformations::ALPHA,
    );

    let mut reader = decoder
        .read_info()
        .map_err(|e| DecodeError::Png(format!("read_info: {}", e)))?;

    let info_snapshot = {
        let info = reader.info();
        InfoSnapshot {
            width: info.width,
            height: info.height,
            color_type: info.color_type,
            num_frames: info.animation_control().map(|a| a.num_frames).unwrap_or(1),
            loop_count: info.animation_control().map(|a| a.num_plays).unwrap_or(0),
            is_animated: info.animation_control().is_some(),
        }
    };

    if !info_snapshot.is_animated {
        // 静态 PNG — 我们 Rust pipeline 不处理,交回 Flutter 内置 codec
        return Err(DecodeError::UnsupportedFormat);
    }

    let canvas_w = info_snapshot.width;
    let canvas_h = info_snapshot.height;
    let canvas_size = (canvas_w as usize) * (canvas_h as usize) * 4;
    let mut canvas: Vec<u8> = vec![0u8; canvas_size];

    let buf_size = reader
        .output_buffer_size()
        .ok_or_else(|| DecodeError::Png("output_buffer_size unknown".into()))?;
    let mut frame_buf = vec![0u8; buf_size];

    let mut frames: Vec<Frame> = Vec::with_capacity(info_snapshot.num_frames as usize);

    for _frame_idx in 0..info_snapshot.num_frames {
        let oi = reader
            .next_frame(&mut frame_buf)
            .map_err(|e| DecodeError::Png(format!("next_frame: {}", e)))?;

        // OutputInfo 包含本帧 row 数据的尺寸/格式
        let frame_width = oi.width;
        let frame_height = oi.height;
        let frame_color_type = oi.color_type;
        let actual_buf_size = oi.buffer_size();
        let frame_pixels = &frame_buf[..actual_buf_size];

        // fcTL 控制(位置 / 时长 / disposal / blend)
        let (frame_x, frame_y, delay_ms, dispose_op, blend_op) = {
            let info = reader.info();
            let fctl = info
                .frame_control()
                .ok_or_else(|| DecodeError::Png("missing fcTL chunk".into()))?;
            let delay_den = if fctl.delay_den == 0 {
                100u32
            } else {
                fctl.delay_den as u32
            };
            let delay_ms = (fctl.delay_num as u32 * 1000) / delay_den;
            (
                fctl.x_offset,
                fctl.y_offset,
                if delay_ms == 0 { 100 } else { delay_ms },
                fctl.dispose_op,
                fctl.blend_op,
            )
        };

        // 保存 pre-frame canvas(只在 DisposeOp::Previous 时需要)
        let pre_frame_canvas: Vec<u8> = if matches!(dispose_op, DisposeOp::Previous) {
            canvas.clone()
        } else {
            Vec::new()
        };

        // 把帧 pixels 转换为 RGBA 后,按 blend_op 合成到 canvas 上
        let frame_rgba = pixels_to_rgba(frame_pixels, frame_color_type, frame_width, frame_height);

        composite_frame(
            &mut canvas,
            canvas_w,
            canvas_h,
            frame_x,
            frame_y,
            frame_width,
            frame_height,
            &frame_rgba,
            blend_op,
        );

        // 输出当前 canvas 作为这一帧
        frames.push(Frame {
            rgba: canvas.clone(),
            delay_ms,
        });

        // 处理 disposal,准备下一帧
        match dispose_op {
            DisposeOp::Background => {
                clear_region_to_transparent(
                    &mut canvas,
                    canvas_w,
                    canvas_h,
                    frame_x,
                    frame_y,
                    frame_width,
                    frame_height,
                );
            }
            DisposeOp::Previous => {
                canvas = pre_frame_canvas;
            }
            DisposeOp::None => {
                // keep canvas as is
            }
        }
    }

    if frames.is_empty() {
        return Err(DecodeError::EmptyFrames);
    }

    Ok(DecodedImage {
        width: canvas_w,
        height: canvas_h,
        loop_count: info_snapshot.loop_count,
        frames,
    })
}

struct InfoSnapshot {
    width: u32,
    height: u32,
    #[allow(dead_code)]
    color_type: ColorType,
    num_frames: u32,
    loop_count: u32,
    is_animated: bool,
}

/// 把 png crate 解出的 pixel buffer 转为 RGBA(适配各种 color type)
fn pixels_to_rgba(buf: &[u8], color_type: ColorType, width: u32, height: u32) -> Vec<u8> {
    let pixel_count = (width as usize) * (height as usize);
    match color_type {
        ColorType::Rgba => {
            // 已经是 RGBA
            buf.to_vec()
        }
        ColorType::Rgb => {
            let mut out = Vec::with_capacity(pixel_count * 4);
            for chunk in buf.chunks_exact(3) {
                out.push(chunk[0]);
                out.push(chunk[1]);
                out.push(chunk[2]);
                out.push(255);
            }
            out
        }
        ColorType::GrayscaleAlpha => {
            let mut out = Vec::with_capacity(pixel_count * 4);
            for chunk in buf.chunks_exact(2) {
                let v = chunk[0];
                out.push(v);
                out.push(v);
                out.push(v);
                out.push(chunk[1]);
            }
            out
        }
        ColorType::Grayscale => {
            let mut out = Vec::with_capacity(pixel_count * 4);
            for &v in buf {
                out.push(v);
                out.push(v);
                out.push(v);
                out.push(255);
            }
            out
        }
        ColorType::Indexed => {
            // 我们设了 Transformations::EXPAND,理论上 Indexed 不会出现这里
            // 兜底:当作 grayscale 处理
            let mut out = Vec::with_capacity(pixel_count * 4);
            for &v in buf {
                out.push(v);
                out.push(v);
                out.push(v);
                out.push(255);
            }
            out
        }
    }
}

/// 把帧 RGBA 数据按 blend_op 合成到全尺寸 canvas
#[inline]
#[allow(clippy::too_many_arguments)] // 像素坐标参数本身就多,拆 struct 反而冗余
fn composite_frame(
    canvas: &mut [u8],
    canvas_w: u32,
    canvas_h: u32,
    frame_x: u32,
    frame_y: u32,
    frame_w: u32,
    frame_h: u32,
    frame_rgba: &[u8],
    blend_op: BlendOp,
) {
    for fy in 0..frame_h {
        let dst_y = frame_y + fy;
        if dst_y >= canvas_h {
            break;
        }
        for fx in 0..frame_w {
            let dst_x = frame_x + fx;
            if dst_x >= canvas_w {
                break;
            }

            let src_idx = ((fy * frame_w + fx) * 4) as usize;
            let dst_idx = ((dst_y * canvas_w + dst_x) * 4) as usize;

            if src_idx + 3 >= frame_rgba.len() || dst_idx + 3 >= canvas.len() {
                continue;
            }

            let sr = frame_rgba[src_idx];
            let sg = frame_rgba[src_idx + 1];
            let sb = frame_rgba[src_idx + 2];
            let sa = frame_rgba[src_idx + 3];

            match blend_op {
                BlendOp::Source => {
                    // 直接覆盖(包含 alpha)
                    canvas[dst_idx] = sr;
                    canvas[dst_idx + 1] = sg;
                    canvas[dst_idx + 2] = sb;
                    canvas[dst_idx + 3] = sa;
                }
                BlendOp::Over => {
                    // alpha 合成: out = src + dst * (1 - src.alpha)
                    if sa == 255 {
                        // fully opaque source overrides
                        canvas[dst_idx] = sr;
                        canvas[dst_idx + 1] = sg;
                        canvas[dst_idx + 2] = sb;
                        canvas[dst_idx + 3] = 255;
                    } else if sa == 0 {
                        // fully transparent source — keep dst
                    } else {
                        let inv = 255u16 - sa as u16;
                        let dr = canvas[dst_idx] as u16;
                        let dg = canvas[dst_idx + 1] as u16;
                        let db = canvas[dst_idx + 2] as u16;
                        let da = canvas[dst_idx + 3] as u16;
                        canvas[dst_idx] = ((sr as u16 * sa as u16 + dr * inv) / 255) as u8;
                        canvas[dst_idx + 1] = ((sg as u16 * sa as u16 + dg * inv) / 255) as u8;
                        canvas[dst_idx + 2] = ((sb as u16 * sa as u16 + db * inv) / 255) as u8;
                        canvas[dst_idx + 3] = (sa as u16 + da * inv / 255).min(255) as u8;
                    }
                }
            }
        }
    }
}

#[inline]
fn clear_region_to_transparent(
    canvas: &mut [u8],
    canvas_w: u32,
    canvas_h: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) {
    for fy in 0..h {
        let dst_y = y + fy;
        if dst_y >= canvas_h {
            break;
        }
        for fx in 0..w {
            let dst_x = x + fx;
            if dst_x >= canvas_w {
                break;
            }
            let dst_idx = ((dst_y * canvas_w + dst_x) * 4) as usize;
            if dst_idx + 3 >= canvas.len() {
                continue;
            }
            canvas[dst_idx] = 0;
            canvas[dst_idx + 1] = 0;
            canvas[dst_idx + 2] = 0;
            canvas[dst_idx + 3] = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 最小静态 PNG (1x1 红色) — 用于测 "静态 PNG 被识别为 UnsupportedFormat"
    const TINY_STATIC_PNG: &[u8] = &[
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, // PNG signature
        0x00, 0x00, 0x00, 0x0d, // IHDR length
        0x49, 0x48, 0x44, 0x52, // "IHDR"
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
        0x08, 0x02, 0x00, 0x00, 0x00, // 8-bit RGB
        0x90, 0x77, 0x53, 0xde, // IHDR CRC
        0x00, 0x00, 0x00, 0x0c, // IDAT length
        0x49, 0x44, 0x41, 0x54, // "IDAT"
        0x08, 0x99, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x97, 0x5e, 0xfa,
        0x5b, // IDAT CRC
        0x00, 0x00, 0x00, 0x00, // IEND length
        0x49, 0x45, 0x4e, 0x44, // "IEND"
        0xae, 0x42, 0x60, 0x82, // IEND CRC
    ];

    #[test]
    fn test_static_png_returns_unsupported() {
        // 静态 PNG 不该走 Rust pipeline,由 Flutter 内置 codec 处理
        let result = decode(TINY_STATIC_PNG);
        assert!(matches!(result, Err(DecodeError::UnsupportedFormat)));
    }

    #[test]
    fn test_invalid_png_data() {
        // 不是合法 PNG → 报错
        let bad = b"not a png";
        let result = decode(bad);
        assert!(result.is_err());
    }

    // 注:真正的 APNG fixture 测试由 build_native 准备阶段添加(fixtures/),
    // 这里用静态 PNG 覆盖 "non-animated → unsupported" 路径
}

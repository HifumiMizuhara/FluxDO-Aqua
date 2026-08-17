//! GIF 解码器
//!
//! 用 `gif` crate 解码,按 GIF89a 规范处理 disposal/transparency,
//! 输出每帧的全尺寸 RGBA(width × height × 4 字节)+ delay。
//!
//! 关键设计:`gif` crate 的 `Frame::buffer` 只包含该帧的局部 RGBA 数据
//! (尺寸 = frame.width × frame.height,位置 = frame.left, frame.top),
//! 我们必须按 disposal 规则合成到全尺寸 canvas 上。
//!
//! 这正是 Flutter Skia multi_frame_codec 在某些 disposal=2 后续帧上
//! getPixels 失败的场景 — 这里我们用 image-rs/gif 的成熟实现绕开。

use crate::{DecodeError, DecodedImage, Frame};
use gif::{ColorOutput, DecodeOptions, DisposalMethod};

pub fn decode(bytes: &[u8]) -> Result<DecodedImage, DecodeError> {
    let mut opts = DecodeOptions::new();
    // 让 gif crate 自动应用调色板,输出 RGBA(包含 alpha 通道,透明像素 alpha=0)
    opts.set_color_output(ColorOutput::RGBA);

    let mut decoder = opts
        .read_info(bytes)
        .map_err(|e| DecodeError::Gif(format!("read_info failed: {}", e)))?;

    let width = decoder.width() as u32;
    let height = decoder.height() as u32;

    if width == 0 || height == 0 {
        return Err(DecodeError::Gif(format!(
            "invalid dimensions: {}x{}",
            width, height
        )));
    }

    let canvas_size = (width as usize) * (height as usize) * 4;
    let mut canvas: Vec<u8> = vec![0u8; canvas_size];
    let mut frames: Vec<Frame> = Vec::new();

    while let Some(frame) = decoder
        .read_next_frame()
        .map_err(|e| DecodeError::Gif(format!("read_next_frame failed: {}", e)))?
    {
        // 保存渲染前的 canvas 状态(用于 DisposalMethod::Previous 恢复)
        // 这里 clone 是必要的 — Previous disposal 需要回滚到本帧绘制之前的画面
        // 内存开销:width*height*4(典型 288×288 = 330KB)/ 帧,可接受
        let pre_frame_canvas: Vec<u8> = if matches!(frame.dispose, DisposalMethod::Previous) {
            canvas.clone()
        } else {
            Vec::new() // 不需要保存,空 vec 不占内存
        };

        // 把帧的局部 RGBA 数据合成到 canvas 上(只处理非透明像素)
        composite_frame_to_canvas(
            &mut canvas,
            width,
            height,
            frame.left as u32,
            frame.top as u32,
            frame.width as u32,
            frame.height as u32,
            &frame.buffer,
        );

        // 输出当前 canvas 作为这一帧的完整 RGBA
        // delay 是 1/100 秒为单位,转 ms;0 delay 给个合理默认(100ms)
        let delay_ms = (frame.delay as u32) * 10;
        frames.push(Frame {
            rgba: canvas.clone(),
            delay_ms: if delay_ms == 0 { 100 } else { delay_ms },
        });

        // 根据当前帧的 disposal 处理 canvas,准备下一帧绘制
        match frame.dispose {
            DisposalMethod::Background => {
                // GIF 规范说"恢复成 background color",但绝大多数解码器(Chrome/Firefox/macOS)
                // 实现为"该帧覆盖区域置为透明" — 这里跟随主流行为
                clear_region_to_transparent(
                    &mut canvas,
                    width,
                    height,
                    frame.left as u32,
                    frame.top as u32,
                    frame.width as u32,
                    frame.height as u32,
                );
            }
            DisposalMethod::Previous => {
                // 恢复到本帧绘制之前的 canvas
                canvas = pre_frame_canvas;
            }
            DisposalMethod::Any | DisposalMethod::Keep => {
                // Keep: 保留当前 canvas 给下一帧
                // Any (unspecified): 解码器自由处理,通常 treat as Keep
            }
        }
    }

    if frames.is_empty() {
        return Err(DecodeError::EmptyFrames);
    }

    // loop count:gif crate 0.13 不直接暴露 NETSCAPE2.0 extension 的 loop count
    // 默认 0 = 无限循环(与浏览器主流行为一致)
    let loop_count = 0;

    Ok(DecodedImage {
        width,
        height,
        loop_count,
        frames,
    })
}

/// 把局部 RGBA 帧数据合成到全尺寸 canvas 上(透明像素不覆盖)
#[inline]
#[allow(clippy::too_many_arguments)] // 像素坐标参数本身就多,拆 struct 反而冗余
fn composite_frame_to_canvas(
    canvas: &mut [u8],
    canvas_w: u32,
    canvas_h: u32,
    frame_x: u32,
    frame_y: u32,
    frame_w: u32,
    frame_h: u32,
    frame_buf: &[u8],
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

            // 边界检查(避免 panic)
            if src_idx + 3 >= frame_buf.len() || dst_idx + 3 >= canvas.len() {
                continue;
            }

            let alpha = frame_buf[src_idx + 3];
            // 透明像素不覆盖(保留 canvas 现有内容,这是 GIF transparency 语义)
            if alpha == 0 {
                continue;
            }

            canvas[dst_idx] = frame_buf[src_idx];
            canvas[dst_idx + 1] = frame_buf[src_idx + 1];
            canvas[dst_idx + 2] = frame_buf[src_idx + 2];
            canvas[dst_idx + 3] = alpha;
        }
    }
}

/// 把指定区域清成透明(用于 DisposalMethod::Background)
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

    /// 最小 GIF89a:1x1 单帧
    const TINY_GIF: &[u8] = &[
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4c, 0x01, 0x00, 0x3b,
    ];

    #[test]
    fn test_decode_minimal_gif() {
        let img = decode(TINY_GIF).expect("decode minimal GIF");
        assert_eq!(img.width, 1);
        assert_eq!(img.height, 1);
        assert_eq!(img.frames.len(), 1);
        assert_eq!(img.frames[0].rgba.len(), 4);
        // 0 delay → 默认 100ms
        assert_eq!(img.frames[0].delay_ms, 100);
    }

    #[test]
    fn test_invalid_gif_data() {
        let bad = b"GIF89a\x00\x00not a valid gif";
        assert!(decode(bad).is_err());
    }

    /// 测试目标 GIF(用户报的那张 ifgsll 头像 GIF)— frame 10 disposal=2
    /// 这是导致 Flutter Skia multi_frame_codec 在 frame 11 getPixels 失败的具体 case
    ///
    /// 注:实际 fixture 由 build/cargo test 时从 fixtures/ 目录读取(后续添加)
    /// 暂时只测一个最小 disposal=2 的人工构造 GIF
    #[test]
    fn test_disposal_background_synthetic() {
        // 2x2 GIF,2 frames,第 1 帧 disposal=2 (RestoreBackground)
        // 不便手工构造,这里用 gif crate 的 encoder 生成
        use gif::{Encoder, Frame as GifFrame, Repeat};

        let mut buf: Vec<u8> = Vec::new();
        {
            let mut encoder = Encoder::new(&mut buf, 2, 2, &[]).expect("create encoder");
            encoder.set_repeat(Repeat::Infinite).unwrap();

            // Frame 0: 全红色 (RGBA = 255,0,0,255 → indexed 0)
            let mut f0 = GifFrame::from_rgba(
                2,
                2,
                &mut [
                    255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255,
                ],
            );
            f0.dispose = DisposalMethod::Background;
            f0.delay = 4; // 40ms
            encoder.write_frame(&f0).unwrap();

            // Frame 1: 局部绿色 (1x1 at (0,0))
            let mut f1 = GifFrame::from_rgba(1, 1, &mut [0, 255, 0, 255]);
            f1.dispose = DisposalMethod::Keep;
            f1.delay = 4;
            encoder.write_frame(&f1).unwrap();
        }

        let img = decode(&buf).expect("decode synthetic disposal=2 GIF");
        assert_eq!(img.frames.len(), 2);
        assert_eq!(img.width, 2);
        assert_eq!(img.height, 2);

        // Frame 0 应该是全红色画面
        let f0 = &img.frames[0].rgba;
        assert_eq!(f0[0], 255); // R
        assert_eq!(f0[1], 0); // G

        // Frame 1: disposal=2 把 frame 0 清空,然后画 1x1 绿色到 (0,0)
        // 期望 (0,0)=绿色,其他=透明
        let f1 = &img.frames[1].rgba;
        // (0,0) 像素
        assert_eq!(f1[0], 0); // R
        assert_eq!(f1[1], 255); // G
        assert_eq!(f1[2], 0); // B
        assert_eq!(f1[3], 255); // A
                                // (1,0) 像素 应该透明
        assert_eq!(f1[4 + 3], 0); // A=0 透明
    }
}

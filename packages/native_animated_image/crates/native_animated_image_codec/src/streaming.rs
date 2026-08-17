//! Sequential animated-image decoder sessions.
//!
//! A session owns compressed input, decoder state, one compositing canvas and
//! the most recently requested frame. It never materializes the animation.

use crate::DecodeError;
use gif::{ColorOutput, DecodeOptions, DisposalMethod};
use image_webp::WebPDecoder;
use png::{BlendOp, ColorType, DisposeOp, Transformations};
use std::io::Cursor;

#[derive(Clone, Copy, Debug)]
pub struct StreamMetadata {
    pub width: u32,
    pub height: u32,
    pub frame_count: u32,
    pub loop_count: u32,
}

pub struct StreamFrame {
    pub rgba: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub delay_ms: u32,
}

pub enum StreamingDecoder {
    Gif(GifSession),
    Apng(ApngSession),
    Webp(WebpSession),
}

impl StreamingDecoder {
    pub fn open(bytes: &[u8], target_width: u32, target_height: u32) -> Result<Self, DecodeError> {
        if bytes.len() < 12 { return Err(DecodeError::InvalidInput); }
        if &bytes[0..6] == b"GIF87a" || &bytes[0..6] == b"GIF89a" {
            return GifSession::open(bytes.to_vec(), target_width, target_height).map(Self::Gif);
        }
        if bytes[0..8] == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] {
            return ApngSession::open(bytes.to_vec(), target_width, target_height).map(Self::Apng);
        }
        if &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            return WebpSession::open(bytes.to_vec(), target_width, target_height).map(Self::Webp);
        }
        Err(DecodeError::UnsupportedFormat)
    }

    pub fn metadata(&self) -> StreamMetadata {
        match self { Self::Gif(v) => v.metadata, Self::Apng(v) => v.metadata, Self::Webp(v) => v.metadata }
    }

    pub fn next_frame(&mut self) -> Result<StreamFrame, DecodeError> {
        match self { Self::Gif(v) => v.next_frame(), Self::Apng(v) => v.next_frame(), Self::Webp(v) => v.next_frame() }
    }
}

fn dimensions(source_w: u32, source_h: u32, requested_w: u32, requested_h: u32) -> (u32, u32) {
    if source_w == 0 || source_h == 0 { return (1, 1); }
    let (mut w, mut h) = if requested_w == 0 && requested_h == 0 {
        (source_w, source_h)
    } else if requested_w == 0 {
        let h = requested_h.min(source_h).max(1);
        (((source_w as u64 * h as u64) / source_h as u64).max(1) as u32, h)
    } else if requested_h == 0 {
        let w = requested_w.min(source_w).max(1);
        (w, ((source_h as u64 * w as u64) / source_w as u64).max(1) as u32)
    } else {
        let scale = (requested_w as f64 / source_w as f64).min(requested_h as f64 / source_h as f64).min(1.0);
        ((source_w as f64 * scale).round().max(1.0) as u32, (source_h as f64 * scale).round().max(1.0) as u32)
    };
    let scale = (4096.0 / w.max(h) as f64).min((8_000_000.0 / (w as f64 * h as f64)).sqrt()).min(1.0);
    if scale < 1.0 { w = (w as f64 * scale).round().max(1.0) as u32; h = (h as f64 * scale).round().max(1.0) as u32; }
    (w, h)
}

fn scaled(value: u32, source: u32, target: u32) -> u32 { ((value as u64 * target as u64) / source.max(1) as u64) as u32 }

fn resize_rgba_nearest(src: &[u8], src_w: u32, src_h: u32, dst_w: u32, dst_h: u32) -> Vec<u8> {
    let mut out = vec![0; dst_w as usize * dst_h as usize * 4];
    if src_w == 0 || src_h == 0 { return out; }
    for y in 0..dst_h { for x in 0..dst_w {
        let sx = ((x as u64 * src_w as u64) / dst_w as u64) as u32;
        let sy = ((y as u64 * src_h as u64) / dst_h as u64) as u32;
        let si = ((sy * src_w + sx) * 4) as usize; let di = ((y * dst_w + x) * 4) as usize;
        if si + 3 < src.len() { out[di..di + 4].copy_from_slice(&src[si..si + 4]); }
    }}
    out
}

fn clear_region(canvas: &mut [u8], cw: u32, ch: u32, x: u32, y: u32, w: u32, h: u32) {
    for fy in 0..h { for fx in 0..w { let dx = x + fx; let dy = y + fy;
        if dx >= cw || dy >= ch { continue; } let i = ((dy * cw + dx) * 4) as usize; canvas[i..i + 4].fill(0);
    }}
}

fn composite_gif(canvas: &mut [u8], cw: u32, ch: u32, x: u32, y: u32, w: u32, h: u32, frame: &[u8]) {
    for fy in 0..h { for fx in 0..w { let dx = x + fx; let dy = y + fy;
        let si = ((fy * w + fx) * 4) as usize; let di = ((dy * cw + dx) * 4) as usize;
        if dx >= cw || dy >= ch || si + 3 >= frame.len() || di + 3 >= canvas.len() { continue; }
        if frame[si + 3] != 0 { canvas[di..di + 4].copy_from_slice(&frame[si..si + 4]); }
    }}
}

pub struct GifSession {
    bytes: Vec<u8>, decoder: gif::Decoder<Cursor<Vec<u8>>>, canvas: Vec<u8>,
    source_width: u32, source_height: u32, pub metadata: StreamMetadata,
    frame_buffer: Vec<u8>, frame_index: u32,
}

impl GifSession {
    fn make_decoder(bytes: Vec<u8>) -> Result<gif::Decoder<Cursor<Vec<u8>>>, DecodeError> {
        let mut opts = DecodeOptions::new(); opts.set_color_output(ColorOutput::RGBA);
        opts.read_info(Cursor::new(bytes)).map_err(|e| DecodeError::Gif(format!("read_info failed: {}", e)))
    }
    fn open(bytes: Vec<u8>, requested_w: u32, requested_h: u32) -> Result<Self, DecodeError> {
        let decoder = Self::make_decoder(bytes.clone())?; let sw = decoder.width() as u32; let sh = decoder.height() as u32;
        if sw == 0 || sh == 0 { return Err(DecodeError::Gif("invalid dimensions".into())); }
        let (w, h) = dimensions(sw, sh, requested_w, requested_h);
        Ok(Self { bytes: bytes.clone(), decoder, canvas: vec![0; w as usize * h as usize * 4], source_width: sw, source_height: sh,
            metadata: StreamMetadata { width: w, height: h, frame_count: count_gif_frames(&bytes).unwrap_or(1), loop_count: 0 }, frame_buffer: Vec::new(), frame_index: 0 })
    }
    fn reset(&mut self) -> Result<(), DecodeError> { self.decoder = Self::make_decoder(self.bytes.clone())?; self.canvas.fill(0); self.frame_index = 0; Ok(()) }
    fn next_frame(&mut self) -> Result<StreamFrame, DecodeError> {
        let next = self.decoder.read_next_frame().map_err(|e| DecodeError::Gif(format!("read_next_frame failed: {}", e)))?;
        let (dispose, delay, x, y, fw, fh) = match next {
            Some(f) => { let v = (f.dispose, (f.delay as u32 * 10).max(100), f.left as u32, f.top as u32, f.width as u32, f.height as u32); self.frame_buffer.clear(); self.frame_buffer.extend_from_slice(&f.buffer); v }
            None => { self.reset()?; return self.next_frame(); }
        };
        let previous = if matches!(dispose, DisposalMethod::Previous) { Some(self.canvas.clone()) } else { None };
        let w = scaled(fw, self.source_width, self.metadata.width).max(1); let h = scaled(fh, self.source_height, self.metadata.height).max(1);
        let x = scaled(x, self.source_width, self.metadata.width).min(self.metadata.width.saturating_sub(1));
        let y = scaled(y, self.source_height, self.metadata.height).min(self.metadata.height.saturating_sub(1));
        let resized = resize_rgba_nearest(&self.frame_buffer, fw, fh, w, h);
        composite_gif(&mut self.canvas, self.metadata.width, self.metadata.height, x, y, w, h, &resized);
        let rgba = self.canvas.clone();
        match dispose { DisposalMethod::Background => clear_region(&mut self.canvas, self.metadata.width, self.metadata.height, x, y, w, h), DisposalMethod::Previous => self.canvas = previous.unwrap_or_else(|| vec![0; self.canvas.len()]), DisposalMethod::Any | DisposalMethod::Keep => {} }
        self.frame_index += 1; Ok(StreamFrame { rgba, width: self.metadata.width, height: self.metadata.height, delay_ms: delay })
    }
}

fn count_gif_frames(bytes: &[u8]) -> Option<u32> {
    if bytes.len() < 14 { return None; } let mut i = 13usize; let packed = bytes[10];
    if packed & 0x80 != 0 { i = i.checked_add(3 * (2usize << (packed & 7)))?; } let mut n = 0u32;
    while i < bytes.len() { match bytes[i] { 0x3b => break, 0x21 => { i += 2; while i < bytes.len() && bytes[i] != 0 { i = i.checked_add(bytes[i] as usize + 1)?; } i += 1; }, 0x2c => { n += 1; i += 9; if i >= bytes.len() { break; } let p = bytes[i]; i += 1; if p & 0x80 != 0 { i = i.checked_add(3 * (2usize << (p & 7)))?; } if i >= bytes.len() { break; } i += 1; while i < bytes.len() && bytes[i] != 0 { i = i.checked_add(bytes[i] as usize + 1)?; } i += 1; }, _ => return (n > 0).then_some(n) } }
    (n > 0).then_some(n)
}

pub struct ApngSession {
    bytes: Vec<u8>, reader: png::Reader<Cursor<Vec<u8>>>, canvas: Vec<u8>, source_width: u32, source_height: u32,
    source_frames: u32, pub metadata: StreamMetadata, frame_buf: Vec<u8>, frame_index: u32,
}

impl ApngSession {
    fn make_reader(bytes: Vec<u8>) -> Result<png::Reader<Cursor<Vec<u8>>>, DecodeError> {
        let mut d = png::Decoder::new(Cursor::new(bytes)); d.set_ignore_text_chunk(true); d.set_transformations(Transformations::EXPAND | Transformations::STRIP_16 | Transformations::ALPHA);
        d.read_info().map_err(|e| DecodeError::Png(format!("read_info: {}", e)))
    }
    fn open(bytes: Vec<u8>, requested_w: u32, requested_h: u32) -> Result<Self, DecodeError> {
        let reader = Self::make_reader(bytes.clone())?;
        let (sw, sh, source_frames, loop_count) = {
            let info = reader.info();
            let a = info.animation_control().ok_or(DecodeError::UnsupportedFormat)?;
            (info.width, info.height, a.num_frames, a.num_plays)
        };
        if sw == 0 || sh == 0 { return Err(DecodeError::Png("invalid dimensions".into())); }
        let (w, h) = dimensions(sw, sh, requested_w, requested_h); let buf = vec![0; reader.output_buffer_size().ok_or_else(|| DecodeError::Png("output_buffer_size unknown".into()))?];
        Ok(Self { bytes, reader, canvas: vec![0; w as usize * h as usize * 4], source_width: sw, source_height: sh, source_frames,
            metadata: StreamMetadata { width: w, height: h, frame_count: source_frames, loop_count }, frame_buf: buf, frame_index: 0 })
    }
    fn reset(&mut self) -> Result<(), DecodeError> { self.reader = Self::make_reader(self.bytes.clone())?; self.canvas.fill(0); self.frame_index = 0; Ok(()) }
    fn next_frame(&mut self) -> Result<StreamFrame, DecodeError> {
        if self.frame_index >= self.source_frames { self.reset()?; }
        let oi = self.reader.next_frame(&mut self.frame_buf).map_err(|e| DecodeError::Png(format!("next_frame: {}", e)))?;
        let (x, y, delay, dispose, blend) = { let f = self.reader.info().frame_control().ok_or_else(|| DecodeError::Png("missing fcTL".into()))?; let den = if f.delay_den == 0 { 100 } else { f.delay_den as u32 }; (f.x_offset, f.y_offset, ((f.delay_num as u32 * 1000) / den).max(100), f.dispose_op, f.blend_op) };
        let src = pixels_to_rgba(&self.frame_buf[..oi.buffer_size()], oi.color_type, oi.width, oi.height);
        let w = scaled(oi.width, self.source_width, self.metadata.width).max(1); let h = scaled(oi.height, self.source_height, self.metadata.height).max(1);
        let x = scaled(x, self.source_width, self.metadata.width); let y = scaled(y, self.source_height, self.metadata.height); let resized = resize_rgba_nearest(&src, oi.width, oi.height, w, h);
        let previous = if matches!(dispose, DisposeOp::Previous) { Some(self.canvas.clone()) } else { None };
        composite_apng(&mut self.canvas, self.metadata.width, self.metadata.height, x, y, w, h, &resized, blend); let rgba = self.canvas.clone();
        match dispose { DisposeOp::Background => clear_region(&mut self.canvas, self.metadata.width, self.metadata.height, x, y, w, h), DisposeOp::Previous => self.canvas = previous.unwrap_or_else(|| vec![0; self.canvas.len()]), DisposeOp::None => {} }
        self.frame_index += 1; Ok(StreamFrame { rgba, width: self.metadata.width, height: self.metadata.height, delay_ms: delay })
    }
}

fn pixels_to_rgba(buf: &[u8], color: ColorType, width: u32, height: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(width as usize * height as usize * 4); match color {
        ColorType::Rgba => out.extend_from_slice(buf), ColorType::Rgb => for c in buf.chunks_exact(3) { out.extend_from_slice(&[c[0], c[1], c[2], 255]); },
        ColorType::GrayscaleAlpha => for c in buf.chunks_exact(2) { out.extend_from_slice(&[c[0], c[0], c[0], c[1]]); },
        ColorType::Grayscale | ColorType::Indexed => for &v in buf { out.extend_from_slice(&[v, v, v, 255]); },
    } out
}

fn composite_apng(canvas: &mut [u8], cw: u32, ch: u32, x: u32, y: u32, w: u32, h: u32, frame: &[u8], blend: BlendOp) {
    for fy in 0..h { for fx in 0..w { let dx = x + fx; let dy = y + fy; let si = ((fy * w + fx) * 4) as usize; let di = ((dy * cw + dx) * 4) as usize;
        if dx >= cw || dy >= ch || si + 3 >= frame.len() || di + 3 >= canvas.len() { continue; } if matches!(blend, BlendOp::Source) { canvas[di..di+4].copy_from_slice(&frame[si..si+4]); continue; }
        let sa = frame[si+3] as u16; if sa == 255 { canvas[di..di+4].copy_from_slice(&frame[si..si+4]); } else if sa != 0 { let inv = 255 - sa; let da = canvas[di+3] as u16; for c in 0..3 { canvas[di+c] = ((frame[si+c] as u16 * sa + canvas[di+c] as u16 * inv) / 255) as u8; } canvas[di+3] = (sa + da * inv / 255).min(255) as u8; }
    }}
}

pub struct WebpSession {
    bytes: Vec<u8>, decoder: WebPDecoder<Cursor<Vec<u8>>>, source_width: u32, source_height: u32, frame_count: u32, has_alpha: bool,
    pub metadata: StreamMetadata, frame_buf: Vec<u8>, frame_index: u32,
}

impl WebpSession {
    fn make_decoder(bytes: Vec<u8>) -> Result<WebPDecoder<Cursor<Vec<u8>>>, DecodeError> { WebPDecoder::new(Cursor::new(bytes)).map_err(|e| DecodeError::Webp(format!("WebPDecoder::new: {}", e))) }
    fn open(bytes: Vec<u8>, requested_w: u32, requested_h: u32) -> Result<Self, DecodeError> {
        let mut decoder = Self::make_decoder(bytes.clone())?; let (sw, sh) = decoder.dimensions(); let count = decoder.num_frames(); if sw == 0 || sh == 0 || count <= 1 { return Err(DecodeError::UnsupportedFormat); }
        decoder.set_background_color([0, 0, 0, 0]).ok(); let loops = match decoder.loop_count() { image_webp::LoopCount::Forever => 0, image_webp::LoopCount::Times(n) => n.get() as u32 }; let (w, h) = dimensions(sw, sh, requested_w, requested_h);
        let size = decoder.output_buffer_size().ok_or_else(|| DecodeError::Webp("output_buffer_size overflow".into()))?; let alpha = decoder.has_alpha();
        Ok(Self { bytes, decoder, source_width: sw, source_height: sh, frame_count: count as u32, has_alpha: alpha, metadata: StreamMetadata { width: w, height: h, frame_count: count as u32, loop_count: loops }, frame_buf: vec![0; size], frame_index: 0 })
    }
    fn reset(&mut self) -> Result<(), DecodeError> { self.decoder = Self::make_decoder(self.bytes.clone())?; self.decoder.set_background_color([0, 0, 0, 0]).ok(); self.frame_index = 0; Ok(()) }
    fn next_frame(&mut self) -> Result<StreamFrame, DecodeError> {
        if self.frame_index >= self.frame_count { self.reset()?; }
        let read = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| self.decoder.read_frame(&mut self.frame_buf)));
        let delay = match read { Ok(Ok(v)) => (v as u32).max(100), Ok(Err(e)) => return Err(DecodeError::Webp(format!("read_frame: {}", e))), Err(_) => return Err(DecodeError::Webp("read_frame panicked".into())) };
        let src = if self.has_alpha { self.frame_buf.clone() } else { rgb_to_rgba(&self.frame_buf, self.source_width * self.source_height * 4) }; let rgba = resize_rgba_nearest(&src, self.source_width, self.source_height, self.metadata.width, self.metadata.height);
        self.frame_index += 1; Ok(StreamFrame { rgba, width: self.metadata.width, height: self.metadata.height, delay_ms: delay })
    }
}

fn rgb_to_rgba(rgb: &[u8], size: u32) -> Vec<u8> { let mut out = vec![0; size as usize]; for (s, d) in rgb.chunks_exact(3).zip(out.chunks_exact_mut(4)) { d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255; } out }

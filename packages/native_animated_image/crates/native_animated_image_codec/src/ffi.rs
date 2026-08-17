//! C FFI 接口 — dart:ffi 端通过这些函数与 Rust 解码器通信。
//!
//! 错误码约定:
//!   0  = success
//!  -1  = invalid input (null pointer / empty bytes / too short)
//!  -2  = unsupported format (magic bytes not recognized)
//!  -3  = decode error (decoder threw error)
//!  -4  = handle not found
//!  -5  = frame index out of range
//!  -6  = decoder panicked (已被 catch_unwind 捕获,畸形输入触发底层 crate 的 panic)

use crate::{decode_bytes, register, release, with_image, DecodeError};
use crate::streaming::StreamingDecoder;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::ffi::{c_char, CString};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;

const ERR_OK: i32 = 0;
const ERR_INVALID: i32 = -1;
const ERR_UNSUPPORTED: i32 = -2;
const ERR_DECODE: i32 = -3;
const ERR_HANDLE_NOT_FOUND: i32 = -4;
const ERR_FRAME_OOR: i32 = -5;
/// 解码器内部 panic(被 catch_unwind 捕获)。image-webp 等 forbid(unsafe) 的 crate
/// 在 canvas/帧尺寸不一致等畸形动画输入上会 assert_eq! panic 而非返回 Err。
const ERR_PANIC: i32 = -6;

#[repr(C)]
pub struct NativeAnimatedImageStreamMetadata {
    pub width: u32,
    pub height: u32,
    pub frame_count: u32,
    pub loop_count: u32,
}

struct StreamSession {
    decoder: Mutex<StreamingDecoder>,
    last_frame: Vec<u8>,
}

fn stream_registry() -> &'static Mutex<HashMap<u64, Arc<Mutex<StreamSession>>>> {
    static REG: std::sync::OnceLock<Mutex<HashMap<u64, Arc<Mutex<StreamSession>>>>> = std::sync::OnceLock::new();
    REG.get_or_init(|| Mutex::new(HashMap::new()))
}

fn next_stream_handle() -> u64 {
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// Open a sequential decoder. The compressed input is owned by the native
/// session; only the requested-size compositing canvas is retained.
#[no_mangle]
pub unsafe extern "C" fn native_animated_image_stream_open(
    bytes: *const u8,
    len: usize,
    target_width: u32,
    target_height: u32,
    out_handle: *mut u64,
    out_metadata: *mut NativeAnimatedImageStreamMetadata,
) -> i32 {
    if bytes.is_null() || out_handle.is_null() || out_metadata.is_null() || len == 0 { return ERR_INVALID; }
    let input = std::slice::from_raw_parts(bytes, len);
    let decoder = match std::panic::catch_unwind(|| StreamingDecoder::open(input, target_width, target_height)) {
        Ok(Ok(v)) => v,
        Ok(Err(DecodeError::InvalidInput)) => return ERR_INVALID,
        Ok(Err(DecodeError::UnsupportedFormat)) => return ERR_UNSUPPORTED,
        Ok(Err(_)) => return ERR_DECODE,
        Err(_) => return ERR_PANIC,
    };
    let meta = decoder.metadata();
    let handle = next_stream_handle();
    let session = Arc::new(Mutex::new(StreamSession { decoder: Mutex::new(decoder), last_frame: Vec::new() }));
    stream_registry().lock().insert(handle, session);
    *out_handle = handle;
    (*out_metadata).width = meta.width;
    (*out_metadata).height = meta.height;
    (*out_metadata).frame_count = meta.frame_count;
    (*out_metadata).loop_count = meta.loop_count;
    ERR_OK
}

/// Decode the next frame. The returned pointer is owned by the session and is
/// invalidated by the next call or close; callers must copy it before either.
#[no_mangle]
pub unsafe extern "C" fn native_animated_image_stream_next_frame(
    handle: u64,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
    out_width: *mut u32,
    out_height: *mut u32,
    out_delay_ms: *mut u32,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() || out_width.is_null() || out_height.is_null() || out_delay_ms.is_null() { return ERR_INVALID; }
    let session = match stream_registry().lock().get(&handle).cloned() { Some(v) => v, None => return ERR_HANDLE_NOT_FOUND };
    let mut guard = session.lock();
    let frame = match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| guard.decoder.lock().next_frame())) {
        Ok(Ok(v)) => v,
        Ok(Err(_)) => return ERR_DECODE,
        Err(_) => return ERR_PANIC,
    };
    guard.last_frame = frame.rgba;
    *out_ptr = guard.last_frame.as_ptr();
    *out_len = guard.last_frame.len();
    *out_width = frame.width;
    *out_height = frame.height;
    *out_delay_ms = frame.delay_ms;
    ERR_OK
}

/// Close is idempotent. Removing the registry entry first makes a concurrent
/// nextFrame unable to start, while an already-running call keeps its Arc alive
/// until it has finished using the decoder.
#[no_mangle]
pub extern "C" fn native_animated_image_stream_close(handle: u64) {
    stream_registry().lock().remove(&handle);
}

#[cfg(test)]
mod streaming_tests {
    use super::*;

    const TINY_GIF: &[u8] = &[0x47,0x49,0x46,0x38,0x39,0x61,0x01,0x00,0x01,0x00,0x80,0x00,0x00,0x00,0x00,0x00,0xff,0xff,0xff,0x21,0xf9,0x04,0x00,0x00,0x00,0x00,0x00,0x2c,0x00,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x02,0x02,0x4c,0x01,0x00,0x3b];

    #[test]
    fn stream_open_next_close_is_idempotent() {
        let mut handle = 0; let mut meta = NativeAnimatedImageStreamMetadata { width: 0, height: 0, frame_count: 0, loop_count: 0 };
        assert_eq!(unsafe { native_animated_image_stream_open(TINY_GIF.as_ptr(), TINY_GIF.len(), 8, 8, &mut handle, &mut meta) }, 0);
        assert_eq!((meta.width, meta.height), (1, 1));
        let mut ptr = std::ptr::null(); let mut len = 0; let mut w = 0; let mut h = 0; let mut delay = 0;
        assert_eq!(unsafe { native_animated_image_stream_next_frame(handle, &mut ptr, &mut len, &mut w, &mut h, &mut delay) }, 0);
        assert_eq!(len, 4); assert_eq!(delay, 100);
        native_animated_image_stream_close(handle); native_animated_image_stream_close(handle);
        assert_eq!(unsafe { native_animated_image_stream_next_frame(handle, &mut ptr, &mut len, &mut w, &mut h, &mut delay) }, ERR_HANDLE_NOT_FOUND);
    }
}

/// 解码动图字节流,成功时返回 handle(写入 *out_handle),失败返回错误码
///
/// # Safety
/// - `bytes` 必须指向至少 `len` 字节的有效内存
/// - `out_handle` 必须是有效的 *mut u64
///
/// dart 端调用方:
///   final outHandle = calloc<Uint64>();
///   final rc = lib.native_animated_image_decode(bytesPtr, len, outHandle);
///   final handle = outHandle.value;
///   calloc.free(outHandle);
#[no_mangle]
pub unsafe extern "C" fn native_animated_image_decode(
    bytes: *const u8,
    len: usize,
    out_handle: *mut u64,
) -> i32 {
    if bytes.is_null() || out_handle.is_null() || len == 0 {
        return ERR_INVALID;
    }

    let slice = std::slice::from_raw_parts(bytes, len);

    // 解码器吃任意网络输入,某些畸形/非标准图片会让底层 crate(image-webp 等
    // forbid(unsafe) 的 crate,越界即 panic)在解码过程中 panic。catch_unwind 把
    // panic 收敛成错误码,绝不让它逃逸出 extern "C" 边界 —— 否则(Rust 1.81+)会
    // abort 整个进程,把 app 一起带走。必须配合 Cargo.toml `panic = "unwind"`。
    // (闭包仅捕获 &[u8],本身就是 UnwindSafe,无需 AssertUnwindSafe。)
    let decoded = match std::panic::catch_unwind(|| decode_bytes(slice)) {
        Ok(r) => r,
        Err(_) => return ERR_PANIC,
    };

    match decoded {
        Ok(image) => {
            let handle = register(image);
            *out_handle = handle;
            ERR_OK
        }
        Err(DecodeError::InvalidInput) => ERR_INVALID,
        Err(DecodeError::UnsupportedFormat) => ERR_UNSUPPORTED,
        Err(DecodeError::EmptyFrames)
        | Err(DecodeError::Gif(_))
        | Err(DecodeError::Png(_))
        | Err(DecodeError::Webp(_)) => ERR_DECODE,
    }
}

/// 取 handle 对应解码结果的 metadata JSON(width/height/frame_count/frames[delay_ms])
///
/// 返回指针:成功 = 拥有所有权的 C 字符串(调用方负责 free 通过 `native_animated_image_free_string`);
/// 失败 = NULL
///
/// # Safety
/// - 返回的字符串必须用 `native_animated_image_free_string` 释放,不能用 free()
#[no_mangle]
pub extern "C" fn native_animated_image_get_metadata_json(handle: u64) -> *mut c_char {
    let json = with_image(handle, |img| {
        let meta = img.to_metadata();
        serde_json::to_string(&meta).ok()
    });

    match json {
        Some(Some(s)) => match CString::new(s) {
            Ok(cstr) => cstr.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
        _ => std::ptr::null_mut(),
    }
}

/// 取某帧的 RGBA 数据指针(零拷贝)+ 长度
///
/// 返回指针生命周期:与 handle 绑定,在 `native_animated_image_release` 之前一直有效
///
/// # Safety
/// - `out_ptr` 和 `out_len` 必须是有效指针
/// - 返回指针指向的内存归 handle 所有,**不要 free**
/// - dart 端只能 readonly 读取,持有期间不能跨过 release 调用
#[no_mangle]
pub unsafe extern "C" fn native_animated_image_get_frame_rgba(
    handle: u64,
    frame_idx: u32,
    out_ptr: *mut *const u8,
    out_len: *mut usize,
) -> i32 {
    if out_ptr.is_null() || out_len.is_null() {
        return ERR_INVALID;
    }

    // 这里有个生命周期挑战:with_image 借用是临时的,但我们要返回指向 frame.rgba 的指针给 dart
    // 解决:registry 的 Mutex 保证 image 在 handle 存在期间是 stable 的(Vec 不会 reallocate
    // 除非有人 mutate,我们的设计是 decoded 后只读),所以指针有效期 = handle 生命周期
    //
    // 用 raw pointer 从 with_image 闭包内拿出来 — 闭包返回 (ptr, len)
    let result = with_image(handle, |img| {
        img.frames
            .get(frame_idx as usize)
            .map(|f| (f.rgba.as_ptr(), f.rgba.len()))
    });

    match result {
        Some(Some((ptr, len))) => {
            *out_ptr = ptr;
            *out_len = len;
            ERR_OK
        }
        Some(None) => ERR_FRAME_OOR,
        None => ERR_HANDLE_NOT_FOUND,
    }
}

/// 释放 handle 对应的解码结果(整张图所有帧 + metadata)
///
/// 释放后,该 handle 不可再用;之前从 `get_frame_rgba` 拿到的指针也立即失效
#[no_mangle]
pub extern "C" fn native_animated_image_release(handle: u64) {
    release(handle);
}

/// 释放 `get_metadata_json` 返回的字符串
///
/// # Safety
/// - `s` 必须是 `native_animated_image_get_metadata_json` 返回的指针,或 NULL
#[no_mangle]
pub unsafe extern "C" fn native_animated_image_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let _ = CString::from_raw(s);
}

/// 返回 codec 版本字符串(语义版本)
///
/// dart 端用于运行时检测 binary 与 dart 包是否兼容
///
/// 返回静态字符串,无需释放
#[no_mangle]
pub extern "C" fn native_animated_image_version() -> *const c_char {
    static VERSION: OnceLock<CString> = OnceLock::new();
    let v = VERSION
        .get_or_init(|| CString::new(env!("CARGO_PKG_VERSION")).expect("version contains no NUL"));
    v.as_ptr()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    /// 最小 GIF89a 1x1
    const TINY_GIF: &[u8] = &[
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4c, 0x01, 0x00, 0x3b,
    ];

    #[test]
    fn ffi_full_lifecycle() {
        // 1. decode
        let mut handle: u64 = 0;
        let rc =
            unsafe { native_animated_image_decode(TINY_GIF.as_ptr(), TINY_GIF.len(), &mut handle) };
        assert_eq!(rc, ERR_OK);
        assert!(handle > 0);

        // 2. get metadata
        let meta_ptr = native_animated_image_get_metadata_json(handle);
        assert!(!meta_ptr.is_null());
        let meta_str = unsafe { CStr::from_ptr(meta_ptr) }.to_str().unwrap();
        assert!(meta_str.contains("\"width\":1"));
        assert!(meta_str.contains("\"frame_count\":1"));
        unsafe { native_animated_image_free_string(meta_ptr) };

        // 3. get frame RGBA
        let mut frame_ptr: *const u8 = std::ptr::null();
        let mut frame_len: usize = 0;
        let rc = unsafe {
            native_animated_image_get_frame_rgba(handle, 0, &mut frame_ptr, &mut frame_len)
        };
        assert_eq!(rc, ERR_OK);
        assert!(!frame_ptr.is_null());
        assert_eq!(frame_len, 4); // 1*1*4

        // 4. frame out of range
        let rc_oor = unsafe {
            native_animated_image_get_frame_rgba(handle, 99, &mut frame_ptr, &mut frame_len)
        };
        assert_eq!(rc_oor, ERR_FRAME_OOR);

        // 5. release
        native_animated_image_release(handle);

        // 6. handle gone
        let rc_gone = unsafe {
            native_animated_image_get_frame_rgba(handle, 0, &mut frame_ptr, &mut frame_len)
        };
        assert_eq!(rc_gone, ERR_HANDLE_NOT_FOUND);
    }

    #[test]
    fn ffi_decode_invalid_input() {
        let mut handle: u64 = 0;

        // null pointer
        let rc = unsafe { native_animated_image_decode(std::ptr::null(), 0, &mut handle) };
        assert_eq!(rc, ERR_INVALID);

        // empty
        let rc = unsafe { native_animated_image_decode([].as_ptr(), 0, &mut handle) };
        assert_eq!(rc, ERR_INVALID);

        // null out_handle
        let rc = unsafe {
            native_animated_image_decode(TINY_GIF.as_ptr(), TINY_GIF.len(), std::ptr::null_mut())
        };
        assert_eq!(rc, ERR_INVALID);
    }

    #[test]
    fn ffi_decode_unsupported() {
        // JPEG magic bytes — dispatcher 不识别,返 ERR_UNSUPPORTED
        let jpeg_bytes = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01";
        let mut handle: u64 = 0;
        let rc = unsafe {
            native_animated_image_decode(jpeg_bytes.as_ptr(), jpeg_bytes.len(), &mut handle)
        };
        assert_eq!(rc, ERR_UNSUPPORTED);
    }

    #[test]
    fn ffi_version() {
        let ptr = native_animated_image_version();
        assert!(!ptr.is_null());
        let v = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
        assert!(!v.is_empty());
        // 形如 "0.1.0"
        assert!(v.split('.').count() >= 2);
    }

    /// 拼一个 RIFF 子 chunk:fourcc(4) + size(LE u32) + payload(奇数长度补 1 pad 字节)
    fn riff_chunk(fourcc: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut v = Vec::with_capacity(8 + payload.len() + 1);
        v.extend_from_slice(fourcc);
        v.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        v.extend_from_slice(payload);
        if payload.len() % 2 == 1 {
            v.push(0);
        }
        v
    }

    /// 构造一个"看起来是动画"(VP8X anim flag + ANIM + 2×ANMF)但帧 bitstream 是
    /// 垃圾的 WebP。image-webp(forbid unsafe)在这类输入上要么返回 Err、要么在
    /// read_frame 内部 assert_eq! panic(正是线上 crash 来源)。
    fn build_malformed_animated_webp() -> Vec<u8> {
        let (cw, ch): (u32, u32) = (64, 64);
        let (wm1, hm1) = (cw - 1, ch - 1);

        // VP8X: flags(1) + reserved(3) + canvasW-1(3 LE) + canvasH-1(3 LE)
        let mut vp8x = Vec::new();
        vp8x.push(0x02); // bit1 = animation
        vp8x.extend_from_slice(&[0, 0, 0]);
        vp8x.extend_from_slice(&wm1.to_le_bytes()[..3]);
        vp8x.extend_from_slice(&hm1.to_le_bytes()[..3]);

        // ANIM: bg_color(4) + loop_count(2)
        let anim = [0u8, 0, 0, 0, 0, 0];

        // ANMF: x(3)+y(3)+w-1(3)+h-1(3)+duration(3)+flags(1) + frame bitstream(垃圾)
        let mut anmf = Vec::new();
        anmf.extend_from_slice(&[0, 0, 0]); // x
        anmf.extend_from_slice(&[0, 0, 0]); // y
        anmf.extend_from_slice(&wm1.to_le_bytes()[..3]);
        anmf.extend_from_slice(&hm1.to_le_bytes()[..3]);
        anmf.extend_from_slice(&[0, 0, 0]); // duration
        anmf.push(0); // flags
        anmf.extend_from_slice(&[0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22]);

        let mut body = Vec::new();
        body.extend_from_slice(&riff_chunk(b"VP8X", &vp8x));
        body.extend_from_slice(&riff_chunk(b"ANIM", &anim));
        body.extend_from_slice(&riff_chunk(b"ANMF", &anmf));
        body.extend_from_slice(&riff_chunk(b"ANMF", &anmf)); // 第 2 帧 → num_frames>1

        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&((4 + body.len()) as u32).to_le_bytes());
        out.extend_from_slice(b"WEBP");
        out.extend_from_slice(&body);
        out
    }

    /// 回归:线上 SIGABRT 来自 image-webp 解动画 WebP 时
    /// `assert_eq! left: Some(409600), right: Some(307200)` 的 panic 逃逸 extern "C"
    /// 边界。native_animated_image_decode 的 catch_unwind 必须把任何解码 panic /
    /// 错误收敛成负错误码,绝不 abort 进程。
    ///
    /// 注:本测试在 dev profile(panic=unwind)下跑 —— 若兜底被移除,panic 会逃逸到
    /// 测试函数被标红;兜底在则返回 rc<0。release 的 `panic=unwind` 由 Cargo.toml
    /// 保证(见该文件注释),二者缺一不可。
    #[test]
    fn ffi_decode_malformed_animated_webp_does_not_abort() {
        let webp = build_malformed_animated_webp();
        let mut handle: u64 = 0;
        let rc = unsafe { native_animated_image_decode(webp.as_ptr(), webp.len(), &mut handle) };

        // 不崩 + 返回失败码(ERR_PANIC=-6 / ERR_DECODE=-3 / ERR_UNSUPPORTED=-2 等),
        // 且不产生悬空 handle。
        assert!(
            rc < 0,
            "expected negative error code for malformed animated WebP, got {}",
            rc
        );
        assert_eq!(handle, 0, "no handle should be produced on failure");
    }
}

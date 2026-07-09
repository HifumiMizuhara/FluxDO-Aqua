import 'package:flutter/widgets.dart';

/// 图片首绘分帧闸门:限制每帧允许"首次上屏"的新图张数。
///
/// 解码完成的位图在首次被绘制的那一帧才上传 GPU 纹理(Impeller:
/// DecompressTexture / UploadTextureToPrivate)。图密话题快速滚动时
/// 常有多张图同帧首绘,纹理上传叠加把 raster 单帧顶到 60~105ms,
/// 后续 build 好的帧全部在管线里排队 —— 诊断时间轴上"raster 大帧 +
/// 队列等待连坐 8~13 帧"掉帧簇的来源。闸门把集中上传摊成每帧
/// [_perFrameQuota] 张;被推迟的图晚几帧显示(排队深度常态个位数),
/// 不可感知。
///
/// 记账周期是"post-frame → 下一个 post-frame"(覆盖下一帧的整个
/// build):帧末重置配额并按 FIFO 唤醒等量 waiter,被唤醒者计入新
/// 周期配额,与下一帧的新申请者共享同一记账,不会超发。
class ImagePaintGate {
  ImagePaintGate._();

  /// 每帧放行张数。中等尺寸图片单张上传 ~10ms 级,1 张/帧在 120Hz
  /// 下最多轻微超预算,不再出现多图同帧上百 ms 的尖峰。
  static const int _perFrameQuota = 1;

  static int _admitted = 0;
  static bool _flushScheduled = false;
  static final List<VoidCallback> _waiters = [];

  /// 申请本帧首绘名额。true = 获准,本帧直接显示;false = 已入队,
  /// 轮到时回调 [onAdmitted](调用方 setState 放行),期间继续占位。
  /// 同一张图重复申请由调用方防重(见 LazyImage 的 _gateWaiter)。
  static bool admit(VoidCallback onAdmitted) {
    _ensureFlushHook();
    if (_admitted < _perFrameQuota) {
      _admitted++;
      return true;
    }
    _waiters.add(onAdmitted);
    return false;
  }

  /// 出队(widget dispose / 换图时调用,防止回调打到死 State)
  static void cancel(VoidCallback onAdmitted) {
    for (var i = 0; i < _waiters.length; i++) {
      if (identical(_waiters[i], onAdmitted)) {
        _waiters.removeAt(i);
        return;
      }
    }
  }

  static void _ensureFlushHook() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      _admitted = 0;
      final n = _waiters.length < _perFrameQuota
          ? _waiters.length
          : _perFrameQuota;
      if (n > 0) {
        final batch = _waiters.sublist(0, n);
        _waiters.removeRange(0, n);
        _admitted = n;
        for (final callback in batch) {
          callback();
        }
        // 后续帧由被唤醒者的 setState 驱动;若其恰好已失活(cancel
        // 理应保证不会),兜底请求一帧,防止剩余队列冻结
        if (_waiters.isNotEmpty) {
          WidgetsBinding.instance.scheduleFrame();
        }
      }
      // 队列未清空、或本周期有配额占用(需要下个帧末清零)则续挂
      if (_waiters.isNotEmpty || _admitted > 0) {
        _ensureFlushHook();
      }
    });
  }
}

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart' as vms;
import 'package:vm_service/vm_service_io.dart' as vms_io;

import 'frame_jank_monitor.dart';

/// 掉帧现场自动抓取:app 内连接自身 VM Service,掉帧后拉取该帧时间窗
/// 的 timeline 事件,归并出耗时构成(阶段 + widget 级,依赖
/// debugProfileBuildsEnabled),写回 [FrameJankMonitor] 的记录。
///
/// 这替代了"连 DevTools 录 timeline → 导出 → 电脑上解析"的链路:
/// 掉帧现场自动带解剖结果,诊断页/导出报告直接可读。
///
/// 仅 debug/profile 有效(release 无 VM Service);抓取在掉帧之后异步
/// 进行且有节流(默认 2s 一次),不在渲染关键路径上。
class JankProfiler {
  JankProfiler._();

  static vms.VmService? _service;
  static bool _initTried = false;
  static DateTime _lastCapture = DateTime.fromMillisecondsSinceEpoch(0);

  /// STALL 抓取的独立节流:与帧抓取共享节流时,STALL 前总有 jank 帧
  /// 先占掉窗口,STALL-PROF 实际从未触发(生产验证)——分开计
  static DateTime _lastStallCapture = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前状态(诊断页/导出报告展示):ready / 各种失败原因
  static String status = '未初始化';

  /// 抓取节流间隔:掉帧常成串出现,一个窗口抓一次代表帧即可
  static const _throttle = Duration(seconds: 2);

  /// 单次抓取的时间窗上限(µs):防止把整段转场全拉下来
  static const _maxWindowUs = 200 * 1000;

  static Future<void> ensureInitialized() async {
    if (_initTried) return;
    _initTried = true;
    if (kReleaseMode) {
      status = 'release 构建无 VM Service';
      return;
    }
    try {
      final info = await developer.Service.getInfo();
      final httpUri = info.serverUri;
      if (httpUri == null) {
        status = 'VM Service 未开启';
        FrameJankMonitor.logEvent('PROF', status);
        return;
      }
      final wsUri = httpUri.replace(
        scheme: 'ws',
        path: '${httpUri.path}${httpUri.path.endsWith('/') ? '' : '/'}ws',
      );
      final service = await vms_io.vmServiceConnectUri(wsUri.toString());
      final vm = await service.getVM();
      if (vm.isolates?.isEmpty ?? true) {
        status = '未找到 isolate';
        FrameJankMonitor.logEvent('PROF', status);
        return;
      }
      // Dart stream:framework 的 BUILD/LAYOUT 与 debugProfileBuilds 的
      // widget 事件;Embedder stream:engine/raster 侧事件(纹理上传、
      // Rasterizer::Draw 等),raster 型大帧靠它解剖
      await service.setVMTimelineFlags(['Dart', 'Embedder']);
      _service = service;
      status = 'ready';
      FrameJankMonitor.logEvent('PROF', 'ready ($wsUri)');
    } catch (e) {
      // flutter run / IDE 附加时,getInfo 返回的是电脑侧 DDS 地址,
      // 设备上直连必然被拒 —— 这种场景下用 DevTools 即可;现场抓取
      // 面向"独立启动 profile 包日常使用"(此时可直连设备本机 VM Service)
      if ('$e'.contains('Connection refused')) {
        status = 'IDE 附加运行时不可用(独立启动应用后可用)';
      } else {
        status = '初始化失败: $e';
      }
      FrameJankMonitor.logEvent('PROF', status);
    }
  }

  /// [FrameJankMonitor] 在掉帧时调用:异步抓取该帧时间窗的 timeline
  /// 并把归并结果写回 [record]。
  static void captureForFrame(FrameTiming timing, JankRecord record) {
    final service = _service;
    if (service == null) {
      // 断线后由此触发重连,当前帧放弃、后续掉帧恢复抓取
      unawaited(ensureInitialized());
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastCapture) < _throttle) return;
    _lastCapture = now;

    final startUs =
        timing.timestampInMicroseconds(FramePhase.vsyncStart);
    final endUs =
        timing.timestampInMicroseconds(FramePhase.rasterFinishWallTime);
    final extent = (endUs - startUs).clamp(1000, _maxWindowUs);

    unawaited(() async {
      try {
        final timeline = await service.getVMTimeline(
          timeOriginMicros: startUs,
          timeExtentMicros: extent,
        );
        final summary = _summarize(timeline.traceEvents ?? []);
        if (summary.isNotEmpty) {
          record.detail = summary;
          FrameJankMonitor.revision.value++;
          debugPrint('[JANK-PROF] #${record.frameNumber} $summary');
        } else {
          record.detail = '(时间窗内无 timeline 事件)';
          FrameJankMonitor.revision.value++;
        }
      } catch (e) {
        status = '抓取失败: $e';
        FrameJankMonitor.logEvent('PROF', status);
        // 连接断开(后台挂起 / hot restart 等):重置,下次掉帧自动重连
        if ('$e'.contains('disposed') || '$e'.contains('closed')) {
          _service = null;
          _initTried = false;
        }
      }
    }());
  }

  /// STALL(UI 事件循环单任务阻塞)现场抓取:jank 抓取按帧时间窗,
  /// STALL 常发生在帧间隙、或伴随帧被 2s 节流吃掉,这里按"刚过去的
  /// [windowMs]"独立抓一窗,汇总写回诊断时间轴 —— 回答"那 ~100ms
  /// 的单任务是谁"(配合业务侧的 Timeline 标记:ParseShortPost /
  /// ParseLongChunk / MsgBusDecode 等)。与帧抓取共享节流。
  static void captureStallWindow(int windowMs) {
    final service = _service;
    if (service == null) {
      unawaited(ensureInitialized());
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastStallCapture) < _throttle) return;
    _lastStallCapture = now;

    final nowUs = developer.Timeline.now;
    final extent = (windowMs * 1000).clamp(1000, _maxWindowUs);
    unawaited(() async {
      try {
        final timeline = await service.getVMTimeline(
          timeOriginMicros: nowUs - extent,
          timeExtentMicros: extent,
        );
        final summary = _summarize(timeline.traceEvents ?? []);
        if (summary.isNotEmpty) {
          FrameJankMonitor.logEvent('STALL-PROF', summary);
        }
      } catch (_) {
        // 抓取失败不影响 STALL 事件本身;下次掉帧路径会自动重连
      }
    }());
  }

  /// 纯包装层事件:总是覆盖整帧、不携带定位信息,从摘要中剔除,
  /// 把位置留给 BUILD/LAYOUT/业务 widget/纹理上传等有效条目
  static const _wrapperNames = {
    // engine/framework 帧结构
    'VsyncProcessCallback',
    'VsyncFireCallback',
    'Animator::BeginFrame',
    'Animator::Render',
    'GPURasterizer::Draw',
    'Rasterizer::DoDraw',
    'Rasterizer::DrawToSurfaces',
    'SurfaceFrame::Submit',
    'SurfaceFrame::Encode',
    'SurfaceFrame::BuildDisplayList',
    'CompositorContext::ScopedFrame::Raster',
    'LAYOUT (root)',
    'PAINT (root)',
    'SEMANTICS (root)',
    'UPDATING COMPOSITING BITS (root)',
    'UPDATING COMPOSITING BITS',
    'FINALIZE TREE',
    'POST_FRAME',
    'Frame Request Pending',
    'PipelineItem',
    'PipelineProduce',
    'Frame',
    'Animate',
    // 通用框架 widget:出现在几乎每条链上,不带业务定位信息
    'Semantics',
    'Listener',
    'Builder',
    'KeyedSubtree',
    'IgnorePointer',
    'DefaultTextStyle',
    'AnimatedDefaultTextStyle',
    'Material',
    'RawGestureDetector',
    '_GestureSemantics',
    'GestureDetector',
    'Actions',
    '_ActionsScope',
    'Focus',
    '_FocusInheritedScope',
    'FocusScope',
    'Shortcuts',
    'MediaQuery',
    'Padding',
    'Stack',
    'Column',
    'Row',
    'Container',
    'DecoratedBox',
    'ConstrainedBox',
    'ColoredBox',
    'SizedBox',
    'Center',
    'Align',
    'ClipRect',
    'ClipRRect',
    'RepaintBoundary',
    '_InkFeatures',
    'InkWell',
    'FadeTransition',
    'SlideTransition',
    'FractionalTranslation',
    'Transform',
    'AnimatedBuilder',
    'ListenableBuilder',
    'ValueListenableBuilder<bool>',
    'ValueListenableBuilder<int>',
    'UnmanagedRestorationScope',
    'Offstage',
    'Opacity',
    'Expanded',
    'Flexible',
    'Wrap',
    'CustomPaint',
    'PhysicalModel',
    'PhysicalShape',
    'Viewport',
    'CustomScrollView',
    'SliverPadding',
    'Consumer',
    'Theme',
    '_InheritedTheme',
    'IconTheme',
    'DefaultSelectionStyle',
    'MouseRegion',
    'TickerMode',
    '_EffectiveTickerMode',
    'AbsorbPointer',
    'SafeArea',
  };

  /// 名称级噪音前缀(泛型/组合名)
  static bool _isNoise(String name) {
    if (_wrapperNames.contains(name)) return true;
    return name.startsWith('NotificationListener<') ||
        name.startsWith('_MixinApplication') ||
        name.startsWith('InheritedProvider<') ||
        name.startsWith('UncontrolledProviderScope');
  }

  /// 把 Chrome trace 格式事件归并为"名称 → 累计耗时"的 top 列表。
  ///
  /// 只统计 Duration 事件(B/E 配对与 X),按名称聚合 total(嵌套父子
  /// 都计入,阅读时天然呈现层级:BUILD 其下的 widget 次之)。剔除
  /// 纯包装层([_wrapperNames])与 <0.3ms 碎片。
  static String _summarize(List<vms.TimelineEvent> events) {
    // B/E 配对:同 tid 栈式匹配
    final stacks = <int, List<(String, int)>>{};
    final totals = <String, int>{};
    for (final e in events) {
      final json = e.json;
      if (json == null) continue;
      final ph = json['ph'] as String?;
      final name = json['name'] as String?;
      final tid = json['tid'] as int? ?? 0;
      final ts = json['ts'] as int? ?? 0;
      if (name == null) continue;
      switch (ph) {
        case 'X':
          final dur = json['dur'] as int? ?? 0;
          totals[name] = (totals[name] ?? 0) + dur;
        case 'B':
          stacks.putIfAbsent(tid, () => []).add((name, ts));
        case 'E':
          final stack = stacks[tid];
          if (stack != null && stack.isNotEmpty) {
            final (n, startTs) = stack.removeLast();
            totals[n] = (totals[n] ?? 0) + (ts - startTs);
          }
      }
    }
    final entries = totals.entries
        .where((e) => e.value >= 300 && !_isNoise(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(10)
        .map((e) => '${e.key} ${(e.value / 1000).toStringAsFixed(1)}ms')
        .join(' | ');
  }
}

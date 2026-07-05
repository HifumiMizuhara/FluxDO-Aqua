import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'jank_profiler.dart';

/// 一条掉帧记录(供诊断页展示与导出)
class JankRecord {
  JankRecord({
    required this.time,
    required this.frameNumber,
    required this.total,
    required this.buildDuration,
    required this.rasterDuration,
    required this.vsyncOverhead,
    this.cause,
  });

  final DateTime time;
  final int frameNumber;
  final Duration total;
  final Duration buildDuration;
  final Duration rasterDuration;
  final Duration vsyncOverhead;

  /// 归因标注,如 `nav+320ms push TopicDetailPage`(掉帧发生在导航后
  /// 1.5s 内 = 页面切换首建帧)。null 表示稳态(多为滚动/更新)。
  final String? cause;

  /// 现场解剖结果(JankProfiler 异步回填):该帧时间窗内 timeline
  /// 事件的耗时归并,如 `BUILD 12.1ms | PostItem 5.2ms | ...`。
  String? detail;
}

/// 一条诊断事件(NAV / MSGBUS / TYPING / SCROLL-PROBE 等)
class DiagEvent {
  const DiagEvent({required this.time, required this.tag, required this.message});

  final DateTime time;
  final String tag;
  final String message;
}

/// 帧卡顿监控:app 内自采、自看、自导出的掉帧诊断
///
/// 背景:DevTools 的 Performance 页开着时,timeline 上报与 trace buffer
/// 拉取本身会周期性阻塞 UI 线程(实测单次可达 140ms),体感判断会被
/// 观察者效应污染;且依赖 adb/logcat 的排查链路太长。本监控直接消费
/// engine 的 [FrameTiming] 回调,记录进内存环形缓冲,配合"性能诊断"
/// 页面即可在设备上直接查看与导出,无需连接电脑。
///
/// - debug/profile:main() 里无条件 [start]
/// - release:由设置开关(pref_perf_diagnostics)控制,诊断页可即时启停
/// - 掉帧行带场景归因:导航([JankNavObserver])、message bus、typing、
///   滚动回跳等事件经 [logEvent] 汇入同一时间轴
class FrameJankMonitor {
  FrameJankMonitor._();

  /// release 开关的 SharedPreferences key
  static const prefKey = 'pref_perf_diagnostics';

  /// 单帧总耗时超过该值视为掉帧(120Hz 预算 8.3ms,放宽一点过滤噪音)
  static const _jankThreshold = Duration(milliseconds: 10);

  /// Logcat 汇总输出间隔
  static const _summaryInterval = Duration(seconds: 10);

  static const _maxJankRecords = 500;
  static const _maxEvents = 300;

  static bool _started = false;
  static bool get isRunning => _started;

  /// 掉帧记录(环形,最新在末尾)
  static final List<JankRecord> jankRecords = [];

  /// 诊断事件(环形,最新在末尾)
  static final List<DiagEvent> events = [];

  /// 记录变化版本号,诊断页用它驱动刷新
  static final ValueNotifier<int> revision = ValueNotifier(0);

  // 会话累计(诊断页汇总)
  static DateTime? sessionStart;
  static int sessionFrames = 0;
  static int sessionJanks = 0;
  static Duration sessionWorstBuild = Duration.zero;
  static Duration sessionWorstRaster = Duration.zero;

  // Logcat 10s 窗口
  static int _frames = 0;
  static int _janks = 0;
  static Duration _worstBuild = Duration.zero;
  static Duration _worstRaster = Duration.zero;
  static DateTime _lastSummary = DateTime.now();

  static DateTime? _lastNav;
  static String _lastNavDesc = '';

  static void start() {
    if (_started) return;
    _started = true;
    sessionStart ??= DateTime.now();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // 掉帧现场抓取(debug/profile;release 内部自动跳过)
    unawaited(JankProfiler.ensureInitialized());
    debugPrint(
      '[JANK] monitor started, threshold ${_jankThreshold.inMilliseconds}ms',
    );
  }

  static void stop() {
    if (!_started) return;
    _started = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    debugPrint('[JANK] monitor stopped');
  }

  /// 统一事件入口:打印到 Logcat 并汇入诊断时间轴。
  /// NAV 事件同时驱动掉帧行的导航归因。监控未启用时为空操作
  /// (release 关闭态零输出零开销)。
  static void logEvent(String tag, String message) {
    if (!_started) return;
    if (tag == 'NAV') {
      _lastNav = DateTime.now();
      _lastNavDesc = message;
    }
    debugPrint('[$tag] $message');
    events.add(DiagEvent(time: DateTime.now(), tag: tag, message: message));
    if (events.length > _maxEvents) {
      events.removeRange(0, events.length - _maxEvents);
    }
    revision.value++;
  }

  /// 兼容旧调用:导航事件
  static void noteNavigation(String desc) => logEvent('NAV', desc);

  static void clear() {
    jankRecords.clear();
    events.clear();
    sessionStart = DateTime.now();
    sessionFrames = 0;
    sessionJanks = 0;
    sessionWorstBuild = Duration.zero;
    sessionWorstRaster = Duration.zero;
    revision.value++;
  }

  static String _ms(Duration d) =>
      (d.inMicroseconds / 1000).toStringAsFixed(1);

  static void _onTimings(List<FrameTiming> timings) {
    var changed = false;
    for (final t in timings) {
      _frames++;
      sessionFrames++;
      if (t.buildDuration > _worstBuild) _worstBuild = t.buildDuration;
      if (t.rasterDuration > _worstRaster) _worstRaster = t.rasterDuration;
      if (t.buildDuration > sessionWorstBuild) {
        sessionWorstBuild = t.buildDuration;
      }
      if (t.rasterDuration > sessionWorstRaster) {
        sessionWorstRaster = t.rasterDuration;
      }
      if (t.totalSpan > _jankThreshold) {
        _janks++;
        sessionJanks++;
        final nav = _lastNav;
        final sinceNav = nav == null
            ? null
            : DateTime.now().difference(nav).inMilliseconds;
        final cause = sinceNav != null && sinceNav < 1500
            ? 'nav+${sinceNav}ms $_lastNavDesc'
            : null;
        debugPrint(
          '[JANK] #${t.frameNumber} total ${_ms(t.totalSpan)}ms '
          '(build ${_ms(t.buildDuration)} / raster ${_ms(t.rasterDuration)} '
          '/ vsyncOverhead ${_ms(t.vsyncOverhead)})'
          '${cause == null ? '' : ' [$cause]'}',
        );
        final record = JankRecord(
          time: DateTime.now(),
          frameNumber: t.frameNumber,
          total: t.totalSpan,
          buildDuration: t.buildDuration,
          rasterDuration: t.rasterDuration,
          vsyncOverhead: t.vsyncOverhead,
          cause: cause,
        );
        jankRecords.add(record);
        if (jankRecords.length > _maxJankRecords) {
          jankRecords.removeRange(0, jankRecords.length - _maxJankRecords);
        }
        // 异步抓取该帧的 timeline 解剖(节流在 profiler 内部)
        JankProfiler.captureForFrame(t, record);
        changed = true;
      }
    }
    if (changed) revision.value++;

    final now = DateTime.now();
    if (now.difference(_lastSummary) >= _summaryInterval && _frames > 0) {
      final semanticsEnabled = SemanticsBinding.instance.semanticsEnabled;
      debugPrint(
        '[JANK] summary: $_janks/$_frames janky, '
        'worst build ${_ms(_worstBuild)}ms, '
        'worst raster ${_ms(_worstRaster)}ms, '
        'semantics: ${semanticsEnabled ? countSemanticsNodes() : 'off'}',
      );
      _lastSummary = now;
      _frames = 0;
      _janks = 0;
      _worstBuild = Duration.zero;
      _worstRaster = Duration.zero;
    }
  }

  /// 当前语义树节点总数(未启用语义时为 -1)。
  ///
  /// 滚动时每帧的语义几何更新成本正比于可见节点数;这个数字用来
  /// 判断语义树是否臃肿、以及合并/裁剪优化的效果。
  /// 多视图架构下语义树挂在子 PipelineOwner 上,需整树遍历。
  static int countSemanticsNodes() {
    var count = 0;
    void visitOwner(PipelineOwner owner) {
      final root = owner.semanticsOwner?.rootSemanticsNode;
      if (root != null) {
        void visit(SemanticsNode node) {
          count++;
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(root);
      }
      owner.visitChildren(visitOwner);
    }

    visitOwner(RendererBinding.instance.rootPipelineOwner);
    return count == 0 ? -1 : count;
  }

  /// 当前显示刷新率(拿不到时为 null)
  static double? displayRefreshRate() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    return views.first.display.refreshRate;
  }

  /// 生成导出文本:头部汇总 + jank/事件合并时间轴(时间正序)
  static String exportText() {
    final buf = StringBuffer();
    final start = sessionStart;
    final elapsed = start == null
        ? null
        : DateTime.now().difference(start);
    final rate = sessionFrames == 0
        ? 0.0
        : sessionJanks / sessionFrames * 100;
    final semanticsEnabled = SemanticsBinding.instance.semanticsEnabled;
    buf.writeln('FluxDO 性能诊断导出');
    buf.writeln('导出时间: ${DateTime.now()}');
    if (elapsed != null) {
      buf.writeln('会话时长: ${elapsed.inMinutes}m${elapsed.inSeconds % 60}s');
    }
    buf.writeln(
      '帧数: $sessionFrames, 掉帧: $sessionJanks (${rate.toStringAsFixed(1)}%)',
    );
    buf.writeln(
      'worst build: ${_ms(sessionWorstBuild)}ms, '
      'worst raster: ${_ms(sessionWorstRaster)}ms',
    );
    buf.writeln('刷新率: ${displayRefreshRate()?.toStringAsFixed(0) ?? '?'}Hz');
    buf.writeln(
      '语义树: ${semanticsEnabled ? '${countSemanticsNodes()} 节点' : '未启用'}',
    );
    buf.writeln('监控状态: ${_started ? '运行中' : '已停止'}');
    buf.writeln('现场抓取: ${JankProfiler.status}');
    buf.writeln('--- 时间轴(旧→新) ---');

    String fmtTime(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${t.millisecond.toString().padLeft(3, '0')}';

    final lines = <(DateTime, String)>[
      for (final e in events) (e.time, '${fmtTime(e.time)}  [${e.tag}] ${e.message}'),
      for (final j in jankRecords)
        (
          j.time,
          '${fmtTime(j.time)}  JANK #${j.frameNumber} total ${_ms(j.total)}ms '
              '(build ${_ms(j.buildDuration)} / raster ${_ms(j.rasterDuration)} '
              '/ ov ${_ms(j.vsyncOverhead)})'
              '${j.cause == null ? '' : ' [${j.cause}]'}'
              '${j.detail == null ? '' : '\n           ↳ ${j.detail}'}'
        ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final l in lines) {
      buf.writeln(l.$2);
    }
    return buf.toString();
  }
}

/// 导航事件观察者:配合 [FrameJankMonitor] 给掉帧日志做场景归因。
/// 页面切换后 1.5s 内的掉帧会带 [nav+XXXms] 标注 —— 首建/转场帧与
/// 滚动帧一眼区分,不再需要靠回忆"当时在干什么"。
class JankNavObserver extends NavigatorObserver {
  String _desc(Route<dynamic>? route) =>
      route?.settings.name ?? route.runtimeType.toString();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    FrameJankMonitor.noteNavigation('push ${_desc(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    FrameJankMonitor.noteNavigation('pop → ${_desc(previousRoute)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    FrameJankMonitor.noteNavigation('replace ${_desc(newRoute)}');
  }
}

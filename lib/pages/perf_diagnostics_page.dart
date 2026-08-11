import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/toast_service.dart';
import '../utils/frame_jank_monitor.dart';
import '../utils/jank_profiler.dart';
import '../widgets/common/perf_overlay.dart';
import '../l10n/s.dart';

/// 性能诊断页:查看/导出 [FrameJankMonitor] 采集的掉帧记录与场景事件,
/// 不依赖 adb/logcat。开发者向工具页,文案暂不接入 l10n。
class PerfDiagnosticsPage extends StatefulWidget {
  const PerfDiagnosticsPage({super.key});

  @override
  State<PerfDiagnosticsPage> createState() => _PerfDiagnosticsPageState();
}

class _PerfDiagnosticsPageState extends State<PerfDiagnosticsPage> {
  /// 上次会话快照(退后台时落盘的 perf_diag_last.txt),null = 不存在
  File? _snapshotFile;

  @override
  void initState() {
    super.initState();
    FrameJankMonitor.snapshotFile().then((f) {
      if (mounted) setState(() => _snapshotFile = f);
    });
  }

  Future<void> _toggle(bool enabled) async {
    if (enabled) {
      FrameJankMonitor.start();
    } else {
      FrameJankMonitor.stop();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(FrameJankMonitor.prefKey, enabled);
    if (mounted) setState(() {});
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: FrameJankMonitor.exportText()));
    ToastService.showSuccess(S.current.perf_reportCopied);
  }

  Future<void> _share() async {
    await SharePlus.instance.share(
      ShareParams(
        text: FrameJankMonitor.exportText(),
        subject: S.current.perf_reportSubject,
      ),
    );
  }

  void _clear() {
    FrameJankMonitor.clear();
    ToastService.showInfo(S.current.perf_recordsCleared);
  }

  Future<void> _shareSnapshot() async {
    final file = _snapshotFile;
    if (file == null) return;
    try {
      final text = await file.readAsString();
      await SharePlus.instance.share(
        ShareParams(text: text, subject: S.current.perf_snapshotSubject),
      );
    } catch (e) {
      ToastService.showError(S.current.perf_snapshotReadFailed('$e'));
    }
  }

  String _ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.perf_title),
        actions: [
          IconButton(
            tooltip: l10n.perf_copyReport,
            icon: const Icon(Symbols.content_copy_rounded),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: l10n.perf_shareReport,
            icon: const Icon(Symbols.share_rounded),
            onPressed: _share,
          ),
          IconButton(
            tooltip: l10n.perf_clearRecords,
            icon: const Icon(Symbols.delete_sweep_rounded),
            onPressed: _clear,
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: FrameJankMonitor.revision,
        builder: (context, _, _) {
          final janks = FrameJankMonitor.jankRecords;
          final events = FrameJankMonitor.events;
          // 合并时间轴,最新在前
          final entries = <(_EntryKind, DateTime, Widget)>[
            for (final j in janks)
              (_EntryKind.jank, j.time, _jankTile(theme, j)),
            for (final e in events)
              (_EntryKind.event, e.time, _eventTile(theme, e)),
          ]..sort((a, b) => b.$2.compareTo(a.$2));

          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _summaryCard(theme, l10n),
              const SizedBox(height: 12),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 48),
                  child: Center(
                    child: Text(
                      FrameJankMonitor.isRunning
                          ? l10n.perf_noJankRecords
                          : l10n.perf_monitoringDisabled,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              else
                ...entries.map((e) => e.$3),
            ],
          );
        },
      ),
    );
  }

  Widget _summaryCard(ThemeData theme, AppLocalizations l10n) {
    final frames = FrameJankMonitor.sessionFrames;
    final janks = FrameJankMonitor.sessionJanks;
    final rate = frames == 0 ? 0.0 : janks / frames * 100;
    final refresh = FrameJankMonitor.displayRefreshRate();
    final semanticsNodes = FrameJankMonitor.countSemanticsNodes();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.perf_enableMonitoring),
              subtitle: Text(
                kReleaseMode
                    ? l10n.perf_monitoringReleaseDesc
                    : l10n.perf_monitoringDebugDesc,
              ),
              value: FrameJankMonitor.isRunning,
              onChanged: _toggle,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.perf_floatingOverlay),
              subtitle: Text(l10n.perf_floatingOverlayDesc),
              value: PerfOverlay.isShowing,
              onChanged: (v) async {
                await PerfOverlay.setEnabled(v);
                if (mounted) setState(() {});
              },
            ),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Text(
              l10n.perf_sessionSummary(frames, janks, rate.toStringAsFixed(1)),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.perf_worstFrame(
                _ms(FrameJankMonitor.sessionWorstBuild),
                _ms(FrameJankMonitor.sessionWorstRaster),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.perf_refreshSemantics(
                refresh?.toStringAsFixed(0) ?? '?',
                semanticsNodes < 0
                    ? l10n.perf_semanticsDisabled
                    : l10n.perf_semanticsNodes(semanticsNodes),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.perf_captureStatus(JankProfiler.status),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_snapshotFile != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.perf_lastSnapshot(
                        _fmtSnapshotTime(_snapshotFile!.lastModifiedSync()),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.perf_shareLastSnapshot,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Symbols.share_rounded, size: 18),
                    onPressed: _shareSnapshot,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  String _fmtSnapshotTime(DateTime t) => '${t.month}/${t.day} ${_fmtTime(t)}';

  Widget _jankTile(ThemeData theme, JankRecord j) {
    final heavy = j.total.inMilliseconds >= 20;
    final color = heavy ? theme.colorScheme.error : theme.colorScheme.tertiary;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(Symbols.warning_rounded, size: 18, color: color),
      title: Text(
        S.current.perf_jankDetail(
          _ms(j.total),
          _ms(j.buildDuration),
          _ms(j.rasterDuration),
          _ms(j.vsyncOverhead),
        ),
        style: theme.textTheme.bodySmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      subtitle: (j.cause == null && j.detail == null)
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (j.cause != null)
                  Text(
                    j.cause!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontSize: 11,
                    ),
                  ),
                if (j.detail != null)
                  Text(
                    j.detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
      trailing: Text(
        _fmtTime(j.time),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _eventTile(ThemeData theme, DiagEvent e) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        Symbols.info_rounded,
        size: 18,
        color: theme.colorScheme.outline,
      ),
      title: Text(
        '[${e.tag}] ${e.message}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Text(
        _fmtTime(e.time),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    );
  }
}

enum _EntryKind { jank, event }

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/download_item.dart';
import '../pages/download_list_page.dart';
import '../services/download_service.dart';
import '../services/toast_service.dart';
import '../l10n/s.dart';
import 'theme_provider.dart'; // sharedPreferencesProvider

/// 下载记录状态管理
class DownloadNotifier extends StateNotifier<List<DownloadItem>> {
  static const String _storageKey = 'download_items';
  static const _uuid = Uuid();

  final SharedPreferences _prefs;

  /// 正在进行中的下载 CancelToken，key = item.id
  final Map<String, CancelToken> _cancelTokens = {};

  /// Dio 的下载进度回调可能按网络分片高频触发。若每次都发布 Riverpod 状态，
  /// 下载页会反复重建整份列表，进度 Toast 也会在同一帧收到多次通知。
  final Map<String, int> _lastProgressPublishMicros = {};
  static const int _progressPublishIntervalMicros = 100000;

  /// 下载尚未创建文件时也要占用路径，避免并发下载选到同一个文件名。
  final Set<String> _reservedPaths = {};

  DownloadNotifier(this._prefs) : super(_load(_prefs));

  /// 从 SharedPreferences 加载列表
  static List<DownloadItem> _load(SharedPreferences prefs) {
    final jsonStr = prefs.getString(_storageKey);
    if (jsonStr == null) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .map((e) => DownloadItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 发起下载
  Future<void> startDownload({
    required String url,
    String? suggestedFilename,
    String? mimeType,
    int? contentLength,
  }) async {
    // 快速解析初始文件名（不等待网络），立即反馈用户
    final initialFileName = DownloadService.resolveFileName(
      url,
      suggestedFilename: suggestedFilename,
    );

    // 获取下载目录，处理重名
    final dir = await _getDownloadDir();
    var savePath = _reserveUniquePath(dir.path, initialFileName);
    // 实际文件名可能带编号（如 "file (1).pdf"）
    var actualFileName = p.basename(savePath);

    final id = _uuid.v4();
    final item = DownloadItem(
      id: id,
      url: url,
      fileName: actualFileName,
      savePath: savePath,
      fileSize: contentLength ?? 0,
      createdAt: DateTime.now(),
      mimeType: mimeType,
    );

    // 插入列表头部
    state = [item, ...state];
    _save();

    // 立即显示下载进度 Toast（不等待 HEAD 请求）
    final toastHandle = ToastService.showDownload(actualFileName);

    // 没有建议文件名时，通过 HEAD 请求获取更准确的文件名（作为下载 loading 的一部分）
    if (suggestedFilename == null || suggestedFilename.isEmpty) {
      final headerName = await DownloadService.instance.fetchFileNameFromHeader(
        url,
      );
      if (headerName != null && headerName.isNotEmpty) {
        final safeHeaderName = DownloadService.sanitizeFileName(headerName);
        final betterPath = safeHeaderName == actualFileName
            ? savePath
            : _reserveUniquePath(dir.path, safeHeaderName);
        final betterActualName = p.basename(betterPath);
        if (betterActualName != actualFileName) {
          _reservedPaths.remove(savePath);
          savePath = betterPath;
          actualFileName = betterActualName;
          _updateItem(id, fileName: betterActualName, savePath: betterPath);
          toastHandle.updateFileName(betterActualName);
        }
      }
    }

    // 开始下载
    final cancelToken = CancelToken();
    _cancelTokens[id] = cancelToken;

    try {
      await DownloadService.instance.download(
        url: url,
        savePath: savePath,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          final progress = total > 0 ? received / total : -1.0;
          final now = DateTime.now().microsecondsSinceEpoch;
          final last = _lastProgressPublishMicros[id];
          if (last != null &&
              now - last < _progressPublishIntervalMicros &&
              progress < 1.0) {
            return;
          }
          _lastProgressPublishMicros[id] = now;
          toastHandle.updateProgress(progress);
          _updateItem(
            id,
            progress: total > 0 ? received / total : 0.0,
            fileSize: total > 0 ? total : null,
          );
        },
      );
      _updateItem(id, status: DownloadItemStatus.completed, progress: 1.0);
      toastHandle.dismiss();
      // 显示完成 Toast，带"查看"按钮跳转下载列表
      ToastService.show(
        S.current.myBrowser_downloadComplete,
        type: ToastType.success,
        duration: const Duration(seconds: 5),
        actionLabel: S.current.myBrowser_viewDownload,
        onAction: () => DownloadListPage.navigateTo(highlightItemId: id),
      );
    } on DioException catch (e) {
      toastHandle.dismiss();
      if (e.type == DioExceptionType.cancel) {
        debugPrint('[DownloadProvider] 下载已取消: $actualFileName');
      } else {
        debugPrint('[DownloadProvider] 下载失败: $e');
        _updateItem(id, status: DownloadItemStatus.failed);
        ToastService.showError(S.current.myBrowser_downloadFailed);
      }
    } catch (e) {
      toastHandle.dismiss();
      debugPrint('[DownloadProvider] 下载异常: $e');
      _updateItem(id, status: DownloadItemStatus.failed);
      ToastService.showError(S.current.myBrowser_downloadFailed);
    } finally {
      _cancelTokens.remove(id);
      _lastProgressPublishMicros.remove(id);
      _reservedPaths.remove(savePath);
    }
  }

  /// 重试下载
  Future<void> retry(DownloadItem item) async {
    // 删除旧记录
    await removeById(item.id);
    // 重新下载
    await startDownload(
      url: item.url,
      suggestedFilename: item.fileName,
      mimeType: item.mimeType,
    );
  }

  /// 取消下载
  void cancel(String id) {
    _cancelTokens[id]?.cancel();
    _cancelTokens.remove(id);
    _updateItem(id, status: DownloadItemStatus.failed);
  }

  /// 删除记录（同时删除本地文件）
  Future<void> removeById(String id) async {
    _cancelTokens[id]?.cancel();
    _cancelTokens.remove(id);
    final index = state.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final item = state[index];
    state = state.where((e) => e.id != id).toList();
    _save();
    await _deleteFileIfInsideDownloads(item.savePath);
  }

  /// 清除已完成的记录
  Future<void> clearCompleted() async {
    final completed = state
        .where((e) => e.status == DownloadItemStatus.completed)
        .toList(growable: false);
    if (completed.isEmpty) return;

    state = state
        .where((e) => e.status != DownloadItemStatus.completed)
        .toList();
    _save();
    for (final item in completed) {
      await _deleteFileIfInsideDownloads(item.savePath);
    }
  }

  void _updateItem(
    String id, {
    String? fileName,
    String? savePath,
    DownloadItemStatus? status,
    double? progress,
    int? fileSize,
  }) {
    state = [
      for (final item in state)
        if (item.id == id)
          item.copyWith(
            fileName: fileName,
            savePath: savePath,
            status: status,
            progress: progress,
            fileSize: fileSize,
          )
        else
          item,
    ];
    // 只在状态变更或文件名更新时持久化，避免进度更新频繁写入
    if (status != null || fileName != null) _save();
  }

  /// 持久化到 SharedPreferences
  void _save() {
    final jsonStr = jsonEncode(state.map((e) => e.toJson()).toList());
    _prefs.setString(_storageKey, jsonStr);
  }

  /// 生成不重名的文件路径：file.pdf → file (1).pdf → file (2).pdf ...
  String _reserveUniquePath(String dirPath, String fileName) {
    final path = _uniquePath(dirPath, fileName);
    _reservedPaths.add(path);
    return path;
  }

  String _uniquePath(String dirPath, String fileName) {
    final safeFileName = DownloadService.sanitizeFileName(fileName);
    var path = p.join(dirPath, safeFileName);
    if (!_pathIsTaken(path)) return path;

    final dot = safeFileName.lastIndexOf('.');
    final name = dot > 0 ? safeFileName.substring(0, dot) : safeFileName;
    final ext = dot > 0 ? safeFileName.substring(dot) : '';
    var i = 1;
    do {
      path = p.join(dirPath, '$name ($i)$ext');
      i++;
    } while (_pathIsTaken(path));
    return path;
  }

  bool _pathIsTaken(String path) =>
      _reservedPaths.contains(path) || File(path).existsSync();

  Future<void> _deleteFileIfInsideDownloads(String filePath) async {
    final downloadDir = await _getDownloadDir();
    final base = p.normalize(p.absolute(downloadDir.path));
    final target = p.normalize(p.absolute(filePath));
    final relative = p.relative(target, from: base);
    if (relative == '..' ||
        relative.startsWith('..${p.separator}') ||
        p.isAbsolute(relative)) {
      debugPrint(
        '[DownloadProvider] Skip deleting outside Downloads: $filePath',
      );
      return;
    }

    try {
      final file = File(target);
      if (file.existsSync()) await file.delete();
    } catch (_) {}
  }

  /// 获取下载目录
  /// Android → 公共 Downloads，macOS/Linux/Windows → ~/Downloads
  /// iOS → 应用 Documents（沙盒限制，但通过 Files app 可见）
  Future<Directory> _getDownloadDir() async {
    // 优先使用系统下载目录（Android 公共 Downloads / 桌面 ~/Downloads）
    final downloadsDir = await getDownloadsDirectory();
    if (downloadsDir != null) return downloadsDir;
    // 回退到应用文档目录
    final appDir = await getApplicationDocumentsDirectory();
    final fallbackDir = Directory('${appDir.path}/Downloads');
    if (!fallbackDir.existsSync()) {
      fallbackDir.createSync(recursive: true);
    }
    return fallbackDir;
  }
}

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, List<DownloadItem>>((ref) {
      final prefs = ref.watch(sharedPreferencesProvider);
      return DownloadNotifier(prefs);
    });

/// Android「用户应用工具」(ProcessText)接入 —— 系统翻译/搜索等第三方文本
/// 处理动作,追加到选区工具栏尾部。
///
/// 对齐 Flutter SDK SelectableRegion 的接法(selectable_region.dart:432-469 +
/// :1752-1774):DefaultProcessTextService.queryTextActions() 查询一次缓存,
/// 点击调 processTextAction(id, text, readOnly: true)。仅 Android 有实现
/// (services/process_text.dart,manifest 需 PROCESS_TEXT `<queries>`,主项目
/// 已具备);其他平台查询返回空列表,零成本。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SelectionProcessText {
  SelectionProcessText._();

  static final ProcessTextService _service = DefaultProcessTextService();
  static List<ProcessTextAction> _actions = const [];
  static Future<void>? _query;

  /// 当前已知的文本处理动作(未加载完成时为空列表)。
  static List<ProcessTextAction> get actions => _actions;

  /// 触发一次性查询(幂等)。返回的 Future 在动作列表就绪后完成,可用于
  /// 加载完成时刷新已显示的工具栏。
  static Future<void> ensureLoaded() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return _query ??= Future<void>.value();
    }
    return _query ??= _service
        .queryTextActions()
        .then((a) => _actions = a)
        .catchError((_) => _actions = const <ProcessTextAction>[]);
  }

  /// 执行某动作。readOnly=true(选区不可回写,对齐 SDK :1766)。
  static Future<void> run(String id, String text) =>
      _service.processTextAction(id, text, true);
}

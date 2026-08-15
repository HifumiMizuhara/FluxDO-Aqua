/// 脚注引用点击 callback —— 主项目接 popover / dialog 显示脚注正文。
///
/// - [fnId]:脚注锚点 id(`fn:abc`)
/// - [contentHtml]:脚注正文 HTML(parser 已 strip backref + 剥外层 `<p>`),
///   null 表示在 cooked 中未找到对应 `<li id="fnId">`
///
/// 不传 handler 时点击无反应(默认 [defaultFootnoteTapHandler] 仅 debugPrint)。

library;

import 'package:flutter/widgets.dart';

typedef FootnoteTapHandler =
    void Function(BuildContext context, String fnId, String? contentHtml);

void defaultFootnoteTapHandler(
  BuildContext context,
  String fnId,
  String? contentHtml,
) {
  debugPrint('footnote tap: $fnId (content: ${contentHtml ?? "null"})');
}

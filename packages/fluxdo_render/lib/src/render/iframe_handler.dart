/// 嵌入 iframe builder —— 主项目接入 webview 渲染。
///
/// 主项目场景:用 flutter_inappwebview / webview_flutter 把 src 嵌进卡片。
/// 子包不绑 webview 包(依赖重 + 跨平台插件复杂)。
///
/// 返回 `null` 时子包用内置占位卡(图标 + 域名 + "打开链接" 按钮,
/// 点击通过 [linkHandler] 跳浏览器)。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef IframeBuilder = Widget? Function(BuildContext context, IframeNode node);

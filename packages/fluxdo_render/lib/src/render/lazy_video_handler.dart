/// 懒加载视频 builder —— 主项目接入真实 iframe(webview)渲染。
///
/// 主项目场景:点击缩略图后用 webview_flutter 嵌入 youtube/vimeo embed URL,
/// 子包不绑死 webview 包(跨平台依赖重,且子包面向多场景:用户卡 bio /
/// AI 分享卡 等不应强制依赖)。
///
/// 返回 `null` 时子包用内置缩略图卡片(点击通过 [linkHandler] 跳浏览器)。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef LazyVideoBuilder =
    Widget? Function(BuildContext context, LazyVideoNode node);

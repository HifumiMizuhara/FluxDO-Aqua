/// 原生上传音频 builder —— 主项目接入真播放器(just_audio）。
///
/// 子包不绑 just_audio（平台插件 + 体积)。主项目注入音频条 widget。
///
/// 返回 `null` 时子包用内置占位卡(音乐图标 + 文件名 + 点击通过
/// [linkHandler] 跳浏览器）。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef AudioBuilder = Widget? Function(BuildContext context, AudioNode node);

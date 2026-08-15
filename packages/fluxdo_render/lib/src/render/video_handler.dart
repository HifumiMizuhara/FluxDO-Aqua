/// 原生上传视频 builder —— 主项目接入真播放器(chewie / video_player）。
///
/// 子包不绑 chewie/video_player（平台插件重，且子包面向多场景：用户卡 bio /
/// AI 分享卡 等不应强制依赖)。主项目用 legacy DiscourseVideoPlayer 注入。
///
/// 返回 `null` 时子包用内置占位卡(封面/图标 + "播放视频" + 点击通过
/// [linkHandler] 跳浏览器）。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef VideoBuilder = Widget? Function(BuildContext context, VideoNode node);

/// 聊天记录块 builder —— 主项目接 legacy buildChatTranscript。
///
/// chat-transcript 纯 DOM 驱动(不依赖 post API)。主项目拿
/// ChatTranscriptNode.rawHtml 反构造 element 喂给 legacy builder,
/// 消息内容走 htmlBuilder 递归(支持图片/mention/emoji/嵌套)。
///
/// 返回 `null` 时子包用内置 fallback 卡(左竖条 + 头像 + 用户名 +
/// 时间 + 消息纯文本)。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef ChatTranscriptBuilder =
    Widget? Function(BuildContext context, ChatTranscriptNode node);

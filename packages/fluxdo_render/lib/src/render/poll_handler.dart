/// 投票块 builder —— 主项目接入完整交互(选项 / 票数条 / 投票 + 后端 API)。
///
/// poll 数据全在 API(post.polls / post.pollsVotes),子包不持。主项目
/// 拿 PollNode.rawHtml(或 pollName)调 legacy `buildPoll(post: post)`,
/// 从 post.polls match 出真实数据并渲染。
///
/// 返回 `null` 时子包用内置 fallback 占位卡(标题 + 接入提示)。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef PollBuilder = Widget? Function(BuildContext context, PollNode node);

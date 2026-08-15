/// Discourse policy 区块 builder —— 主项目接入完整交互(按钮 + 接受用户
/// 列表 + 后端 API 调用)。
///
/// 主项目场景:
/// - 调 DiscourseService.acceptPolicy / revokePolicy 接口
/// - 显示已接受用户头像列表(SmartAvatar)
/// - 监听 TopicDetailNotifier.refreshPost 跟随状态变化
///
/// 子包不持 post 状态 / 不依赖业务 service。返回 `null` 时子包用内置
/// fallback:画 body + 静态 footer 占位(显示 acceptLabel 按钮,但无作用)。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef PolicyBuilder = Widget? Function(BuildContext context, PolicyNode node);

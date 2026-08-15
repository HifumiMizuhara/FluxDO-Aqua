/// 本地日期 chip builder —— 主项目接入完整的虚线下划线 + 时区换算 +
/// 多时区 popover。
///
/// 主项目场景:用 `timezone` / `flutter_timezone` 包做时区转换 +
/// `popover` 包做点击弹窗。子包不绑这些重依赖(纯展示场景用不上)。
///
/// 返回 `null` 时子包用内置 fallback:展示 [LocalDateRun.fallbackText]
/// (服务端预渲染文本)+ 时钟图标,无时区换算 / 无 popover。

library;

import 'package:flutter/widgets.dart';

import '../node/inline_node.dart';

typedef LocalDateBuilder =
    Widget? Function(BuildContext context, LocalDateRun node);

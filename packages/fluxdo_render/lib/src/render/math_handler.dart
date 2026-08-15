/// 块级数学公式 builder —— 主项目接入 `flutter_math_fork` 渲染。
///
/// 子包不绑 `flutter_math_fork`(依赖 ~50KB + JS 引擎 + 字体,
/// 跨场景包体压力大;user card / AI 分享卡 等场景用不上)。
///
/// 返回 `null` 时子包用内置 fallback:monospace `$latex$` 原文。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef MathBlockBuilder =
    Widget? Function(BuildContext context, MathBlockNode node);

typedef MathInlineBuilder =
    Widget? Function(BuildContext context, MathInlineRun node);

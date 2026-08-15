/// 块级文本样式常量 —— 阅读端(NodeFactory)与编辑端(EditableTextBlock)
/// **同一来源**,双端字号/间距永远一致(编辑=阅读的所见即所得铁律)。
library;

import 'package:flutter/painting.dart';

/// h1..h6 的字号倍率(索引 0 = h1;对齐浏览器默认)。
const List<double> kHeadingScale = [2.0, 1.5, 1.17, 1.0, 0.83, 0.67];

/// h1..h6 的上下 margin(em 倍数;CSS 默认)。
const List<double> kHeadingMargin = [0.67, 0.83, 1.0, 1.33, 1.67, 2.33];

/// 按 [base] 派生 heading 样式(NodeFactory.buildHeading 同款)。
TextStyle headingStyleFor(TextStyle base, int level) {
  final em = base.fontSize ?? 14;
  return base.copyWith(
    fontSize: em * kHeadingScale[level - 1],
    fontWeight: FontWeight.bold,
    height: 1.2,
  );
}

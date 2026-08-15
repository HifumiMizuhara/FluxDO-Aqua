/// 内容型 SVG builder —— 主项目接入 `jovial_svg` 渲染。
///
/// 子包不绑 `jovial_svg`(依赖轻量化,对齐 math/iframe)。主项目用
/// `ScalableImage.fromSvgString(node.svgSource)` + `ScalableImageWidget`
/// 渲染,LayoutBuilder 等比铺满可用宽(对齐 legacy `_buildInlineSvg`)。
///
/// 返回 `null` 时子包用内置占位框(图标 + 提示文字)。

library;

import 'package:flutter/widgets.dart';

import '../node/node.dart';

typedef SvgBuilder = Widget? Function(BuildContext context, SvgNode node);

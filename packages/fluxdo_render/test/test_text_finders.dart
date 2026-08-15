/// 测试文本探测 helper —— 兼容两条文本渲染路径。
///
/// 直绘路径(CachedParagraphText,纯文字段落缓存 ui.Paragraph 上屏)落地
/// 后,"文本必是 RichText/RenderParagraph"的探测假设失效:
/// - `find.text('x')` 匹配不到直绘块(它不是 Text/RichText;语义 label
///   已上报但默认 finder 不走 semantics);
/// - `allRenderObjects.whereType<RenderParagraph>()` 拿不到直绘块的
///   渲染对象。
///
/// 测试一律改用本文件的 helper:同时认两条路径,与生产行为(选区走
/// BlockTextGeometry 接口)同构。
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/render/cached_paragraph_text.dart';
import 'package:fluxdo_render/src/selection/block_text_geometry.dart';

/// 找渲染出 [text] 的文本块(RichText 的 plain text 或直绘块的段落文本,
/// 精确匹配)。等价旧 `find.text(text)`。
Finder findRenderedText(String text) => find.byWidgetPredicate(
  (w) => _textOf(w) == text,
  description: 'rendered text "$text"',
);

/// 找渲染文本**包含** [text] 的文本块。等价旧 `find.textContaining`。
Finder findRenderedTextContaining(String text) => find.byWidgetPredicate(
  (w) => _textOf(w)?.contains(text) ?? false,
  description: 'rendered text containing "$text"',
);

String? _textOf(Widget w) {
  // 只认 RichText 与直绘块,不认 Text:Text 内部必然构建一个 RichText,
  // 两者都认会让同一段文本双命中(findsOneWidget 恒失败)。
  if (w is RichText) return w.text.toPlainText(includePlaceholders: false);
  if (w is CachedParagraphText) {
    return w.result.span.toPlainText(includePlaceholders: false);
  }
  return null;
}

/// 第 [index] 个文本几何(树序;RenderParagraph 包适配,直绘块本体)。
/// 等价旧 `allRenderObjects.whereType<RenderParagraph>().first` 的
/// 双路径版:返回统一的 [BlockTextGeometry],坐标/选区原语同构。
BlockTextGeometry textGeometryAt(WidgetTester tester, [int index = 0]) {
  final all = tester.allRenderObjects
      .map<BlockTextGeometry?>((ro) {
        if (ro is RenderCachedParagraph) return ro;
        if (ro is RenderParagraph) return ParagraphGeometry(ro);
        return null;
      })
      .whereType<BlockTextGeometry>()
      .toList();
  return all[index];
}

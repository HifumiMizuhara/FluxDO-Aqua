import 'dart:convert';
import 'dart:math' as math;

/// SVG 处理工具类
///
/// 提供 SVG 内容清理功能，移除 jovial_svg 不支持的元素。
///
/// jovial_svg 原生支持 CSS `<style>`、`<text>`、`<clipPath>`、`<mask>` 等，
/// 因此只需移除少量不支持的特性：
/// - SMIL 动画元素
/// - `<filter>` 元素和 filter 属性
/// - 嵌套 SVG 标签
class SvgUtils {
  SvgUtils._();

  /// 通过文件内容判断是否为 SVG，而不是依赖 URL 后缀。
  static bool isSvgBytes(List<int> bytes) {
    if (bytes.isEmpty) return false;

    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }

    while (start < bytes.length && bytes[start] <= 32) {
      start++;
    }
    if (start >= bytes.length) return false;

    final end = math.min(bytes.length, start + 4096);
    final sample = utf8
        .decode(bytes.sublist(start, end), allowMalformed: true)
        .trimLeft()
        .toLowerCase();

    if (sample.startsWith('<svg')) return true;
    return sample.startsWith('<?xml') && sample.contains('<svg');
  }

  /// 将 SVG 字节按 UTF-8 解码。
  static String decodeSvgBytes(List<int> bytes) {
    final svg = utf8.decode(bytes, allowMalformed: true);
    return svg.startsWith('\uFEFF') ? svg.substring(1) : svg;
  }

  /// 清理 SVG 内容，移除渲染引擎不支持的元素
  static String sanitize(String svg) {
    String result = svg;

    // 1. 移除 `<filter>` 元素和 filter 属性引用
    result = _removeFilters(result);

    // 2. 移除 SMIL 动画标签
    result = _removeAnimations(result);

    // 3. 处理嵌套的 SVG 标签
    result = _flattenNestedSvg(result);

    return result;
  }

  /// 移除不可信 SVG 中的主动内容（防注入）。
  ///
  /// full_svg_flutter 会真实执行 `<script>`（QuickJS），包括拉取并执行
  /// src 指向的外部脚本；`<image href="file://...">` 会读本地文件。
  /// 论坛签名/帖子里的 SVG 是不可信输入，进动画渲染管线前必须剥除：
  /// - `<script>` 元素（含外链 src 变体）
  /// - `on*` 事件属性（onload/onclick/...，会接进 JS 事件注册表）
  /// - `file:` / `javascript:` 协议的 href/xlink:href
  ///
  /// 有意保留 `<style>`/filter/动画（这正是走 full_svg_flutter 的原因）。
  static String stripActiveContent(String svg) {
    var result = svg.replaceAll(_scriptPattern, '');
    result = result.replaceAll(_eventAttrPattern, '');
    result = result.replaceAll(_dangerousHrefPattern, '');
    return result;
  }

  /// Prepares an animated SVG for the shared browser-image renderer.
  ///
  /// The SVG is loaded as a `blob:` image, so the parent document never
  /// parses it as HTML. This extra pass also removes network/file references
  /// from the SVG itself while preserving local fragment references and data
  /// URLs used by self-contained signatures. CSS and SMIL are intentionally
  /// left intact.
  static String sanitizeForSecureWebView(String svg) {
    var result = stripActiveContent(svg);
    result = result.replaceAll(_externalImportPattern, '');
    result = result.replaceAllMapped(_externalHrefPattern, (match) {
      final prefix = match.group(1)!;
      final quote = match.group(2)!;
      return '$prefix$quote$quote';
    });
    result = result.replaceAllMapped(_externalCssUrlPattern, (match) {
      final quote = match.group(1) ?? '';
      return 'url(${quote}about:blank$quote)';
    });
    return result;
  }

  static final RegExp _scriptPattern = RegExp(
    r'<script\b[^>]*>.*?</script>|<script\b[^>]*/>',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _eventAttrPattern = RegExp(
    '''\\son[a-z]+\\s*=\\s*("[^"]*"|'[^']*')''',
    caseSensitive: false,
  );

  static final RegExp _dangerousHrefPattern = RegExp(
    '''\\s(?:xlink:)?href\\s*=\\s*("\\s*(?:file|javascript)\\s*:[^"]*"'''
    """|'\\s*(?:file|javascript)\\s*:[^']*')""",
    caseSensitive: false,
  );

  static final RegExp _externalImportPattern = RegExp(
    r'''@import\s+(?:url\(\s*)?["']?(?!(?:data:|#|about:blank))[^;\n]+;?''',
    caseSensitive: false,
  );

  static final RegExp _externalHrefPattern = RegExp(
    '''(\\s(?:xlink:)?href\\s*=\\s*)(["'])(?!(?:data:|#|blob:|about:blank))[^"']*\\2''',
    caseSensitive: false,
  );

  static final RegExp _externalCssUrlPattern = RegExp(
    r'''url\(\s*(["']?)(?!(?:data:|#|blob:|about:blank))(?:(?:https?:|file:|//|javascript:)[^)]*)\1\s*\)''',
    caseSensitive: false,
  );

  /// 按目标主题求值 `@media (prefers-color-scheme: ...)` 块。
  ///
  /// 渲染引擎(jovial / full_svg_flutter)都不求值媒询——暗色规则整块
  /// 被丢,SVG 永远渲染成亮色。此变换在喂给引擎前做浏览器同款求值:
  /// 命中当前主题的块**展开**为普通规则(参与正常级联),不命中的块
  /// **删除**。花括号配平扫描,块内嵌套规则安全。
  static String resolveColorSchemeMedia(String svg, {required bool dark}) {
    final mediaOpen = RegExp(r'@media\s*([^{]*)\{', caseSensitive: false);
    final scheme = RegExp(r'prefers-color-scheme\s*:\s*(dark|light)');
    StringBuffer? buf;
    var pos = 0;
    for (final m in mediaOpen.allMatches(svg)) {
      if (m.start < pos) continue; // 已被前一个块消费
      final schemeMatch = scheme.firstMatch(m.group(1)!.toLowerCase());
      if (schemeMatch == null) continue; // 非主题媒询,原样保留
      // 花括号配平找块尾
      var depth = 1;
      var i = m.end;
      while (i < svg.length && depth > 0) {
        final c = svg.codeUnitAt(i);
        if (c == 0x7B) {
          depth++;
        } else if (c == 0x7D) {
          depth--;
        }
        i++;
      }
      buf ??= StringBuffer();
      buf.write(svg.substring(pos, m.start));
      if ((schemeMatch.group(1) == 'dark') == dark) {
        buf.write(svg.substring(m.end, i - 1)); // 展开块内规则
      }
      pos = i;
    }
    if (buf == null) return svg;
    buf.write(svg.substring(pos));
    return buf.toString();
  }

  /// 移除 `<filter>` 元素和相关属性引用
  static String _removeFilters(String content) {
    String result = content;

    // 移除 <filter>...</filter>
    result = result.replaceAll(
      RegExp(
        r'<filter\b[^>]*>.*?</filter>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );

    // 移除 filter 属性引用
    result = result.replaceAll(
      RegExp(r'\s*filter\s*=\s*"[^"]*"', caseSensitive: false),
      '',
    );
    result = result.replaceAll(
      RegExp(r'filter\s*:\s*[^;]+;', caseSensitive: false),
      '',
    );

    return result;
  }

  /// 移除 SMIL 动画标签
  static String _removeAnimations(String content) {
    final smilPattern = RegExp(
      r'<(animate|animateTransform|animateMotion|animateColor|set)\b[^>]*(?:/>|>.*?</\1>)',
      caseSensitive: false,
      dotAll: true,
    );
    return content.replaceAll(smilPattern, '');
  }

  /// 处理嵌套的 SVG 标签 - 提取内层 SVG 的内容合并到外层
  static String _flattenNestedSvg(String content) {
    String result = content;

    final nestedSvgPattern = RegExp(
      r'(<svg\b[^>]*>)\s*<svg\b[^>]*>(.*?)</svg>\s*(</svg>)',
      caseSensitive: false,
      dotAll: true,
    );

    while (nestedSvgPattern.hasMatch(result)) {
      result = result.replaceFirstMapped(nestedSvgPattern, (match) {
        final outerStart = match.group(1)!;
        final innerContent = match.group(2)!;
        final outerEnd = match.group(3)!;
        return '$outerStart$innerContent$outerEnd';
      });
    }

    return result;
  }
}

import 'package:markdown/markdown.dart' as md;

import '../../utils/url_helper.dart';

/// 把 Markdown 字符串转换成一组 Notion block JSON。
///
/// 设计要点：
/// - 不追求逐字符等价；只覆盖 Discourse 帖子里高频的元素，确保信息无损可读。
/// - 单个 rich_text 的 `content` 超过 [_kRichTextMaxLen] 会被切分，避免 Notion 报 400。
/// - 图片用 `external` 类型直接传 URL，不下载（Discourse CDN 一般开放外链）。
/// - 表格、引用、代码、列表都会展开为对应 block；列表保留单层嵌套。
/// - Discourse 专属语法在 [discourseHtmlBlocksToNotion] 走另一条 cooked HTML 路径，
///   适配 onebox 链接预览、details 折叠、poll 投票等结构。本函数收到 [Cooked]
///   原文中可能残留的 HTML 标签会尽量降级成 paragraph + 富文本。
List<Map<String, dynamic>> markdownToNotionBlocks(String source) {
  if (source.trim().isEmpty) return const [];
  final doc = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final nodes = doc.parseLines(lines);
  final blocks = <Map<String, dynamic>>[];
  for (final node in nodes) {
    blocks.addAll(_nodeToBlocks(node));
  }
  return blocks;
}

const int _kRichTextMaxLen = 1800;

/// 把段落里的 `<img>` 拆出来作为独立 image block,其余 inline 节点继续作为
/// paragraph。常见情形:Discourse 里"文字+多张图"挤在同一段落,如果整段都当
/// paragraph 处理,图就只剩文字链接;直接全部当 image 又会丢文字。
List<Map<String, dynamic>> _paragraphToBlocks(md.Element para) {
  final children = para.children ?? const <md.Node>[];
  // 没有任何 img 的快速路径
  final hasImg = children.any((n) => n is md.Element && n.tag == 'img');
  if (!hasImg) {
    return [_paragraph(_inlineRich(children))];
  }
  final out = <Map<String, dynamic>>[];
  final buffer = <md.Node>[];
  void flushText() {
    if (buffer.isEmpty) return;
    final rich = _inlineRich(List.of(buffer));
    buffer.clear();
    // 全空白文本不产生 block
    final hasContent = rich.any((r) {
      final text = (r['text'] as Map?)?['content'] as String? ?? '';
      return text.trim().isNotEmpty;
    });
    if (hasContent) out.add(_paragraph(rich));
  }

  for (final node in children) {
    if (node is md.Element && node.tag == 'img') {
      flushText();
      final url = node.attributes['src'];
      if (url != null && url.isNotEmpty) {
        out.add(_imageBlock(url, alt: node.attributes['alt']));
      }
    } else if (node is md.Element && node.tag == 'br') {
      // br 是软换行,不拆 block,仍归入 buffer
      buffer.add(node);
    } else {
      buffer.add(node);
    }
  }
  flushText();
  // 如果整段啥都没产出(罕见),至少给个空段落避免上层报错
  if (out.isEmpty) out.add(_paragraph(const []));
  return out;
}

List<Map<String, dynamic>> _nodeToBlocks(md.Node node) {
  if (node is md.Text) {
    return [
      _paragraph([_textRich(node.text)]),
    ];
  }
  if (node is! md.Element) return const [];

  switch (node.tag) {
    case 'h1':
      return [_heading(1, _inlineRich(node.children))];
    case 'h2':
      return [_heading(2, _inlineRich(node.children))];
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      // Notion 只有 h1-h3,h4+ 全压到 h3
      return [_heading(3, _inlineRich(node.children))];
    case 'p':
      return _paragraphToBlocks(node);
    case 'hr':
      return [
        {'object': 'block', 'type': 'divider', 'divider': <String, dynamic>{}},
      ];
    case 'blockquote':
      // 把内部所有块级文本拍平成一个 quote block 的 children
      final rich = <Map<String, dynamic>>[];
      for (final child in node.children ?? const <md.Node>[]) {
        if (child is md.Element && child.tag == 'p') {
          if (rich.isNotEmpty) rich.add(_textRich('\n'));
          rich.addAll(_inlineRich(child.children));
        } else if (child is md.Text) {
          rich.add(_textRich(child.text));
        }
      }
      return [
        {
          'object': 'block',
          'type': 'quote',
          'quote': {'rich_text': rich},
        },
      ];
    case 'pre':
      return [_codeBlockFromPre(node)];
    case 'ul':
      return _listChildrenToBlocks(node, 'bulleted_list_item');
    case 'ol':
      return _listChildrenToBlocks(node, 'numbered_list_item');
    case 'table':
      return [_tableToBlock(node)];
    case 'img':
      final url = node.attributes['src'];
      if (url != null && url.isNotEmpty) {
        return [_imageBlock(url, alt: node.attributes['alt'])];
      }
      return const [];
    default:
      // 兜底：当作段落
      return [_paragraph(_inlineRich(node.children))];
  }
}

List<Map<String, dynamic>> _listChildrenToBlocks(md.Element list, String type) {
  final out = <Map<String, dynamic>>[];
  for (final li in list.children ?? const <md.Node>[]) {
    if (li is! md.Element || li.tag != 'li') continue;
    // li 内可能混合 inline + 嵌套 list；把首段 inline 拼成 rich_text,
    // 嵌套块作为 children
    final rich = <Map<String, dynamic>>[];
    final children = <Map<String, dynamic>>[];
    for (final child in li.children ?? const <md.Node>[]) {
      if (child is md.Text) {
        rich.add(_textRich(child.text));
      } else if (child is md.Element) {
        if (child.tag == 'p') {
          if (rich.isEmpty) {
            rich.addAll(_inlineRich(child.children));
          } else {
            children.add(_paragraph(_inlineRich(child.children)));
          }
        } else if (child.tag == 'ul' || child.tag == 'ol') {
          children.addAll(
            _listChildrenToBlocks(
              child,
              child.tag == 'ul' ? 'bulleted_list_item' : 'numbered_list_item',
            ),
          );
        } else {
          // 其它 inline 元素当 inline 处理
          rich.addAll(_inlineRich([child]));
        }
      }
    }
    out.add({
      'object': 'block',
      'type': type,
      type: {
        'rich_text': rich.isEmpty ? [_textRich('')] : rich,
        if (children.isNotEmpty) 'children': children,
      },
    });
  }
  return out;
}

Map<String, dynamic> _tableToBlock(md.Element table) {
  final rows = <List<List<Map<String, dynamic>>>>[]; // row -> cell -> rich_text
  for (final section in table.children ?? const <md.Node>[]) {
    if (section is! md.Element) continue;
    for (final tr in section.children ?? const <md.Node>[]) {
      if (tr is! md.Element || tr.tag != 'tr') continue;
      final cells = <List<Map<String, dynamic>>>[];
      for (final cell in tr.children ?? const <md.Node>[]) {
        if (cell is! md.Element) continue;
        cells.add(_inlineRich(cell.children));
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
  }
  if (rows.isEmpty) return _paragraph(const []);
  final cols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  return {
    'object': 'block',
    'type': 'table',
    'table': {
      'table_width': cols,
      'has_column_header': true,
      'has_row_header': false,
      'children': [
        for (final row in rows)
          {
            'object': 'block',
            'type': 'table_row',
            'table_row': {
              'cells': [
                for (var i = 0; i < cols; i++)
                  i < row.length ? row[i] : [_textRich('')],
              ],
            },
          },
      ],
    },
  };
}

Map<String, dynamic> _codeBlockFromPre(md.Element pre) {
  // pre > code, code.attributes['class'] = 'language-xxx'
  String language = 'plain text';
  String text = '';
  final first = pre.children?.firstOrNull;
  if (first is md.Element && first.tag == 'code') {
    final cls = first.attributes['class'];
    if (cls != null) {
      final match = RegExp(r'language-([\w+#.-]+)').firstMatch(cls);
      if (match != null) language = _mapNotionLanguage(match.group(1)!);
    }
    text = first.textContent;
  } else {
    text = pre.textContent;
  }
  return {
    'object': 'block',
    'type': 'code',
    'code': {'rich_text': _splitRich(text), 'language': language},
  };
}

/// Notion code block 只接受固定语言枚举,把常见 alias 映射过去；
/// 未知语言降级到 plain text。
String _mapNotionLanguage(String input) {
  const aliases = {
    'js': 'javascript',
    'ts': 'typescript',
    'sh': 'shell',
    'bash': 'shell',
    'zsh': 'shell',
    'py': 'python',
    'yml': 'yaml',
    'md': 'markdown',
    'c++': 'c++',
    'cpp': 'c++',
    'cs': 'c#',
    'cc': 'c++',
    'rs': 'rust',
    'kt': 'kotlin',
    'rb': 'ruby',
  };
  final lower = input.toLowerCase();
  final mapped = aliases[lower] ?? lower;
  // 白名单（Notion 支持的常见值）
  const supported = {
    'abap',
    'arduino',
    'bash',
    'basic',
    'c',
    'clojure',
    'coffeescript',
    'c++',
    'c#',
    'css',
    'dart',
    'diff',
    'docker',
    'elixir',
    'elm',
    'erlang',
    'flow',
    'fortran',
    'f#',
    'gherkin',
    'glsl',
    'go',
    'graphql',
    'groovy',
    'haskell',
    'html',
    'java',
    'javascript',
    'json',
    'julia',
    'kotlin',
    'latex',
    'less',
    'lisp',
    'livescript',
    'lua',
    'makefile',
    'markdown',
    'markup',
    'matlab',
    'mermaid',
    'nix',
    'objective-c',
    'ocaml',
    'pascal',
    'perl',
    'php',
    'plain text',
    'powershell',
    'prolog',
    'protobuf',
    'python',
    'r',
    'reason',
    'ruby',
    'rust',
    'sass',
    'scala',
    'scheme',
    'scss',
    'shell',
    'solidity',
    'sql',
    'swift',
    'toml',
    'typescript',
    'vb.net',
    'verilog',
    'vhdl',
    'visual basic',
    'webassembly',
    'xml',
    'yaml',
  };
  return supported.contains(mapped) ? mapped : 'plain text';
}

// ----- inline -----

List<Map<String, dynamic>> _inlineRich(List<md.Node>? nodes) {
  if (nodes == null) return const [];
  final out = <Map<String, dynamic>>[];
  for (final n in nodes) {
    _inlineCollect(n, _Annotations.none, out, null);
  }
  return out;
}

void _inlineCollect(
  md.Node node,
  _Annotations ann,
  List<Map<String, dynamic>> out,
  String? href,
) {
  if (node is md.Text) {
    final text = node.textContent;
    if (text.isEmpty) return;
    for (final chunk in _chunked(text)) {
      out.add(_richFromText(chunk, ann, href));
    }
    return;
  }
  if (node is! md.Element) return;
  switch (node.tag) {
    case 'em':
      _withChildren(node, ann.copyWith(italic: true), out, href);
      break;
    case 'strong':
      _withChildren(node, ann.copyWith(bold: true), out, href);
      break;
    case 'del':
      _withChildren(node, ann.copyWith(strikethrough: true), out, href);
      break;
    case 'code':
      _withChildren(node, ann.copyWith(code: true), out, href);
      break;
    case 'a':
      final url = node.attributes['href'];
      _withChildren(node, ann, out, url ?? href);
      break;
    case 'br':
      out.add(_textRich('\n'));
      break;
    case 'img':
      // 段落里穿插的图片当成 image 链接显示（块级图片在 _nodeToBlocks 处理）
      final src = node.attributes['src'];
      final alt = node.attributes['alt'] ?? src ?? '';
      if (src != null) {
        out.add(_richFromText(alt, ann, src));
      }
      break;
    default:
      _withChildren(node, ann, out, href);
  }
}

void _withChildren(
  md.Element node,
  _Annotations ann,
  List<Map<String, dynamic>> out,
  String? href,
) {
  for (final child in node.children ?? const <md.Node>[]) {
    _inlineCollect(child, ann, out, href);
  }
}

class _Annotations {
  const _Annotations({
    this.bold = false,
    this.italic = false,
    this.strikethrough = false,
    this.code = false,
  });

  static const none = _Annotations();

  final bool bold;
  final bool italic;
  final bool strikethrough;
  final bool code;

  _Annotations copyWith({
    bool? bold,
    bool? italic,
    bool? strikethrough,
    bool? code,
  }) => _Annotations(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    strikethrough: strikethrough ?? this.strikethrough,
    code: code ?? this.code,
  );

  Map<String, dynamic>? toJson() {
    if (!bold && !italic && !strikethrough && !code) return null;
    return {
      if (bold) 'bold': true,
      if (italic) 'italic': true,
      if (strikethrough) 'strikethrough': true,
      if (code) 'code': true,
    };
  }
}

Map<String, dynamic> _richFromText(
  String text,
  _Annotations ann,
  String? href,
) {
  final annJson = ann.toJson();
  final normalizedHref = _normalizeLinkUrl(href);
  return {
    'type': 'text',
    'text': {
      'content': text,
      if (normalizedHref != null) 'link': {'url': normalizedHref},
    },
    if (annJson != null) 'annotations': annJson,
  };
}

/// 规范化超链接 URL。比 image 宽松：允许 mailto / tel 等非 http(s) scheme,
/// 但对 `upload://` 这种 Discourse 内部占位符以及空/纯 anchor (#xxx) 直接丢弃。
String? _normalizeLinkUrl(String? raw) {
  if (raw == null) return null;
  var url = raw.trim();
  if (url.isEmpty) return null;
  if (url.startsWith('#')) return null; // 纯 anchor 在 Notion 内无意义
  if (url.startsWith('upload://')) return null;

  // 走应用统一的 resolve(不走 CDN,链接不需要 S3 重写)
  url = UrlHelper.resolveUrl(url);

  // 只允许这些 scheme;其它(javascript: / file: / 自定义协议)一律丢弃
  const allowed = {'http', 'https', 'mailto', 'tel', 'sms', 'ftp'};
  final scheme = _schemeOf(url);
  if (scheme == null || !allowed.contains(scheme)) return null;

  final encoded = Uri.encodeFull(url);
  if (encoded.length > 2000) return null;
  return encoded;
}

String? _schemeOf(String url) {
  final colon = url.indexOf(':');
  if (colon <= 0) return null;
  final scheme = url.substring(0, colon).toLowerCase();
  // 只接受 [a-z][a-z0-9+.-]*  形式
  if (!RegExp(r'^[a-z][a-z0-9+\-.]*$').hasMatch(scheme)) return null;
  return scheme;
}

Map<String, dynamic> _textRich(String text) =>
    _richFromText(text, _Annotations.none, null);

/// 把超长字符串切成多段 rich_text。
List<Map<String, dynamic>> _splitRich(String text) {
  return [for (final chunk in _chunked(text)) _textRich(chunk)];
}

Iterable<String> _chunked(String text) sync* {
  if (text.length <= _kRichTextMaxLen) {
    yield text;
    return;
  }
  for (var i = 0; i < text.length; i += _kRichTextMaxLen) {
    final end = (i + _kRichTextMaxLen).clamp(0, text.length);
    yield text.substring(i, end);
  }
}

// ----- block builders -----

Map<String, dynamic> _paragraph(List<Map<String, dynamic>> rich) {
  return {
    'object': 'block',
    'type': 'paragraph',
    'paragraph': {
      'rich_text': rich.isEmpty ? [_textRich('')] : rich,
    },
  };
}

Map<String, dynamic> _heading(int level, List<Map<String, dynamic>> rich) {
  final type = 'heading_$level';
  return {
    'object': 'block',
    'type': type,
    type: {
      'rich_text': rich.isEmpty ? [_textRich('')] : rich,
    },
  };
}

Map<String, dynamic> _imageBlock(String url, {String? alt}) {
  final normalized = _normalizeImageUrl(url);
  if (normalized == null) {
    // 校验失败 -> 退化成段落里的「[图片] alt (url)」, 至少信息不丢
    final label = alt != null && alt.isNotEmpty ? '🖼 $alt' : '🖼 image';
    return _paragraph([_richFromText(label, _Annotations.none, url.trim())]);
  }
  return {
    'object': 'block',
    'type': 'image',
    'image': {
      'type': 'external',
      'external': {'url': normalized},
      if (alt != null && alt.isNotEmpty) 'caption': [_textRich(alt)],
    },
  };
}

/// Notion external image 要求合法 http(s) 绝对 URL。
/// 返回 null 表示需要降级为非 image block。
///
/// 规范化策略复用 [UrlHelper.resolveUrlWithCdn]，确保与应用内其它图片展示
/// 路径一致 —— 处理 `//host/...` 协议相对、`/uploads/...` 站内相对、
/// S3 CDN 重写。
///
/// 但 `upload://shortcode.ext` 是 Discourse raw markdown 里的占位符，
/// 需要服务端 short-url 表才能解析为真实 CDN URL，客户端拿不到。
/// 这种 URL 直接返回 null 让上层降级为段落链接。
String? _normalizeImageUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return null;
  if (url.startsWith('upload://')) return null;
  if (url.startsWith('data:') || url.startsWith('blob:')) return null;

  url = UrlHelper.resolveUrlWithCdn(url);

  // resolveUrlWithCdn 不会强制 http(s) 协议,这里再校验一遍
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return null;
  }
  final parsed = Uri.tryParse(url);
  if (parsed == null || parsed.host.isEmpty) return null;
  // Uri.encodeFull 处理空格、中文等非法字符
  final encoded = Uri.encodeFull(url);
  if (encoded.length > 2000) return null;
  return encoded;
}

// ----- Discourse 专属语法（cooked HTML 路径）-----

/// 把 Discourse cooked HTML 里的专属块语法（onebox / details / poll）映射为
/// Notion blocks。其它内容回退到 [markdownToNotionBlocks]。
///
/// 调用者负责传入「已经从 cooked 字符串里抽出来的、对应的 HTML 片段」。
/// 这里只暴露两个工具函数，让上层在自己的 HTML 解析里按需调用。
class DiscourseBlockMappers {
  /// onebox 卡片 -> 一个带链接的 paragraph，把缩略图/标题/描述拼一起。
  /// 设计上避免造一个新的 block 类型，直接用 paragraph 是为了 Notion 端搜索友好。
  static Map<String, dynamic> oneboxToBlock({
    required String url,
    String? title,
    String? description,
  }) {
    final rich = <Map<String, dynamic>>[
      _richFromText(title ?? url, const _Annotations(bold: true), url),
    ];
    if (description != null && description.isNotEmpty) {
      rich.add(_textRich('\n'));
      rich.add(_textRich(description));
    }
    return _paragraph(rich);
  }

  /// details 折叠 -> Notion 的 toggle block。
  static Map<String, dynamic> detailsToToggle({
    required String summary,
    required List<Map<String, dynamic>> children,
  }) {
    return {
      'object': 'block',
      'type': 'toggle',
      'toggle': {
        'rich_text': [_textRich(summary.isEmpty ? '...' : summary)],
        'children': children,
      },
    };
  }

  /// poll 投票 -> 文字概述（Notion 没有原生投票）。
  static Map<String, dynamic> pollToBlock({
    required String title,
    required List<String> options,
  }) {
    final rich = <Map<String, dynamic>>[
      _richFromText('📊 $title\n', const _Annotations(bold: true), null),
    ];
    for (final opt in options) {
      rich.add(_textRich('  • $opt\n'));
    }
    return {
      'object': 'block',
      'type': 'callout',
      'callout': {
        'rich_text': rich,
        'icon': {'type': 'emoji', 'emoji': '📊'},
      },
    };
  }
}

import 'package:html/parser.dart' as html_parser;
import 'package:html/dom.dart' as dom;
import 'html_chunk.dart';

/// HTML 分割器
class HtmlChunker {
  /// 长帖分块阈值 —— cooked HTML 超过此长度才分块虚拟化(短帖整段渲染)。
  ///
  /// 5000 → 2000(2026-07):生产诊断(120Hz)显示稳态滚动掉帧主体是
  /// build 6~16ms 帧 = 中等帖子(2~5K 字符)整帖首建的 parse+构建+排版
  /// 一次性落在同一滚动帧;分块后随 sliver 逐帧物化,单帧只付一块
  /// (≤_maxMergeLength=2000 字符)的成本,且块可被空闲预热提前解析。
  /// 真正的短帖(<2000)单帧成本本就在预算内,保持整段渲染。
  static const int chunkThreshold = 2000;

  /// 块级元素标签（需要独立成块）
  static const _blockTags = {
    'table',
    'pre',
    'aside',
    'blockquote',
    'details',
    'hr',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'dl',
    'figure',
    'video',
    'audio',
  };

  /// 需要特殊处理的类名
  static const _specialClasses = {'spoiler', 'spoiled'};

  /// div 元素中需要独立成块的类名
  static const _blockDivClasses = {'md-table'};

  /// 最大段落合并字符数（增大以减少块数量，降低 HtmlWidget 实例开销）
  static const _maxMergeLength = 2000;

  /// 最大段落合并数
  static const _maxMergeParagraphs = 8;

  /// 分割 HTML 为块列表
  static List<HtmlChunk> chunk(String html) {
    if (html.isEmpty) return [];
    final document = html_parser.parseFragment(html);
    return chunkDocument(html: html, document: document);
  }

  /// 复用已解析的 DOM 进行分块。
  ///
  /// 用于与其他派生(如 GalleryInfo)共用一次 parseFragment 的场景,
  /// 避免对同一 HTML 重复解析。[html] 仅用于单块时回退到原文本。
  static List<HtmlChunk> chunkDocument({
    required String html,
    required dom.DocumentFragment document,
  }) {
    final chunks = <HtmlChunk>[];
    final pendingNodes = <dom.Node>[];
    int pendingLength = 0;

    void flushPending() {
      if (pendingNodes.isEmpty) return;

      final buffer = StringBuffer();
      for (final node in pendingNodes) {
        if (node is dom.Element) {
          buffer.write(node.outerHtml);
        } else if (node is dom.Text) {
          buffer.write(node.text);
        }
      }

      final content = buffer.toString().trim();
      if (content.isNotEmpty) {
        chunks.add(
          HtmlChunk(
            html: content,
            type: HtmlChunkType.paragraph,
            index: chunks.length,
          ),
        );
      }

      pendingNodes.clear();
      pendingLength = 0;
    }

    for (final node in document.nodes) {
      if (node is dom.Element) {
        // 检查是否是块级元素
        if (_isBlockElement(node)) {
          flushPending();
          chunks.add(
            HtmlChunk(
              html: node.outerHtml,
              type: _getChunkType(node),
              index: chunks.length,
            ),
          );
        } else {
          // 内联元素或短段落，累积
          final nodeLength = node.outerHtml.length;
          pendingNodes.add(node);
          pendingLength += nodeLength;

          // 达到合并阈值时强制分块
          if (pendingLength > _maxMergeLength ||
              pendingNodes.length >= _maxMergeParagraphs) {
            flushPending();
          }
        }
      } else if (node is dom.Text) {
        final text = node.text;
        if (text.trim().isNotEmpty) {
          pendingNodes.add(node);
          pendingLength += text.length;
        }
      }
    }

    flushPending();

    // 后处理 ①:chunk 结尾的孤立 <br> 是分块产生的冗余。原本 `文字<br><图>`
    // 在连续渲染里只是一个换行;分块把 <图> 切到下一个 chunk 后,chunk 之间
    // 垂直堆叠本身就提供了换行,结尾这个 <br> 会再多渲染一个空行(真机 FAQ 帖
    // 图文之间多空当的根因)。去掉它(末 chunk 不动,它后面没有续接)。
    for (int i = 0; i < chunks.length - 1; i++) {
      final chunk = chunks[i];
      if (chunk.type != HtmlChunkType.paragraph) continue;
      final trimmed = chunk.html.replaceFirst(RegExp(r'<br\s*/?>$'), '');
      if (trimmed.length != chunk.html.length) {
        chunks[i] = HtmlChunk(
          html: trimmed,
          type: chunk.type,
          index: chunk.index,
        );
      }
    }

    // 后处理 ②:将 chunk 开头的孤立 <br> 替换为 lb-spacer 占位标记
    // 分块切割可能把 lightbox 之间的 <br> 切到下一个 chunk 开头，
    // 预处理无法匹配到它（前面没有 </a></div>），需要在这里替换。
    for (int i = 1; i < chunks.length; i++) {
      final chunk = chunks[i];
      if (chunk.type == HtmlChunkType.paragraph &&
          chunk.html.startsWith('<br')) {
        final replaced = chunk.html.replaceFirst(
          RegExp(r'^<br\s*/?>'),
          '<div class="lb-spacer"></div>',
        );
        chunks[i] = HtmlChunk(
          html: replaced,
          type: chunk.type,
          index: chunk.index,
        );
      }
    }

    // 后处理 ③:标记「被切断的单段落」接缝 → 无缝拼接。相邻两 paragraph chunk
    // 若都在松散 inline 流边界(末/首节点是 text / <br> / lightbox / lb-spacer /
    // 行内元素,而非 <p> / 块边界),说明它们是同一段落被分块切开 —— 给两侧打
    // joinsNext/joinsPrevious,渲染时裁掉接缝侧外边距,与连续渲染一致。真正
    // 块边界(如 <p> 之间)不打标,保留正常段落间距。
    for (int i = 0; i < chunks.length - 1; i++) {
      final a = chunks[i];
      final b = chunks[i + 1];
      if (a.type != HtmlChunkType.paragraph ||
          b.type != HtmlChunkType.paragraph) {
        continue;
      }
      if (_endsInlineFlow(a.html) && _startsInlineFlow(b.html)) {
        chunks[i] = a.copyWith(joinsNext: true);
        chunks[i + 1] = b.copyWith(joinsPrevious: true);
      }
    }

    // 如果只有一个块，直接返回原 HTML（避免不必要的拆分）
    if (chunks.length == 1) {
      return [HtmlChunk(html: html, type: chunks.first.type, index: 0)];
    }

    return chunks;
  }

  /// 松散 inline 流元素(会与相邻 text 合并进同一段落,不自带块边距):
  /// `<br>`、lightbox/lb-spacer 占位 div、以及常见行内标签。
  /// `<p>` / 带 align 的 div / 标题等「块段落」不算 —— 它们之间是真实段落边界。
  static const _inlineFlowTags = {
    'a',
    'span',
    'code',
    'em',
    'strong',
    'b',
    'i',
    'u',
    's',
    'del',
    'ins',
    'mark',
    'kbd',
    'samp',
    'tt',
    'sup',
    'sub',
    'small',
    'big',
    'img',
    'abbr',
    'q',
    'wbr',
    'font',
  };

  static bool _isInlineFlowElement(dom.Element el) {
    final tag = el.localName?.toLowerCase() ?? '';
    if (tag == 'br') return true;
    if (tag == 'div') {
      return el.classes.contains('lightbox-wrapper') ||
          el.classes.contains('lb-spacer');
    }
    return _inlineFlowTags.contains(tag);
  }

  /// chunk 开头是否是松散 inline 流(跳过纯空白文本)。
  static bool _startsInlineFlow(String html) {
    final nodes = html_parser.parseFragment(html).nodes;
    for (final n in nodes) {
      if (n is dom.Text) {
        if (n.text.trim().isEmpty) continue;
        return true;
      }
      if (n is dom.Element) return _isInlineFlowElement(n);
    }
    return false;
  }

  /// chunk 结尾是否是松散 inline 流(跳过纯空白文本)。
  static bool _endsInlineFlow(String html) {
    final nodes = html_parser.parseFragment(html).nodes;
    for (final n in nodes.reversed) {
      if (n is dom.Text) {
        if (n.text.trim().isEmpty) continue;
        return true;
      }
      if (n is dom.Element) return _isInlineFlowElement(n);
    }
    return false;
  }

  static bool _isBlockElement(dom.Element element) {
    final tagName = element.localName?.toLowerCase() ?? '';

    // 标签名匹配
    if (_blockTags.contains(tagName)) return true;

    // div 元素检查特殊类名和块级类名
    if (tagName == 'div') {
      final classes = element.classes;
      if (classes.any((c) => _specialClasses.contains(c))) return true;
      if (classes.any((c) => _blockDivClasses.contains(c))) return true;
    }

    // span 元素检查特殊类名
    if (tagName == 'span') {
      final classes = element.classes;
      if (classes.any((c) => _specialClasses.contains(c))) return true;
    }

    return false;
  }

  static HtmlChunkType _getChunkType(dom.Element element) {
    final tagName = element.localName?.toLowerCase() ?? '';

    switch (tagName) {
      case 'table':
        return HtmlChunkType.table;
      case 'pre':
        return HtmlChunkType.codeBlock;
      case 'blockquote':
        return HtmlChunkType.blockquote;
      case 'details':
        return HtmlChunkType.details;
      case 'hr':
        return HtmlChunkType.divider;
      case 'ul':
      case 'ol':
      case 'dl':
        return HtmlChunkType.list;
      case 'aside':
        if (element.classes.contains('quote')) return HtmlChunkType.quoteCard;
        if (element.classes.contains('onebox')) return HtmlChunkType.onebox;
        return HtmlChunkType.paragraph;
      case 'div':
        if (element.classes.contains('md-table')) return HtmlChunkType.table;
        return HtmlChunkType.paragraph;
      default:
        if (tagName.startsWith('h') && tagName.length == 2) {
          return HtmlChunkType.heading;
        }
        if (element.classes.contains('spoiler') ||
            element.classes.contains('spoiled')) {
          return HtmlChunkType.spoiler;
        }
        return HtmlChunkType.paragraph;
    }
  }
}

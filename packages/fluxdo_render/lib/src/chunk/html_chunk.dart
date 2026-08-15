/// HTML 块类型枚举
enum HtmlChunkType {
  paragraph, // 段落（可能包含多个连续的 <p>、文本）
  codeBlock, // 代码块 <pre><code>
  table, // 表格 <table>
  quoteCard, // 引用卡片 <aside class="quote">
  onebox, // 链接卡片 <aside class="onebox">
  blockquote, // 普通引用 <blockquote>
  spoiler, // 折叠内容 .spoiler/.spoiled
  heading, // 标题 <h1>-<h6>
  list, // 列表 <ul>/<ol>
  divider, // 分割线 <hr>
  details, // 折叠详情 <details>
}

/// HTML 块数据
class HtmlChunk {
  final String html;
  final HtmlChunkType type;
  final int index;

  /// 本 chunk 的首块是否「接续上一片」—— 上一片末尾与本片开头同属一个被分块
  /// 切断的松散 inline 段落(非 `<p>`/块边界)。为 true 时渲染裁掉首块上边距,
  /// 让接缝与连续渲染无缝(见 FluxdoRender.trimTopMargin)。
  final bool joinsPrevious;

  /// 本 chunk 的末块是否「接续下一片」(对称于 [joinsPrevious])。
  final bool joinsNext;

  const HtmlChunk({
    required this.html,
    required this.type,
    required this.index,
    this.joinsPrevious = false,
    this.joinsNext = false,
  });

  HtmlChunk copyWith({String? html, bool? joinsPrevious, bool? joinsNext}) =>
      HtmlChunk(
        html: html ?? this.html,
        type: type,
        index: index,
        joinsPrevious: joinsPrevious ?? this.joinsPrevious,
        joinsNext: joinsNext ?? this.joinsNext,
      );
}

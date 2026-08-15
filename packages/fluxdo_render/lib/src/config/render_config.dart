/// 节点类型注册表。
///
/// 曾经这里还承载渲染引擎灰度开关(RenderEngine / RenderConfig),
/// legacy fwfh 引擎下线后已移除,现只保留 [NodeKind] —— 项目内"节点"的
/// 唯一权威定义,与 test/fixtures/ 目录名 + golden 目录名一一对应。
library;

/// 节点类型。**必须与 test/fixtures/ 目录名 + golden 目录名一一对应**。
///
/// 这是项目内"节点"的唯一权威定义。新增节点时:
/// 1. 在这里加 enum 值
/// 2. 在 test/fixtures/ 下加同名目录
/// 3. 在 NodeFactory 里实现对应 buildXxx
enum NodeKind {
  paragraph,
  heading,
  list,
  codeBlock,
  quoteCard,
  spoiler,
  details,
  onebox,
  table,
  poll,
  math,
  iframe,
  imageGrid,
  lazyVideo,
  footnote,
  mention,
  emoji,
  lightbox,
  inlineCode,
  blockquote,
  callout,
  chatTranscript,
  localDate,
  policy,
  horizontalRule,
  image,
  clickCount,
  definitionList,
  svg,
  attachment,
  video,
  audio;

  /// 与 fixture 目录名一致的字符串(snake_case)。
  String get dirName => switch (this) {
    NodeKind.paragraph => 'paragraph',
    NodeKind.heading => 'heading',
    NodeKind.list => 'list',
    NodeKind.codeBlock => 'code_block',
    NodeKind.quoteCard => 'quote_card',
    NodeKind.spoiler => 'spoiler',
    NodeKind.details => 'details',
    NodeKind.onebox => 'onebox',
    NodeKind.table => 'table',
    NodeKind.poll => 'poll',
    NodeKind.math => 'math',
    NodeKind.iframe => 'iframe',
    NodeKind.imageGrid => 'image_grid',
    NodeKind.lazyVideo => 'lazy_video',
    NodeKind.footnote => 'footnote',
    NodeKind.mention => 'mention',
    NodeKind.emoji => 'emoji',
    NodeKind.lightbox => 'lightbox',
    NodeKind.inlineCode => 'inline_code',
    NodeKind.blockquote => 'blockquote',
    NodeKind.callout => 'callout',
    NodeKind.chatTranscript => 'chat_transcript',
    NodeKind.localDate => 'local_date',
    NodeKind.policy => 'policy',
    NodeKind.horizontalRule => 'horizontal_rule',
    NodeKind.image => 'image',
    NodeKind.clickCount => 'click_count',
    NodeKind.definitionList => 'definition_list',
    NodeKind.svg => 'svg',
    NodeKind.attachment => 'attachment',
    NodeKind.video => 'video',
    NodeKind.audio => 'audio',
  };

  /// 节点的英文显示名,作为 fallback 显示。
  ///
  /// 调用方(主项目)需要做本地化时,**不要直接用这个字段**,而是
  /// 用 `NodeKind.name`(如 `'paragraph'`)作为 l10n key 查表。
  /// 子包不应承载用户面文本。
  String get label => switch (this) {
    NodeKind.paragraph => 'Paragraph',
    NodeKind.heading => 'Heading',
    NodeKind.list => 'List',
    NodeKind.codeBlock => 'Code block',
    NodeKind.quoteCard => 'Quote card',
    NodeKind.spoiler => 'Spoiler',
    NodeKind.details => 'Details',
    NodeKind.onebox => 'Onebox',
    NodeKind.table => 'Table',
    NodeKind.poll => 'Poll',
    NodeKind.math => 'Math',
    NodeKind.iframe => 'Iframe',
    NodeKind.imageGrid => 'Image grid',
    NodeKind.lazyVideo => 'Lazy video',
    NodeKind.footnote => 'Footnote',
    NodeKind.mention => 'Mention',
    NodeKind.emoji => 'Emoji',
    NodeKind.lightbox => 'Lightbox',
    NodeKind.inlineCode => 'Inline code',
    NodeKind.blockquote => 'Blockquote',
    NodeKind.callout => 'Callout',
    NodeKind.chatTranscript => 'Chat transcript',
    NodeKind.localDate => 'Local date',
    NodeKind.policy => 'Policy',
    NodeKind.horizontalRule => 'Horizontal rule',
    NodeKind.image => 'Image',
    NodeKind.clickCount => 'Click count',
    NodeKind.definitionList => 'Definition list',
    NodeKind.svg => 'SVG',
    NodeKind.attachment => 'Attachment',
    NodeKind.video => 'Video',
    NodeKind.audio => 'Audio',
  };

  /// 根据 dirName 反查。未知值返回 null。
  static NodeKind? fromDirName(String dir) {
    for (final k in NodeKind.values) {
      if (k.dirName == dir) return k;
    }
    return null;
  }
}

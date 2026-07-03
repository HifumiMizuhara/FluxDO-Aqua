import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../providers/preferences_provider.dart';
import '../../../services/toast_service.dart';
import '../../../utils/fluxdo_render_callbacks.dart';
import '../../content/collapsed_html_content.dart';
import 'quote_selection_helper.dart';
import 'widgets/post_footer_section/post_footer_section.dart';
import 'widgets/post_header_section.dart';
import 'widgets/post_segment_frame.dart';

/// 新引擎长帖分段数据(chunk 切分 eager,单 chunk 解析 lazy)。
/// - [chunks]:对**预处理后** cooked 切的 chunk(含 emoji/click-count 注入)。
///   切分必须 eager —— segment 数量/scrollIndex 映射依赖 chunk 数。
/// - 单 chunk 的 `ParagraphParser.parse` 推迟到该 chunk 首次进入
///   sliver cacheExtent(itemBuilder 调 [parsedChunkAt])才执行并记忆化,
///   避免进话题/分页落地帧把所有 chunk 一次性解析完(此前的集中卡顿点)。
/// - [imageOffsetAt]:chunk 的图片 indexInPost 起始偏移(对齐整帖画廊/
///   heroTag)。有前缀依赖 —— 取第 k 块会顺序补齐 0..k-1 的解析。
/// - [footnotesHtml]:整帖脚注区源(正文 chunk 不含帖尾脚注区,需额外传)。
/// - [callbacks]:整帖共享的 FluxdoRenderCallbacks。画廊数据同样惰性:
///   首次点图时经 lightboxImageRunsProvider 触发全 chunk 解析后收集。
class NewEngineLongPostData {
  final List<HtmlChunk> chunks;
  final String? footnotesHtml;
  late final FluxdoRenderCallbacks callbacks;

  /// 懒解析状态:_parsed[i] 与 _offsets[i] 同步填充(前缀连续)。
  final ParagraphParser _parser;
  final List<List<BlockNode>?> _parsed;
  final List<int?> _offsets;

  NewEngineLongPostData._({
    required this.chunks,
    required this.footnotesHtml,
    required ParagraphParser parser,
  })  : _parser = parser,
        _parsed = List<List<BlockNode>?>.filled(chunks.length, null),
        _offsets = List<int?>.filled(chunks.length, null);

  /// 第 [index] 块的解析结果(未解析时顺序补齐前缀并缓存)。
  List<BlockNode> parsedChunkAt(int index) {
    _ensureParsedThrough(index);
    return _parsed[index]!;
  }

  /// 第 [index] 块的图片 indexInPost 起始偏移。
  int imageOffsetAt(int index) {
    _ensureParsedThrough(index);
    return _offsets[index]!;
  }

  /// 顺序解析 0..[index](offset 有前缀依赖)。已解析的块直接跳过,
  /// 单块只解析一次。从帖尾进入时会一次补齐前面的块 —— 单帖范围内可接受。
  void _ensureParsedThrough(int index) {
    for (var i = 0; i <= index; i++) {
      if (_parsed[i] != null) continue;
      final prevOffset = i == 0 ? 0 : _offsets[i - 1]!;
      final prevCount =
          i == 0 ? 0 : countImageRuns(_parsed[i - 1]!);
      final offset = prevOffset + prevCount;
      final nodes = _parser.parse(
        chunks[i].html,
        imageIndexStart: offset,
        footnotesHtml: footnotesHtml,
      );
      _parsed[i] = List.unmodifiable(nodes);
      _offsets[i] = offset;
    }
  }

  /// 全帖 lightbox 画廊项(触发全 chunk 解析)。仅在首次点图时被
  /// callbacks 的惰性画廊 resolver 调用。
  List<ImageRun> _collectAllLightboxImageRuns() {
    if (chunks.isEmpty) return const [];
    _ensureParsedThrough(chunks.length - 1);
    final runs = <ImageRun>[];
    for (final nodes in _parsed) {
      runs.addAll(collectLightboxImageRuns(nodes!));
    }
    return runs;
  }

  /// 长帖且可切多 chunk 时返回数据;否则 null(短帖走整段 PostItem)。
  static NewEngineLongPostData? tryBuild(
    Post post, {
    // 链接点击追踪 + 图片引用菜单引用上下文(透传给 forPost → imageContentBuilder
    // / linkHandler)。NewEngineLongPostData 本身无需新增字段(callbacks 闭包已捕获)。
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
  }) {
    final preprocessed = FluxdoRenderCallbacks.preprocessCookedForRender(post);
    if (preprocessed.length <= HtmlChunker.chunkThreshold) return null;
    // 先按顶层切,再把「大 blockquote」装饰下放拆成多片(让容器内部也跟随
    // sliver 虚拟化,见子包 BlockquoteChunkPos)。拆分后再判 chunk 数 → 单个
    // 超大引用块的帖子也能拆开,不会退回整段渲染。
    final chunks = _splitLargeBlockquotes(HtmlChunker.chunk(preprocessed));
    if (chunks.length <= 1) return null;

    final footnotesHtml = _extractFootnotesSection(preprocessed);
    final data = NewEngineLongPostData._(
      chunks: chunks,
      footnotesHtml: footnotesHtml,
      parser: ParagraphParser(),
    );
    data.callbacks = FluxdoRenderCallbacks.forPost(
      post: post,
      topicId: topicId,
      onQuoteImage: onQuoteImage,
      preprocessedCooked: preprocessed,
      // 画廊惰性:首次点图才收集(触发剩余 chunk 解析),构建时零解析成本
      lightboxImageRunsProvider: data._collectAllLightboxImageRuns,
    );
    return data;
  }

  // 大引用块拆分阈值:内部块数或字符数超过即拆(都不超 → 小引用块不拆,零开销)。
  static const _bqSplitMinBlocks = 6;
  static const _bqSplitMinChars = 1500;

  /// 把 chunk 列表里的「大 blockquote」装饰下放拆成多片,其余原样透传,最后重编 index。
  static List<HtmlChunk> _splitLargeBlockquotes(List<HtmlChunk> chunks) {
    final expanded = <HtmlChunk>[];
    for (final c in chunks) {
      if (c.type == HtmlChunkType.blockquote) {
        expanded.addAll(_splitBlockquoteChunk(c.html));
      } else {
        expanded.add(c);
      }
    }
    return [
      for (var i = 0; i < expanded.length; i++)
        HtmlChunk(
          html: expanded[i].html,
          type: expanded[i].type,
          index: i,
          joinsPrevious: expanded[i].joinsPrevious,
          joinsNext: expanded[i].joinsNext,
        ),
    ];
  }

  /// 把一个 `<blockquote>` chunk 拆成多片:每片 re-wrap 成
  /// `<blockquote ...原属性 data-fxd-pos="first|mid|last">子片</blockquote>`,
  /// 子包按 pos 渲染连续装饰。小引用块不拆。
  ///
  /// callout(`[!type]`):**不可折叠**的大 callout 也拆 —— 首片保留 `[!type]`
  /// 标记(子包走文本识别出标题头),中/尾片打 `data-fxd-callout` 属性(只 kind
  /// + body)。可折叠 callout 不拆(折叠态本就懒构建)。
  static List<HtmlChunk> _splitBlockquoteChunk(String html) {
    HtmlChunk whole() =>
        HtmlChunk(html: html, type: HtmlChunkType.blockquote, index: 0);
    final frag = html_parser.parseFragment(html);
    final root = frag.children.isNotEmpty ? frag.children.first : null;
    if (root == null || root.localName?.toLowerCase() != 'blockquote') {
      return [whole()];
    }

    // 太小不拆(零开销)。
    final smallByBlocks = root.children.length <= _bqSplitMinBlocks;
    final smallByChars = root.text.length <= _bqSplitMinChars;
    if (smallByBlocks && smallByChars) return [whole()];

    final sub = HtmlChunker.chunk(root.innerHtml);
    if (sub.length <= 1) return [whole()];

    final attrs = _attrsString(root); // 保留原 class 等属性

    // callout 识别:首行 [!type]([+-] = 可折叠 → 不拆)。
    final callout =
        RegExp(r'^\[!([^\]]+)\]([+-])?').firstMatch(root.text.trimLeft());
    if (callout != null) {
      if (callout.group(2) != null) return [whole()]; // 可折叠不拆
      final kind = callout.group(1)!.trim().toLowerCase();
      return [
        for (var i = 0; i < sub.length; i++)
          HtmlChunk(
            // 首片保留 [!type] 标记(在 sub[0] 内)→ 子包文本识别出标题头;
            // 中/尾片打属性 → 子包属性识别(只 kind + body,无头)。
            html: i == 0
                ? '<blockquote$attrs data-fxd-pos="${_pos(i, sub.length)}">'
                    '${sub[i].html}</blockquote>'
                : '<blockquote$attrs data-fxd-callout="$kind" '
                    'data-fxd-pos="${_pos(i, sub.length)}">'
                    '${sub[i].html}</blockquote>',
            type: HtmlChunkType.blockquote,
            index: i,
          ),
      ];
    }

    // 普通 blockquote。
    return [
      for (var i = 0; i < sub.length; i++)
        HtmlChunk(
          html: '<blockquote$attrs data-fxd-pos="${_pos(i, sub.length)}">'
              '${sub[i].html}</blockquote>',
          type: HtmlChunkType.blockquote,
          index: i,
        ),
    ];
  }

  static String _pos(int i, int n) =>
      i == 0 ? 'first' : (i == n - 1 ? 'last' : 'mid');

  /// 序列化元素原属性为 ` k="v"` 串(排除 data-fxd-pos,避免重复)。
  static String _attrsString(dom.Element el) {
    final buf = StringBuffer();
    el.attributes.forEach((k, v) {
      final key = k.toString();
      if (key == 'data-fxd-pos') return;
      buf.write(' $key="$v"');
    });
    return buf.toString();
  }

  /// 抽出整帖脚注区 `<section class="footnotes">…</section>`(无则 null)。
  static String? _extractFootnotesSection(String html) {
    final m = RegExp(
      r'<section[^>]*class="[^"]*footnotes[^"]*"[^>]*>[\s\S]*?</section>',
      caseSensitive: false,
    ).firstMatch(html);
    return m?.group(0);
  }
}

/// 新引擎长帖的单个 chunk 段:用 [FluxdoRender] 渲染 chunk.html。
/// 自带自研选区(chunk 内),图片/脚注靠 [imageIndexOffset]/[footnotesHtml]
/// + 共享 [callbacks] 对齐整帖。
class NewEngineChunkSegment extends StatelessWidget {
  final Post post;
  final int topicId;
  final bool selected;
  final bool highlight;
  final HtmlChunk chunk;
  final int chunkIndex;
  final int imageIndexOffset;
  final List<BlockNode> parsedNodes;
  final String? footnotesHtml;
  final FluxdoRenderCallbacks callbacks;
  final void Function(String plainText, Post post)? onQuoteSelection;

  const NewEngineChunkSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.selected,
    required this.highlight,
    required this.chunk,
    required this.chunkIndex,
    required this.imageIndexOffset,
    required this.parsedNodes,
    required this.footnotesHtml,
    required this.callbacks,
    required this.onQuoteSelection,
  });

  @override
  Widget build(BuildContext context) {
    return PostSegmentFrame(
      post: post,
      selected: selected,
      highlight: highlight,
      showBottomBorder: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: FluxdoRender(
          cookedHtml: chunk.html,
          parsedNodes: parsedNodes,
          imageIndexOffset: imageIndexOffset,
          footnotesHtml: footnotesHtml,
          // 同 post 各 chunk 共享一个选区作用域 → 选区可跨 chunk。
          selectionScopeId: post.id,
          // chunk 文档序号 → 跨 chunk 选区按 (chunkIndex, docOrder) 逻辑序排序。
          chunkIndex: chunkIndex,
          // 被分块切断的单段落接缝:裁掉接缝侧外边距 → 与连续渲染无缝拼接。
          trimTopMargin: chunk.joinsPrevious,
          trimBottomMargin: chunk.joinsNext,
          linkHandler: callbacks.linkHandler,
          emojiImageBuilder: callbacks.emojiImageBuilder,
          mentionTapHandler: callbacks.mentionTapHandler,
          imageContentBuilder: callbacks.imageContentBuilder,
          codeBlockHighlighter: callbacks.codeBlockHighlighter,
          quoteAvatarBuilder: callbacks.quoteAvatarBuilder,
          footnoteTapHandler: callbacks.footnoteTapHandler,
          lazyVideoBuilder: callbacks.lazyVideoBuilder,
          iframeBuilder: callbacks.iframeBuilder,
          localDateBuilder: callbacks.localDateBuilder,
          mathBlockBuilder: callbacks.mathBlockBuilder,
          mathInlineBuilder: callbacks.mathInlineBuilder,
          oneboxBuilder: callbacks.oneboxBuilder,
          imageGridBuilder: callbacks.imageGridBuilder,
          policyBuilder: callbacks.policyBuilder,
          pollBuilder: callbacks.pollBuilder,
          chatTranscriptBuilder: callbacks.chatTranscriptBuilder,
          svgBuilder: callbacks.svgBuilder,
          videoBuilder: callbacks.videoBuilder,
          audioBuilder: callbacks.audioBuilder,
          onDownloadAttachment: callbacks.onDownloadAttachment,
          // 自研选区恒开(外层系统 SelectionArea 已拆):未登录时
          // onQuoteRequest 为 null,toolbar 自动降级只留「复制/复制引用」。
          selectionEnabled: true,
          onQuoteRequest: onQuoteSelection == null
              ? null
              : (plainText) => onQuoteSelection!(plainText, post),
          onCopyQuoteRequest: (plainText) =>
              QuoteSelectionHelper.copyQuoteToClipboard(
            selectedText: plainText,
            post: post,
            topicId: topicId,
          ),
          onCopyToast: () =>
              ToastService.showSuccess(context.l10n.common_copiedToClipboard),
        ),
      ),
    );
  }
}

class LongPostHeaderSegment extends StatelessWidget {
  final Post post;
  final int topicId;
  final bool selected;
  final bool highlight;
  final bool isTopicOwner;
  final String? dateSeparatorLabel;
  final bool showDivider;
  final void Function(int postNumber)? onJumpToPost;

  /// 头像长按菜单「@用户」回调（null = 不可回复，菜单不显示该项）
  final void Function(String username)? onMentionUser;

  const LongPostHeaderSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.selected,
    required this.highlight,
    required this.isTopicOwner,
    required this.dateSeparatorLabel,
    required this.showDivider,
    required this.onJumpToPost,
    this.onMentionUser,
  });

  @override
  Widget build(BuildContext context) {
    return PostSegmentFrame(
      post: post,
      selected: selected,
      highlight: highlight,
      showTopDateSeparator: dateSeparatorLabel != null,
      topDateSeparatorLabel: dateSeparatorLabel,
      showDivider: showDivider,
      showBottomBorder: false,
      child: SelectionContainer.disabled(
        child: PostHeaderSection(
          post: post,
          topicId: topicId,
          isTopicOwner: isTopicOwner,
          showStamp: post.acceptedAnswer,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          onJumpToPost: onJumpToPost,
          onMentionUser: onMentionUser,
        ),
      ),
    );
  }
}

class LongPostFooterSegment extends ConsumerWidget {
  final Post post;
  final int topicId;
  final bool selected;
  final bool highlight;
  final bool topicHasAcceptedAnswer;
  final List<AcceptedAnswer> acceptedAnswers;
  final String? bottomDateSeparatorLabel;
  final void Function({String? initialContent})? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onShareAsImage;
  final void Function(int postId)? onRefreshPost;
  final void Function(int postNumber)? onJumpToPost;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final bool useReplyDialog;
  final String? topicTitle;
  final bool isPrivateMessageTopic;
  final bool isPmWithNonHumanUser;
  final VoidCallback? onShowPostDetail;
  final String? highlightBoostUsername;

  /// OP 帖专属插槽: 仅在 postNumber == 1 时透传给 PostFooterSection
  final Widget? opTopSlot;

  const LongPostFooterSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.selected,
    required this.highlight,
    this.highlightBoostUsername,
    required this.topicHasAcceptedAnswer,
    this.acceptedAnswers = const [],
    required this.bottomDateSeparatorLabel,
    required this.onReply,
    required this.onEdit,
    required this.onShareAsImage,
    required this.onRefreshPost,
    required this.onJumpToPost,
    required this.onSolutionChanged,
    this.useReplyDialog = false,
    this.topicTitle,
    this.isPrivateMessageTopic = false,
    this.isPmWithNonHumanUser = false,
    this.onShowPostDetail,
    this.opTopSlot,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final showSignatures = ref.watch(preferencesProvider).showSignatures;
    return PostSegmentFrame(
      post: post,
      selected: selected,
      highlight: highlight,
      showBottomDateSeparator: bottomDateSeparatorLabel != null,
      bottomDateSeparatorLabel: bottomDateSeparatorLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSignatures &&
              post.signatureCooked != null &&
              post.signatureCooked!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                padding: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.3,
                      ),
                      width: 0.5,
                    ),
                  ),
                ),
                child: CollapsedHtmlContent(
                  html: post.signatureCooked!,
                  textStyle: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                    fontSize: 12,
                    height: 1.4,
                  ),
                  maxLines: 2,
                ),
              ),
            ),
          SelectionContainer.disabled(
            child: PostFooterSection(
              post: post,
              topicId: topicId,
              topicHasAcceptedAnswer: topicHasAcceptedAnswer,
              acceptedAnswers: acceptedAnswers,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              highlightBoostUsername: highlightBoostUsername,
              onReply: onReply,
              onEdit: onEdit,
              onShareAsImage: onShareAsImage,
              onRefreshPost: onRefreshPost,
              onJumpToPost: onJumpToPost,
              onSolutionChanged: onSolutionChanged,
              useReplyDialog: useReplyDialog,
              topicTitle: topicTitle,
              isPrivateMessageTopic: isPrivateMessageTopic,
              isPmWithNonHumanUser: isPmWithNonHumanUser,
              onShowPostDetail: onShowPostDetail,
              opTopSlot: opTopSlot,
            ),
          ),
        ],
      ),
    );
  }
}

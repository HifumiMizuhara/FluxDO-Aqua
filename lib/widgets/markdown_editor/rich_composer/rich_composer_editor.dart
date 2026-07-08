/// 富文本 composer 编辑器 —— 自研 WYSIWYG 内核(fluxdo_render/editor)的
/// 主 app 宿主。实现 MarkdownEditor 的接口面,宿主页面(reply_sheet /
/// create_topic_page)按 feature flag 二选一渲染,其余逻辑零改动。
///
/// **controller 镜像策略**:TextEditingController 保持为对外真相源 ——
/// 编辑文档每次变更 debounce 序列化回写 controller.text,宿主的草稿保存
/// (监听 controller)/提交(controller.text → raw)/字数校验全部照旧。
/// 初始文本(草稿恢复)经 cook 链路导入;导入失败回调 onFallbackToPlain
/// 让宿主切回纯文本编辑器。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show EmojiRun, ImageRun, MentionRun, NodeFactory, ParagraphNode;
import 'package:image_picker/image_picker.dart';

import '../../../models/mention_user.dart';
import '../../../services/app_error_handler.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/discourse_cook_service.dart';
import '../../../services/emoji_handler.dart';
import '../../../utils/fluxdo_render_callbacks.dart';
import '../../content/discourse_html_content/image_utils.dart';
import '../../mention/mention_autocomplete.dart';
import '../emoji_sticker_panel.dart';
import '../image_upload_dialog.dart';
import '../link_insert_dialog.dart';
import 'composer_doc_codec.dart';

/// 孤岛渲染工厂:复用 generic callbacks 的全部 builder(emoji 缓存池/
/// 图片管线/代码高亮…),编辑器里的岛与阅读端视觉一致。
NodeFactory buildComposerNodeFactory(BuildContext context) {
  final callbacks = FluxdoRenderCallbacks.generic(
    heroTagNamespace: 'rich_composer',
  );
  return NodeFactory(
    emojiImageBuilder: callbacks.emojiImageBuilder,
    imageContentBuilder: callbacks.imageContentBuilder,
    codeBlockHighlighter: callbacks.codeBlockHighlighter,
    quoteAvatarBuilder: callbacks.quoteAvatarBuilder,
    oneboxBuilder: callbacks.oneboxBuilder,
    imageGridBuilder: callbacks.imageGridBuilder,
    localDateBuilder: callbacks.localDateBuilder,
    mathBlockBuilder: callbacks.mathBlockBuilder,
    mathInlineBuilder: callbacks.mathInlineBuilder,
    svgBuilder: callbacks.svgBuilder,
  );
}

class RichComposerEditor extends StatefulWidget {
  const RichComposerEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = '',
    this.emojiPanelHeight = 280.0,
    this.onEmojiPanelChanged,
    this.mentionDataSource,
    this.onFallbackToPlain,
  });

  /// 对外真相源镜像(宿主草稿/提交读它)。
  final TextEditingController controller;

  final FocusNode? focusNode;
  final String hintText;
  final double emojiPanelHeight;
  final ValueChanged<bool>? onEmojiPanelChanged;
  final MentionDataSource? mentionDataSource;

  /// 初始导入失败(cook 不可用/草稿含不可解析内容)时回调 —— 宿主应
  /// 切回纯文本 MarkdownEditor。
  final VoidCallback? onFallbackToPlain;

  @override
  State<RichComposerEditor> createState() => RichComposerEditorState();
}

class RichComposerEditorState extends State<RichComposerEditor> {
  EditorState? _editor;
  bool _importing = true;

  Timer? _serializeDebounce;

  bool _showEmojiPanel = false;
  final FocusNode _emojiBtnFocus =
      FocusNode(canRequestFocus: false, skipTraversal: true);
  // 功能条按钮全部不抢编辑器焦点(点完光标还在原处,插入直达光标)
  final FocusNode _imageBtnFocus =
      FocusNode(canRequestFocus: false, skipTraversal: true);
  final FocusNode _linkBtnFocus =
      FocusNode(canRequestFocus: false, skipTraversal: true);
  final FocusNode _insertBtnFocus =
      FocusNode(canRequestFocus: false, skipTraversal: true);

  // mention 补全状态
  final LayerLink _mentionLink = LayerLink();
  OverlayEntry? _mentionOverlay;
  List<MentionUser> _mentionCandidates = const [];
  String _mentionQuery = '';
  Timer? _mentionDebounce;

  /// 岛渲染工厂:initState 建一次(build 里每帧新建会让孤岛 didUpdateWidget
  /// 判定 factory 变化 → 代码块每次打字重新高亮)。
  NodeFactory? _nodeFactory;

  @override
  void initState() {
    super.initState();
    // 预热 cook 引擎:551K JS bundle 的同步 eval 挪到打开编辑器时,
    // 否则落在首次序列化触发预览 cook 的时刻 —— 表现为"打第一个字超卡"。
    DiscourseCookService().warmUp();
    if (kDebugMode) EditorImeClient.debugLogging = true;
    _importInitial();
  }

  Future<void> _importInitial() async {
    // 门禁导入:序列化回写 → 二次 cook 与原 raw 的 cook 对比,不等价
    // (不可序列化岛/语法缺口)→ 回调降级纯文本,防止编辑-提交毁帖。
    // 空文档/富 composer 自己存的草稿天然过门禁;唯一代价是打开时多一次
    // cook(warmUp 后毫秒级)。
    final doc = await markdownToDocGuarded(widget.controller.text);
    if (!mounted) return;
    if (doc == null) {
      widget.onFallbackToPlain?.call();
      return;
    }
    final editor = EditorState(blocks: doc);
    editor.addListener(_onDocChanged);
    setState(() {
      _editor = editor;
      _importing = false;
    });
  }

  @override
  void dispose() {
    // 镜像 debounce(800ms)窗口内的最后编辑先落盘到 controller ——
    // unmount 后序遍历,子先于宿主 dispose,此刻 controller 还活着、
    // 宿主的草稿监听也还挂着;不 flush 的话宿主 dispose 里的兜底草稿
    // 保存读到旧文本(丢最后一句话)。
    flushToController();
    _emojiBtnFocus.dispose();
    _imageBtnFocus.dispose();
    _linkBtnFocus.dispose();
    _insertBtnFocus.dispose();
    _serializeDebounce?.cancel();
    _mentionDebounce?.cancel();
    _removeMentionOverlay();
    _editor?.removeListener(_onDocChanged);
    _editor?.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------
  // doc → controller 镜像
  // -----------------------------------------------------------------

  bool _lastIsEmpty = true;

  void _onDocChanged() {
    // 只在「空 ↔ 非空」翻转时重建(hint 显隐依赖它);普通打字不 setState ——
    // FluxdoEditor 内部自己监听 state 重建,整个 composer 跟着每字全量
    // rebuild 是纯浪费(打字卡顿嫌疑之一)。
    final empty = _computeIsEmpty();
    if (empty != _lastIsEmpty && mounted) {
      setState(() => _lastIsEmpty = empty);
    }
    _serializeDebounce?.cancel();
    // 800ms:回写 controller 会触发宿主(字数/草稿监听)整页 setState,
    // 打字停顿后再做;草稿保存自身还有二级 debounce,不丢内容。
    _serializeDebounce = Timer(const Duration(milliseconds: 800), () {
      final editor = _editor;
      if (editor == null || !mounted) return;
      final sw = Stopwatch()..start();
      final raw = docToRaw(editor.blocks);
      if (raw == widget.controller.text) return;
      widget.controller.text = raw;
      if (kDebugMode && sw.elapsedMilliseconds > 8) {
        debugPrint('[RichComposer] serialize+mirror '
            '${sw.elapsedMilliseconds}ms (${raw.length} chars)');
      }
    });
    _updateMentionQuery();
  }

  bool _computeIsEmpty() {
    final editor = _editor;
    if (editor == null) return true;
    return editor.blocks.length == 1 &&
        editor.blocks.first is TextBlock &&
        (editor.blocks.first as TextBlock).content.length == 0;
  }

  /// 立即序列化(宿主提交前调用,确保 controller 是最新;镜像 debounce
  /// 窗口内提交也不丢内容)。
  void flushToController() {
    _serializeDebounce?.cancel();
    final editor = _editor;
    if (editor == null) return;
    final raw = docToRaw(editor.blocks);
    if (raw != widget.controller.text) {
      widget.controller.text = raw;
    }
  }

  // -----------------------------------------------------------------
  // mention 补全(监听光标前缀 @word)
  // -----------------------------------------------------------------

  void _updateMentionQuery() {
    final dataSource = widget.mentionDataSource;
    final editor = _editor;
    if (dataSource == null || editor == null) return;
    final sel = editor.selection;
    if (sel == null || !sel.isCollapsed) {
      _dismissMention();
      return;
    }
    final block = editor.textBlockById(sel.extent.blockId);
    if (block == null) {
      _dismissMention();
      return;
    }
    final before = block.content.text.substring(0, sel.extent.offset);
    final m = RegExp(r'@([\w_-]*)$').firstMatch(before);
    if (m == null) {
      _dismissMention();
      return;
    }
    final query = m.group(1)!;
    if (query == _mentionQuery && _mentionOverlay != null) return;
    _mentionQuery = query;
    _mentionDebounce?.cancel();
    _mentionDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      try {
        final result = await dataSource(query);
        if (!mounted || _mentionQuery != query) return;
        _mentionCandidates = result.users;
        if (_mentionCandidates.isEmpty) {
          _dismissMention();
        } else {
          _showMentionOverlay();
        }
      } catch (_) {
        _dismissMention();
      }
    });
  }

  void _showMentionOverlay() {
    _removeMentionOverlay();
    _mentionOverlay = OverlayEntry(
      builder: (context) => Positioned(
        width: 260,
        child: CompositedTransformFollower(
          link: _mentionLink,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomLeft,
          offset: const Offset(16, -8),
          followerAnchor: Alignment.bottomLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _mentionCandidates.length,
                itemBuilder: (context, i) {
                  final user = _mentionCandidates[i];
                  return ListTile(
                    dense: true,
                    title: Text('@${user.username}'),
                    subtitle: (user.name?.isNotEmpty ?? false)
                        ? Text(user.name!)
                        : null,
                    onTap: () => _insertMention(user),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_mentionOverlay!);
  }

  void _insertMention(MentionUser user) {
    final editor = _editor;
    if (editor == null) return;
    final sel = editor.selection;
    if (sel == null) return;
    final block = editor.textBlockById(sel.extent.blockId);
    if (block == null) return;
    final before = block.content.text.substring(0, sel.extent.offset);
    final m = RegExp(r'@([\w_-]*)$').firstMatch(before);
    if (m == null) return;
    // 删掉 @query 前缀,插入 mention 原子 + 空格
    editor.updateSelection(EditorSelection(
      base: EditorPosition(blockId: block.id, offset: m.start),
      extent: EditorPosition(blockId: block.id, offset: sel.extent.offset),
    ));
    editor.deleteSelection();
    editor.insertAtom(MentionRun(
      username: user.username,
      href: '/u/${user.username}',
    ));
    editor.insertText(' ');
    _dismissMention();
  }

  void _dismissMention() {
    _mentionQuery = '';
    _mentionDebounce?.cancel();
    _removeMentionOverlay();
  }

  void _removeMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
  }

  // -----------------------------------------------------------------
  // emoji / sticker / 上传 / 插入
  // -----------------------------------------------------------------

  void _toggleEmojiPanel() {
    setState(() => _showEmojiPanel = !_showEmojiPanel);
    widget.onEmojiPanelChanged?.call(_showEmojiPanel);
  }

  void _insertEmoji(String name) {
    final editor = _editor;
    if (editor == null) return;
    final url = EmojiHandler().getEmojiUrl(name);
    editor.insertAtom(EmojiRun(name: name, url: url));
  }

  /// 万能插入原语:markdown 片段 → cook 链路 → 富内容块,粘贴语义并入
  /// 光标处。所有"+"菜单项(表格/公式/details/…)与链接/图片全走这条 ——
  /// 插入面 = markdown 语法面,零专用代码。cook 失败静默降级纯文本。
  Future<void> insertMarkdownSnippet(String markdown) async {
    final editor = _editor;
    if (editor == null || markdown.isEmpty) return;
    // 从未聚焦过(选区 null)→ 落到文档末尾,插入不静默丢
    if (editor.selection == null) {
      final last = editor.blocks.last;
      editor.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: last.id, offset: last.selectionLength),
      ));
    }
    final fragment = await markdownToDoc(markdown);
    if (!mounted) return;
    if (fragment != null && fragment.isNotEmpty) {
      editor.pasteBlocks(fragment);
    } else {
      editor.pastePlainText(markdown);
    }
  }

  /// 上传图片(选图 → 确认框 → 上传 → 插图片岛;单图流程,多图循环单图)。
  Future<void> _pickAndUploadImages() async {
    try {
      final images = await ImagePicker().pickMultiImage();
      if (images.isEmpty || !mounted) return;
      for (final img in images) {
        if (!mounted) return;
        final confirmed = await showImageUploadDialog(
          context,
          imagePath: img.path,
          imageName: img.name,
        );
        if (confirmed == null) continue;
        setState(() => _uploadingCount++);
        try {
          final uploadResult =
              await DiscourseService().uploadImage(confirmed.path);
          // 预置 short_url → 完整 url 解析缓存(编辑器里的图立即可显)
          final url = uploadResult.url;
          if (url != null) {
            DiscourseImageUtils.seedUploadUrl(uploadResult.shortUrl, url);
          }
          if (!mounted) return;
          insertUploadedImage(
            shortUrl: uploadResult.shortUrl,
            alt: confirmed.originalName,
            width: uploadResult.width,
            height: uploadResult.height,
          );
        } finally {
          if (mounted) setState(() => _uploadingCount--);
        }
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  int _uploadingCount = 0;

  /// 插入链接(复用纯文本编辑器的对话框;产 `[text](url)` 走 cook)。
  Future<void> _insertLink() async {
    final result = await showLinkInsertDialog(context);
    if (result == null || !mounted) return;
    final text = result['text'] ?? '';
    final url = result['url'] ?? '';
    if (url.isEmpty) return;
    await insertMarkdownSnippet('[${text.isEmpty ? url : text}]($url)');
  }

  /// "+"插入菜单:每项 = 一段模板 markdown(经 cook 变成对应块类型)。
  /// 覆盖编辑白名单外的全部常用块 —— 验证任何类型不再需要手写语法。
  Future<void> _showInsertMenu() async {
    final entries = <(String, String, IconData)>[
      ('表格', '| 列 1 | 列 2 |\n|---|---|\n| 内容 | 内容 |', Icons.table_chart_outlined),
      ('代码块', '```dart\n// 代码\n```', Icons.code_rounded),
      ('公式块', r'$$' '\nE=mc^2\n' r'$$', Icons.functions_rounded),
      ('分隔线', '---', Icons.horizontal_rule_rounded),
      ('折叠详情', '[details="点开看"]\n折叠内容\n[/details]', Icons.expand_circle_down_outlined),
      ('剧透遮罩', '[spoiler]\n剧透内容\n[/spoiler]', Icons.blur_on_rounded),
      ('引用卡', '[quote]\n引用内容\n[/quote]', Icons.format_quote_rounded),
      ('日期时间', '[date=2026-12-31 time=20:00 timezone="Asia/Shanghai"]', Icons.event_rounded),
    ];

    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx + 8,
        origin.dy + box.size.height - 380,
        origin.dx + 300,
        origin.dy + box.size.height - 56,
      ),
      items: [
        for (final (label, md, icon) in entries)
          PopupMenuItem<String>(
            value: md,
            child: Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 10),
                Text(label),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '__custom__',
          child: Row(
            children: const [
              Icon(Icons.data_object_rounded, size: 18),
              SizedBox(width: 10),
              Text('Markdown 片段…'),
            ],
          ),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    if (selected == '__custom__') {
      await _insertCustomMarkdown();
    } else {
      await insertMarkdownSnippet(selected);
    }
  }

  /// 自由 markdown 输入(兜底:poll/policy/iframe 等任意语法都能进来,
  /// 走 cook 后所见即所得 —— 相当于局部源码模式)。
  Future<void> _insertCustomMarkdown() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('插入 Markdown 片段'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: '任意 Discourse markdown/bbcode…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('插入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty || !mounted) return;
    await insertMarkdownSnippet(text);
  }

  /// 上传完成后插入图片岛(短链 + 尺寸;渲染层 data-orig-src 异步解析)。
  void insertUploadedImage({
    required String shortUrl,
    String alt = '',
    int? width,
    int? height,
  }) {
    final editor = _editor;
    if (editor == null) return;
    final sel = editor.selection;
    final anchorId = sel?.extent.blockId ?? editor.blocks.last.id;
    editor.insertIslandAfter(
      anchorId,
      ParagraphNode(id: 'b_up_${DateTime.now().microsecondsSinceEpoch}',
          inlines: [
            ImageRun(
              src: shortUrl,
              alt: alt,
              width: width?.toDouble(),
              height: height?.toDouble(),
            ),
          ]),
    );
  }

  // -----------------------------------------------------------------
  // build
  // -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    if (_importing || editor == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final isEmpty = _lastIsEmpty = _computeIsEmpty();

    return Column(
      children: [
        EditorToolbar(state: editor),
        const Divider(height: 1),
        Expanded(
          child: CompositedTransformTarget(
            link: _mentionLink,
            child: Stack(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: FluxdoEditor(
                    state: editor,
                    autofocus: true,
                    nodeFactory: _nodeFactory ??=
                        buildComposerNodeFactory(context),
                    // 粘贴导入:剪贴板 markdown → cook 链路 → 编辑块
                    // (失败/不可用时 FluxdoEditor 内部降级纯文本粘贴)
                    markdownImporter: markdownToDoc,
                    baseTextStyle: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(height: 1.5),
                  ),
                ),
                if (isEmpty)
                  Positioned(
                    left: 12,
                    // 12(scroll padding) + 4(块 vertical padding) 与首行文字同源
                    top: 16,
                    child: IgnorePointer(
                      child: Text(
                        widget.hintText,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              height: 1.5,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 底部功能条:emoji / 图片上传 / 链接 / 块插入菜单
        Row(
          children: [
            IconButton(
              tooltip: '表情',
              icon: Icon(
                _showEmojiPanel
                    ? Icons.keyboard_alt_outlined
                    : Icons.emoji_emotions_outlined,
              ),
              focusNode: _emojiBtnFocus,
              onPressed: _toggleEmojiPanel,
            ),
            IconButton(
              tooltip: '上传图片',
              icon: const Icon(Icons.image_outlined),
              focusNode: _imageBtnFocus,
              onPressed: _uploadingCount > 0 ? null : _pickAndUploadImages,
            ),
            IconButton(
              tooltip: '插入链接',
              icon: const Icon(Icons.link_rounded),
              focusNode: _linkBtnFocus,
              onPressed: _insertLink,
            ),
            IconButton(
              tooltip: '插入块(表格/代码/公式…)',
              icon: const Icon(Icons.add_box_outlined),
              focusNode: _insertBtnFocus,
              onPressed: _showInsertMenu,
            ),
            if (_uploadingCount > 0) ...[
              const SizedBox(width: 4),
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 6),
              Text('上传中…',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
        if (_showEmojiPanel)
          SizedBox(
            height: widget.emojiPanelHeight,
            child: EmojiStickerPanel(
              onEmojiSelected: (emoji) => _insertEmoji(emoji.name),
              onStickerSelected: (markdown) {
                // sticker 是 markdown 图片:解析 src 插图片岛
                final m = RegExp(r'!\[([^\]|]*)(?:\|(\d+)x(\d+))?\]\(([^)]+)\)')
                    .firstMatch(markdown);
                if (m != null) {
                  insertUploadedImage(
                    shortUrl: m.group(4)!,
                    alt: m.group(1) ?? '',
                    width: int.tryParse(m.group(2) ?? ''),
                    height: int.tryParse(m.group(3) ?? ''),
                  );
                }
              },
            ),
          ),
      ],
    );
  }
}

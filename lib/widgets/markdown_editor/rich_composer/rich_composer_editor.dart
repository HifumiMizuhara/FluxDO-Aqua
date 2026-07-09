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
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart'
    show
        EmojiRun,
        ImageRun,
        InlineNode,
        LocalDateRun,
        MentionRun,
        NodeFactory,
        ParagraphNode;
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../../../models/mention_user.dart';
import '../../../services/app_error_handler.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/discourse_cook_service.dart';
import '../../../services/emoji_handler.dart';
import '../../../utils/dialog_utils.dart';
import '../../../utils/fluxdo_render_callbacks.dart';
import '../../common/fading_edge_scroll_view.dart';
import '../../content/discourse_html_content/image_utils.dart';
import '../../mention/mention_autocomplete.dart';
import '../emoji_sticker_panel.dart';
import '../image_upload_dialog.dart';
import '../link_insert_dialog.dart';
import 'composer_doc_codec.dart';
import 'local_date_edit_dialog.dart';

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
    this.onSwitchToSource,
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

  /// 用户主动点"源码模式"按钮。调用前编辑器已 flushToController
  /// (controller.text 即最新 markdown),宿主直接换 MarkdownEditor
  /// 即可,内容无缝衔接。null 时不显示切换按钮。
  final VoidCallback? onSwitchToSource;

  @override
  State<RichComposerEditor> createState() => RichComposerEditorState();
}

class RichComposerEditorState extends State<RichComposerEditor> {
  EditorState? _editor;
  bool _importing = true;

  Timer? _serializeDebounce;

  bool _showEmojiPanel = false;

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
    _serializeDebounce?.cancel();
    _mentionDebounce?.cancel();
    _removeMentionOverlay();
    _removeSlashOverlay();
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
    _updateSlashQuery();
  }

  bool _computeIsEmpty() {
    final editor = _editor;
    if (editor == null) return true;
    if (editor.blocks.length != 1) return false;
    final b = editor.blocks.first;
    if (b is! TextBlock) return false;
    // 空文档判定含块类型:'- ' 转成空列表项/'# ' 转成空标题/包了容器
    // 都不算空 —— 否则 hint 与列表圆点/标题光标叠画(实测截图)。
    return b.content.length == 0 &&
        b.isParagraph &&
        b.containers.isEmpty;
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
  // 斜杠菜单(段首 `/` 唤起块插入 —— 类 Notion)
  // -----------------------------------------------------------------

  OverlayEntry? _slashOverlay;
  String? _slashQuery;
  int _slashSelected = 0;

  /// 光标全局矩形(FluxdoEditor 帧后上抛;斜杠/mention 浮层锚定用)。
  Rect? _caretGlobalRect;

  /// 浮层按键拦截(编辑器 onKeyEvent 首先调):斜杠菜单激活时接管
  /// 上下/回车/Tab/Esc。
  bool _interceptKeyEvent(KeyEvent event) {
    if (_slashOverlay == null) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final items = _slashFiltered;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _slashSelected = (_slashSelected + 1) % items.length;
        _slashOverlay!.markNeedsBuild();
        return true;
      case LogicalKeyboardKey.arrowUp:
        _slashSelected = (_slashSelected - 1 + items.length) % items.length;
        _slashOverlay!.markNeedsBuild();
        return true;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.tab:
        if (_slashSelected < items.length) {
          _runSlashAction(items[_slashSelected].$4);
        }
        return true;
      case LogicalKeyboardKey.escape:
        _dismissSlash();
        return true;
    }
    return false;
  }

  /// 候选:(关键字集, 标签, 图标, 动作)。关键字含中文与英文别名。
  late final List<(List<String>, String, IconData, Future<void> Function())>
      _slashItems = [
    (['h1', 'heading', '标题', 'bt'], '标题 1', Icons.title_rounded,
        () async => _applySlashBlock((s) => s.setHeading(1))),
    (['h2', '标题2'], '标题 2', Icons.title_rounded,
        () async => _applySlashBlock((s) => s.setHeading(2))),
    (['h3', '标题3'], '标题 3', Icons.title_rounded,
        () async => _applySlashBlock((s) => s.setHeading(3))),
    (['ul', 'list', '列表', 'lb', 'wxlb'], '无序列表',
        Icons.format_list_bulleted_rounded,
        () async => _applySlashBlock((s) => s.toggleList(ordered: false))),
    (['ol', '有序', 'yxlb'], '有序列表', Icons.format_list_numbered_rounded,
        () async => _applySlashBlock((s) => s.toggleList(ordered: true))),
    (['quote', '引用', 'yy'], '引用', Icons.format_quote_rounded,
        () async => _applySlashBlock((s) => s.toggleQuote())),
    (['table', '表格', 'bg'], '表格', Icons.table_chart_outlined,
        () async => insertMarkdownSnippet(
            '| 列 1 | 列 2 |\n|---|---|\n| 内容 | 内容 |')),
    (['code', '代码', 'dm'], '代码块', Icons.code_rounded,
        () async => insertMarkdownSnippet('```dart\n// 代码\n```')),
    (['math', '公式', 'gs'], '公式块', Icons.functions_rounded,
        () async => insertMarkdownSnippet(r'$$' '\nE=mc^2\n' r'$$')),
    (['hr', 'divider', '分隔', 'fgx'], '分隔线', Icons.horizontal_rule_rounded,
        () async => insertMarkdownSnippet('---')),
    (['details', '折叠', 'zd'], '折叠详情', Icons.expand_circle_down_outlined,
        () async =>
            insertMarkdownSnippet('[details="点开看"]\n折叠内容\n[/details]')),
    (['spoiler', '剧透', 'jt'], '剧透遮罩', Icons.blur_on_rounded,
        () async => insertMarkdownSnippet('[spoiler]\n剧透内容\n[/spoiler]')),
    (['date', '日期', '时间', 'rq', 'sj'], '日期时间', Icons.event_rounded,
        () async => _insertLocalDate()),
    (['image', '图片', 'tp'], '上传图片', Icons.image_outlined,
        () async => _pickAndUploadImages()),
  ];

  List<(List<String>, String, IconData, Future<void> Function())>
      get _slashFiltered {
    final q = (_slashQuery ?? '').toLowerCase();
    if (q.isEmpty) return _slashItems;
    return [
      for (final item in _slashItems)
        if (item.$1.any((k) => k.contains(q)) || item.$2.contains(q)) item,
    ];
  }

  /// 光标前缀 = 段首 `/query` → 弹菜单(块级插入语义只在段首,行中的
  /// `/` 是普通字符 —— Notion 同款)。
  void _updateSlashQuery() {
    final editor = _editor;
    if (editor == null) return;
    final sel = editor.selection;
    if (sel == null || !sel.isCollapsed) {
      _dismissSlash();
      return;
    }
    final block = editor.textBlockById(sel.extent.blockId);
    if (block == null || editor.hasComposing) {
      _dismissSlash();
      return;
    }
    final before = block.content.text.substring(0, sel.extent.offset);
    final m = RegExp(r'^/([\w一-鿿]*)$').firstMatch(before);
    if (m == null) {
      _dismissSlash();
      return;
    }
    final query = m.group(1)!;
    if (query == _slashQuery && _slashOverlay != null) {
      _slashOverlay!.markNeedsBuild();
      return;
    }
    _slashQuery = query;
    _slashSelected = 0; // 过滤集变了,选中项重置到首个
    if (_slashFiltered.isEmpty) {
      _dismissSlash();
      return;
    }
    if (_slashOverlay == null) {
      _showSlashOverlay();
    } else {
      _slashOverlay!.markNeedsBuild();
    }
  }

  void _showSlashOverlay() {
    _removeSlashOverlay();
    _slashSelected = 0;
    _slashOverlay = OverlayEntry(
      builder: (context) {
        // 锚定光标(全局矩形):默认弹光标下方;近屏幕底翻到上方。
        final caret = _caretGlobalRect;
        final screen = MediaQuery.sizeOf(context);
        const menuWidth = 240.0;
        const menuMaxHeight = 280.0;
        double left;
        double? top;
        double? bottom;
        if (caret != null) {
          left = caret.left.clamp(8.0, screen.width - menuWidth - 8);
          final below = screen.height - caret.bottom;
          if (below >= menuMaxHeight + 16) {
            top = caret.bottom + 4;
          } else {
            bottom = screen.height - caret.top + 4;
          }
        } else {
          left = 16;
          bottom = 80;
        }
        final items = _slashFiltered;
        if (_slashSelected >= items.length) _slashSelected = 0;
        return Positioned(
          left: left,
          top: top,
          bottom: bottom,
          width: menuWidth,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: menuMaxHeight),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final (_, label, icon, action) = items[i];
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    selected: i == _slashSelected,
                    selectedTileColor: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.1),
                    leading: Icon(icon, size: 18),
                    title: Text(label, style: const TextStyle(fontSize: 13)),
                    onTap: () => _runSlashAction(action),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_slashOverlay!);
  }

  /// 执行候选:先删 `/query` 前缀,再跑动作。
  Future<void> _runSlashAction(Future<void> Function() action) async {
    final editor = _editor;
    _dismissSlash();
    if (editor == null) return;
    final sel = editor.selection;
    if (sel != null && sel.isCollapsed) {
      final block = editor.textBlockById(sel.extent.blockId);
      if (block != null) {
        final before = block.content.text.substring(0, sel.extent.offset);
        final m = RegExp(r'^/[\w一-鿿]*$').firstMatch(before);
        if (m != null) {
          editor.updateSelection(EditorSelection(
            base: EditorPosition(blockId: block.id, offset: 0),
            extent:
                EditorPosition(blockId: block.id, offset: sel.extent.offset),
          ));
          editor.deleteSelection();
        }
      }
    }
    await action();
  }

  /// 块属性类候选(标题/列表/引用):直接对当前块执行命令。
  Future<void> _applySlashBlock(void Function(EditorState) command) async {
    final editor = _editor;
    if (editor == null) return;
    command(editor);
  }

  void _dismissSlash() {
    _slashQuery = null;
    _removeSlashOverlay();
  }

  void _removeSlashOverlay() {
    _slashOverlay?.remove();
    _slashOverlay = null;
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
      builder: (context) {
        // 锚定光标(斜杠菜单同款):下方优先,近底翻上方
        final caret = _caretGlobalRect;
        final screen = MediaQuery.sizeOf(context);
        const menuWidth = 260.0;
        const menuMaxHeight = 220.0;
        double left;
        double? top;
        double? bottom;
        if (caret != null) {
          left = caret.left.clamp(8.0, screen.width - menuWidth - 8);
          if (screen.height - caret.bottom >= menuMaxHeight + 16) {
            top = caret.bottom + 4;
          } else {
            bottom = screen.height - caret.top + 4;
          }
        } else {
          left = 16;
          bottom = 80;
        }
        return Positioned(
          left: left,
          top: top,
          bottom: bottom,
          width: menuWidth,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: menuMaxHeight),
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
        );
      },
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
  /// 插入面 = markdown 语法面,零专用代码。cook 失败/超时降级纯文本。
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
    final sw = kDebugMode ? (Stopwatch()..start()) : null;
    final fragment = await markdownToDoc(markdown);
    if (!mounted) return;
    final before = editor.blocks.length;
    if (fragment != null && fragment.isNotEmpty) {
      editor.pasteBlocks(fragment);
    } else {
      editor.pastePlainText(markdown);
    }
    if (kDebugMode) {
      debugPrint('[RichComposer] insert "${markdown.split('\n').first}" '
          'cook=${sw!.elapsedMilliseconds}ms frag=${fragment?.length} '
          'blocks $before→${editor.blocks.length} sel=${editor.selection}');
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

  /// 插入/施加链接:选区非空 → 对选中文字加 link mark(文字保留);
  /// 折叠 → 对话框输入文字+URL 后插入(经 cook)。
  Future<void> _insertLink() async {
    final editor = _editor;
    if (editor == null) return;
    final sel = editor.selection;
    final hasRange = sel != null && !sel.isCollapsed && sel.isSingleBlock;

    final result = await showLinkInsertDialog(context);
    if (result == null || !mounted) return;
    final text = result['text'] ?? '';
    final url = result['url'] ?? '';
    if (url.isEmpty) return;

    if (hasRange && editor.selection == sel) {
      editor.applyLink(url);
      return;
    }
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
        // 日期时间:弹属性对话框选时间再插原子(不再是死模板)
        PopupMenuItem<String>(
          value: '__date__',
          child: Row(
            children: const [
              Icon(Icons.event_rounded, size: 18),
              SizedBox(width: 10),
              Text('日期时间'),
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
    } else if (selected == '__date__') {
      await _insertLocalDate();
    } else {
      await insertMarkdownSnippet(selected);
    }
  }

  /// 插入日期时间:属性对话框 → date 原子插入光标处(行内语义,
  /// 对齐官方 composer 的 modal 插入)。
  Future<void> _insertLocalDate() async {
    final editor = _editor;
    if (editor == null) return;
    final run = await showLocalDateEditDialog(context);
    if (run == null || !mounted) return;
    if (editor.selection == null) {
      final last = editor.blocks.last;
      editor.updateSelection(EditorSelection.collapsed(
        EditorPosition(blockId: last.id, offset: last.selectionLength),
      ));
    }
    editor.insertAtom(run);
  }

  /// 自由 markdown 输入(兜底:poll/policy/iframe 等任意语法都能进来,
  /// 走 cook 后所见即所得 —— 相当于局部源码模式)。
  Future<void> _insertCustomMarkdown() async {
    final text = await _showMarkdownDialog(
      title: '插入 Markdown 片段',
      confirmLabel: '插入',
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    await insertMarkdownSnippet(text);
  }

  /// 岛源码编辑:双击岛 → 对话框(初值 = 岛的 markdown)→ 确认后重
  /// cook 替换。一次覆盖所有岛类型 —— 岛内 WYSIWYG 前的通用编辑通道。
  /// 清空 = 删岛。(表格不走这:cell 原位编辑见 [_onTableEdited]。)
  Future<void> _editIsland(IslandBlock island) async {
    final editor = _editor;
    if (editor == null) return;

    final source = serializeIslandNode(island.node);
    final text = await _showMarkdownDialog(
      title: '编辑源码',
      confirmLabel: '应用',
      initialText: source,
    );
    if (text == null || !mounted) return;
    if (text.trim().isEmpty) {
      editor.replaceIsland(island.id, const []);
      return;
    }
    if (text == source) return; // 没改
    final fragment = await markdownToDoc(text);
    if (!mounted) return;
    if (fragment == null) {
      // cook 不可用:不动原岛(比替换成纯文本更安全)
      return;
    }
    editor.replaceIsland(island.id, fragment);
  }

  /// 表格 cell 原位编辑确认:新表格 markdown → cook → 替换岛。
  Future<void> _onTableEdited(IslandBlock island, String markdown) async {
    final editor = _editor;
    if (editor == null) return;
    final fragment = await markdownToDoc(markdown);
    if (!mounted || fragment == null || fragment.isEmpty) return;
    editor.replaceIsland(island.id, fragment);
  }

  /// 单击可编辑原子:date chip → 属性对话框 → replaceAtomAt。
  Future<void> _onAtomTap(String blockId, int offset, InlineNode atom) async {
    final editor = _editor;
    if (editor == null || atom is! LocalDateRun) return;
    final next = await showLocalDateEditDialog(context, initial: atom);
    if (next == null || !mounted) return;
    editor.replaceAtomAt(blockId, offset, next);
  }

  /// 点 details/callout 壳标题 → 弹单行输入改标题(groupId 不变,壳
  /// Element 复用,只有属性变;undo 一步)。
  Future<void> _editContainerTitle(ContainerFrame frame) async {
    final editor = _editor;
    if (editor == null) return;
    final current = switch (frame) {
      DetailsFrame(:final summary) => summary,
      CalloutFrame(:final title) => title ?? '',
      _ => null,
    };
    if (current == null) return;

    final text = await showAppDialog<String>(
      context: context,
      builder: (ctx) => _SingleLineInputDialog(
        title: frame is DetailsFrame ? '折叠标题' : '标注标题',
        initialText: current,
      ),
    );
    if (text == null || text == current || !mounted) return;

    final newFrame = switch (frame) {
      DetailsFrame(:final groupId, :final open) =>
        DetailsFrame(groupId: groupId, summary: text, open: open),
      CalloutFrame(
        :final groupId,
        :final kind,
        :final typeRaw,
        :final foldable,
      ) =>
        CalloutFrame(
          groupId: groupId,
          kind: kind,
          typeRaw: typeRaw,
          title: text.isEmpty ? null : text,
          foldable: foldable,
        ),
      _ => null,
    };
    if (newFrame != null) {
      editor.updateContainerFrame(frame.groupId, newFrame);
    }
  }

  /// markdown 多行输入对话框(插入片段/岛编辑共用;showAppDialog 统一
  /// app 弹窗风格)。
  Future<String?> _showMarkdownDialog({
    required String title,
    required String confirmLabel,
    String? initialText,
  }) {
    // controller 必须归对话框 State 所有(LinkInsertDialog 同款):
    // pop 后 future 立即 resolve,但退场动画还在播,外部立刻 dispose
    // 会让动画帧里的 TextField 摸已析构 controller(真机崩溃实锤,
    // 并连带触发 Element 半更新 → _dependents 断言红屏)。
    return showAppDialog<String>(
      context: context,
      builder: (ctx) => _MarkdownInputDialog(
        title: title,
        confirmLabel: confirmLabel,
        initialText: initialText,
      ),
    );
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
                    // 双击岛 → 源码编辑对话框
                    onIslandEditRequest: _editIsland,
                    // 点 details/callout 壳标题 → 原位改标题
                    onContainerTitleEdit: _editContainerTitle,
                    // 表格 cell 原位编辑 → 重建 markdown 经 cook 替换
                    onTableEdited: _onTableEdited,
                    // 单击 date chip → 属性编辑对话框
                    onAtomTap: _onAtomTap,
                    // 光标全局矩形上抛(斜杠/mention 浮层锚定用)
                    onCaretRectChanged: (r) => _caretGlobalRect = r,
                    // 浮层激活时接管上下/回车/Esc(否则被编辑器拿去移光标)
                    keyEventInterceptor: _interceptKeyEvent,
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
        // 单一底部工具栏(与 MarkdownToolbar 同构:左表情胶囊 + 中部
        // 可滚工具 + 右胶囊;FaIcon 图标语言 + compact 密度)
        _RichToolbar(
          state: editor,
          isEmojiPanelVisible: _showEmojiPanel,
          onToggleEmoji: _toggleEmojiPanel,
          uploading: _uploadingCount > 0,
          onPickImage: _pickAndUploadImages,
          onInsertLink: _insertLink,
          onInsertMenu: _showInsertMenu,
          onSwitchToSource: widget.onSwitchToSource == null
              ? null
              : () {
                  // 先落盘再切换:controller.text 即最新 markdown,
                  // 宿主换 MarkdownEditor 后内容无缝衔接
                  flushToController();
                  widget.onSwitchToSource!();
                },
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

/// 富 composer 的统一底部工具栏。
///
/// 视觉与 [MarkdownToolbar] 完全同构:左右胶囊(圆角 22 +
/// surfaceContainerHighest 0.45)+ 中部渐隐可滚工具排 + FaIcon 16 +
/// onSurfaceVariant/primary 双态 + compact 密度。区别只在命令目标:
/// 纯文本改 controller.text,这里调 EditorState 命令。
///
/// 激活态签名驱动重建(EditorToolbar 同款):纯打字签名不变零重建。
class _RichToolbar extends StatefulWidget {
  const _RichToolbar({
    required this.state,
    required this.isEmojiPanelVisible,
    required this.onToggleEmoji,
    required this.uploading,
    required this.onPickImage,
    required this.onInsertLink,
    required this.onInsertMenu,
    this.onSwitchToSource,
  });

  final EditorState state;
  final bool isEmojiPanelVisible;
  final VoidCallback onToggleEmoji;
  final bool uploading;
  final VoidCallback onPickImage;
  final VoidCallback onInsertLink;
  final VoidCallback onInsertMenu;
  final VoidCallback? onSwitchToSource;

  @override
  State<_RichToolbar> createState() => _RichToolbarState();
}

typedef _Sig = ({int marksBits, int kindIndex, int headingLevel, bool ordered, bool inQuote});

class _RichToolbarState extends State<_RichToolbar> {
  late _Sig _sig = _compute();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void didUpdateWidget(covariant _RichToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onState);
      widget.state.addListener(_onState);
      _sig = _compute();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final next = _compute();
    if (next != _sig && mounted) {
      setState(() => _sig = next);
    }
  }

  _Sig _compute() {
    final state = widget.state;
    final marks = state.effectiveMarksAtCaret();
    final sel = state.selection;
    final block = sel == null ? null : state.textBlockById(sel.extent.blockId);
    return (
      marksBits: marks.fold(0, (a, k) => a | (1 << k.index)),
      kindIndex: block?.kind.index ?? -1,
      headingLevel: block?.isHeading == true ? block!.headingLevel : 0,
      ordered: block?.isListItem == true && block!.ordered,
      inQuote: (block?.quoteDepth ?? 0) > 0,
    );
  }

  bool _hasMark(MarkKind kind) => (_sig.marksBits & (1 << kind.index)) != 0;

  /// 行内剧透:有选区 → toggle mark;折叠光标 → 插占位文字并整选
  /// (官方 rich editor inputRule 同款:立即可打字覆盖占位)。
  void _toggleInlineSpoiler() {
    final state = widget.state;
    final sel = state.selection;
    if (sel != null && !sel.isCollapsed) {
      state.toggleMark(MarkKind.spoilerInline);
      return;
    }
    if (sel == null) return;
    final block = state.textBlockById(sel.extent.blockId);
    if (block == null) return;
    const placeholder = '剧透内容';
    final start = sel.extent.offset;
    state.insertText(placeholder);
    // 选中占位并施加 mark(选区保留 —— 用户直接打字即替换)
    state.updateSelection(EditorSelection(
      base: EditorPosition(blockId: block.id, offset: start),
      extent: EditorPosition(
          blockId: block.id, offset: start + placeholder.length),
    ));
    state.toggleMark(MarkKind.spoilerInline);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.state;
    final pillColor =
        theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45);
    final isListItem = _sig.kindIndex == TextBlockKind.listItem.index;

    return Container(
      color: theme.colorScheme.surface,
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Row(
            children: [
              // 左:表情按钮(胶囊背景,固定)
              _Pill(
                color: pillColor,
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: FaIcon(
                    widget.isEmojiPanelVisible
                        ? FontAwesomeIcons.keyboard
                        : FontAwesomeIcons.faceSmile,
                    size: 20,
                    color: widget.isEmojiPanelVisible
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: widget.onToggleEmoji,
                ),
              ),
              // 中:格式/插入工具(可滚动,无背景)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: FadingEdgeScrollView(
                    fadeLeft: true,
                    fadeRight: true,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        _btn(FontAwesomeIcons.bold, '粗体 (Cmd+B)',
                            active: _hasMark(MarkKind.strong),
                            onTap: () => state.toggleMark(MarkKind.strong)),
                        _btn(FontAwesomeIcons.italic, '斜体 (Cmd+I)',
                            active: _hasMark(MarkKind.em),
                            onTap: () => state.toggleMark(MarkKind.em)),
                        _btn(FontAwesomeIcons.strikethrough,
                            '删除线 (Cmd+Shift+X)',
                            active: _hasMark(MarkKind.lineThrough),
                            onTap: () =>
                                state.toggleMark(MarkKind.lineThrough)),
                        _btn(FontAwesomeIcons.code, '行内代码 (Cmd+E)',
                            active: _hasMark(MarkKind.inlineCode),
                            onTap: () =>
                                state.toggleMark(MarkKind.inlineCode)),
                        _btn(FontAwesomeIcons.eyeSlash, '行内剧透',
                            active: _hasMark(MarkKind.spoilerInline),
                            onTap: _toggleInlineSpoiler),
                        _headingBtn(theme),
                        _btn(FontAwesomeIcons.listUl, '无序列表',
                            active: isListItem && !_sig.ordered,
                            onTap: () => state.toggleList(ordered: false)),
                        _btn(FontAwesomeIcons.listOl, '有序列表',
                            active: isListItem && _sig.ordered,
                            onTap: () => state.toggleList(ordered: true)),
                        _btn(FontAwesomeIcons.quoteRight, '引用',
                            active: _sig.inQuote, onTap: state.toggleQuote),
                        _btn(FontAwesomeIcons.link, '插入链接',
                            onTap: widget.onInsertLink),
                        widget.uploading
                            ? const Padding(
                                padding:
                                    EdgeInsets.symmetric(horizontal: 12),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              )
                            : _btn(FontAwesomeIcons.image, '上传图片',
                                onTap: widget.onPickImage),
                        _btn(FontAwesomeIcons.circlePlus,
                            '插入块(表格/代码/公式…)',
                            onTap: widget.onInsertMenu),
                      ]),
                    ),
                  ),
                ),
              ),
              // 右:源码模式(胶囊背景)
              if (widget.onSwitchToSource != null)
                _Pill(
                  color: pillColor,
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Symbols.code_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: widget.onSwitchToSource,
                    tooltip: '源码模式',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标准工具按钮(MarkdownToolbar._ToolbarButton 同参:FaIcon 16 +
  /// compact + onSurfaceVariant;激活态 primary)。
  Widget _btn(FaIconData icon, String tooltip,
      {bool active = false, required VoidCallback onTap}) {
    final theme = Theme.of(context);
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: FaIcon(icon, size: 16),
      onPressed: onTap,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: active
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
        backgroundColor: active
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : null,
      ),
    );
  }

  /// 标题按钮:弹菜单选 H1-H3/正文(纯文本工具栏单 heading 按钮的
  /// 富文本版 —— 块级命令需要明确级别)。
  Widget _headingBtn(ThemeData theme) {
    final active = _sig.headingLevel > 0;
    return PopupMenuButton<int>(
      tooltip: '标题',
      position: PopupMenuPosition.over,
      itemBuilder: (context) => [
        for (final level in [1, 2, 3])
          PopupMenuItem(
            value: level,
            child: Text('标题 $level',
                style: TextStyle(
                  fontSize: 18.0 - level * 1.5,
                  fontWeight: FontWeight.w600,
                )),
          ),
        const PopupMenuItem(value: 0, child: Text('正文')),
      ],
      onSelected: (level) =>
          widget.state.setHeading(level == 0 ? null : level),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: active
            ? Text('H${_sig.headingLevel}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ))
            : FaIcon(FontAwesomeIcons.heading,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// 工具栏两侧的胶囊背景容器(MarkdownToolbar._ToolbarPill 同款)。
class _Pill extends StatelessWidget {
  const _Pill({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.all(2),
      child: child,
    );
  }
}

/// markdown 多行输入对话框(controller 归本 State 所有 —— 退场动画期
/// 仍存活,dispose 时机正确)。
class _MarkdownInputDialog extends StatefulWidget {
  const _MarkdownInputDialog({
    required this.title,
    required this.confirmLabel,
    this.initialText,
  });

  final String title;
  final String confirmLabel;
  final String? initialText;

  @override
  State<_MarkdownInputDialog> createState() => _MarkdownInputDialogState();
}

class _MarkdownInputDialogState extends State<_MarkdownInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLines: 10,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: const InputDecoration(
            hintText: '任意 Discourse markdown/bbcode…',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// 单行输入对话框(壳标题编辑用;controller 生命周期同上)。
class _SingleLineInputDialog extends StatefulWidget {
  const _SingleLineInputDialog({
    required this.title,
    required this.initialText,
  });

  final String title;
  final String initialText;

  @override
  State<_SingleLineInputDialog> createState() =>
      _SingleLineInputDialogState();
}

class _SingleLineInputDialogState extends State<_SingleLineInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

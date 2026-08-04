import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../l10n/s.dart';
import '../../models/chat/chat_channel.dart';
import '../../models/chat/chat_message.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/emoji_handler.dart';
import '../../services/toast_service.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import '../../widgets/markdown_editor/emoji_picker.dart';
import 'package:common_ui/common_ui.dart';

/// 菜单动作(对齐网页版 chat-message-interactor 的 secondaryActions)
enum ChatMessageAction {
  reply,
  copyText,
  copyLink,
  select,
  edit,
  flag,
  delete,
  restore,
  bookmark,
  pin,
  unpin,
}

/// 菜单结果:reaction 与动作二选一
typedef ChatMessageMenuResult = (ChatMessageAction?, String?);

/// 消息能力位(网页版 canEdit/canDelete/canRestore 语义)
class ChatMessageCaps {
  final bool canReply;
  final bool canEdit;
  final bool canFlag;
  final bool canDelete;
  final bool canRestore;

  /// 当前收藏态(bookmark 菜单项文案/图标切换)
  final bool bookmarked;

  /// 置顶管理(频道 can_manage_pins;站点关 chat_pinned_messages 时
  /// 服务端不下发该能力位,自然为 false)
  final bool canManagePins;
  final bool pinned;

  const ChatMessageCaps({
    required this.canReply,
    required this.canEdit,
    required this.canFlag,
    required this.canDelete,
    required this.canRestore,
    this.bookmarked = false,
    this.canManagePins = false,
    this.pinned = false,
  });

  factory ChatMessageCaps.compute({
    required ChatMessage message,
    required bool isSelf,
    required ChatChannel? channel,
  }) {
    final deleted = message.isDeleted;
    return ChatMessageCaps(
      canReply: !deleted,
      canEdit: !deleted && isSelf,
      // 服务端 available_flags 已按 本人/DM/权限/已举报 过滤,空即不可举报
      canFlag: !deleted && !isSelf && message.availableFlags.isNotEmpty,
      canDelete:
          !deleted &&
          ((isSelf && (channel?.canDeleteSelf ?? true)) ||
              (!isSelf && (channel?.canDeleteOthers ?? false))),
      canRestore: deleted && (isSelf || (channel?.canModerate ?? false)),
      bookmarked: message.bookmark != null,
      canManagePins: !deleted && (channel?.canManagePins ?? false),
      pinned: message.pinned,
    );
  }
}

// ============================ 快速 reaction ============================

const String _kRecentReactionsKey = 'chat_recent_reactions';

/// 站点默认快速 reaction(default_emoji_reactions 的通用值)
const List<String> _kDefaultReactions = ['heart', '+1', 'laughing'];

/// 快速 reaction 序列:最近使用优先 + 默认兜底去重(对齐网页版
/// "自定义 > 常用 > 默认"的合成顺序,自定义档暂无用户配置入口)
Future<List<String>> loadQuickReactions({int limit = 7}) async {
  final prefs = await SharedPreferences.getInstance();
  final recent = prefs.getStringList(_kRecentReactionsKey) ?? const [];
  final merged = <String>[...recent, ..._kDefaultReactions];
  final seen = <String>{};
  return [
    for (final e in merged)
      if (seen.add(e)) e,
  ].take(limit).toList();
}

/// 记录一次 reaction 使用(供快速行排序)
Future<void> bumpRecentReaction(String emoji) async {
  final prefs = await SharedPreferences.getInstance();
  final recent = prefs.getStringList(_kRecentReactionsKey) ?? [];
  recent.remove(emoji);
  recent.insert(0, emoji);
  await prefs.setStringList(_kRecentReactionsKey, recent.take(12).toList());
}

// ============================ 共享动作执行 ============================

/// 复制消息链接(网页版 copyLink,路径口径 /chat/c/-/:channel/:message)
void copyChatMessageLink(ChatMessage message) {
  final url =
      '${DiscourseService.baseUrl}/chat/c/-/${message.channelId}/${message.id}';
  Clipboard.setData(ClipboardData(text: url));
  ToastService.showSuccess(S.current.common_copiedToClipboard);
}

/// 复制消息原文
void copyChatMessageText(ChatMessage message) {
  Clipboard.setData(ClipboardData(text: message.message));
  ToastService.showSuccess(S.current.common_copiedToClipboard);
}

/// 完整 emoji picker;移动走可拖拽弹层,桌面走居中紧凑弹窗
Future<String?> showChatEmojiPicker(
  BuildContext context, {
  required bool desktop,
}) {
  if (!desktop) {
    return AppBottomSheet.showDraggable<String>(
      context: context,
      initialSize: 0.55,
      minSize: 0.4,
      bodyBuilder: (pickerContext, scrollController) => EmojiPicker(
        onEmojiSelected: (emoji) => Navigator.pop(pickerContext, emoji.name),
      ),
    );
  }
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 380,
        height: 460,
        child: EmojiPicker(
          compact: true,
          inlineSearch: true,
          onEmojiSelected: (emoji) => Navigator.pop(dialogContext, emoji.name),
        ),
      ),
    ),
  );
}

// ======================= 移动端:长按 overlay =======================

/// 长按菜单:背景模糊压暗,被按气泡原位保留(必要时上移
/// 腾出菜单空间),反应条悬浮气泡上方,菜单卡跟在气泡下方。
Future<ChatMessageMenuResult?> showChatMessageActionsOverlay({
  required BuildContext context,
  required Rect bubbleRect,
  required WidgetBuilder bubbleBuilder,
  required ChatMessage message,
  required ChatMessageCaps caps,
  required List<String> quickReactions,
}) {
  HapticFeedback.mediumImpact();
  return Navigator.of(context, rootNavigator: true).push<ChatMessageMenuResult>(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (routeContext, animation, _) => _MessageActionsOverlay(
        animation: animation,
        bubbleRect: bubbleRect,
        bubbleBuilder: bubbleBuilder,
        message: message,
        caps: caps,
        quickReactions: quickReactions,
      ),
    ),
  );
}

class _MessageActionsOverlay extends StatelessWidget {
  final Animation<double> animation;
  final Rect bubbleRect;
  final WidgetBuilder bubbleBuilder;
  final ChatMessage message;
  final ChatMessageCaps caps;
  final List<String> quickReactions;

  const _MessageActionsOverlay({
    required this.animation,
    required this.bubbleRect,
    required this.bubbleBuilder,
    required this.message,
    required this.caps,
    required this.quickReactions,
  });

  List<ChatMenuItemSpec> _menuItems(BuildContext context) =>
      buildChatMenuItems(context, caps: caps, includeCopyText: true);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final screen = media.size;
    final topSafe = media.padding.top;
    final bottomSafe = media.padding.bottom;

    final items = _menuItems(context);
    const barHeight = 48.0;
    const gap = 8.0;
    final menuHeight = items.length * 46.0 + 12;
    const menuWidth = 224.0;

    // 布局:理想位置=气泡原位;空间不够时整体上移/下移
    final bubbleHeight = bubbleRect.height;
    final totalHeight = barHeight + gap + bubbleHeight + gap + menuHeight;
    double bubbleTop = bubbleRect.top;
    final maxBubbleTop =
        screen.height - bottomSafe - 12 - menuHeight - gap - bubbleHeight;
    final minBubbleTop = topSafe + 12 + barHeight + gap;
    bubbleTop = totalHeight > screen.height - topSafe - bottomSafe - 24
        ? minBubbleTop
        : bubbleTop.clamp(minBubbleTop, maxBubbleTop);

    // 水平:消息行是扁平左对齐布局(自己/别人同一侧,靠名字配色区分),
    // 条与菜单一律跟气泡左缘,再收进屏内安全边距。
    // 早先按 isSelf 把菜单右对齐到气泡右缘,是左右气泡时代的遗留——
    // 贴图/短消息的右缘就在屏幕左半区,定宽菜单整块甩出屏外(用户截图)。
    const edge = 8.0;
    final maxAnchorLeft = math.max(edge, screen.width - edge - menuWidth);
    final anchorLeft = math.min(math.max(bubbleRect.left, edge), maxAnchorLeft);
    // 反应条宽度随 emoji 数量浮动,按锚点右侧余量收口(内部可横滚)
    final barMaxWidth = math.max(160.0, screen.width - edge - anchorLeft);

    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return AnimatedBuilder(
      animation: curved,
      // 副本内容只构建一次:builder 每帧重建 _buildBubbleCore(markdown/
      // emoji 渲染)会让副本闪烁(用户点名)。child 参数跨帧复用,外层
      // Positioned/Transform/Opacity 照常每帧按动画值更新。
      child: bubbleBuilder(context),
      builder: (context, child) {
        final t = curved.value;
        // 气泡从原位平滑滑到腾挪后的位置,条/菜单跟着走;
        // 关闭时反向滑回原位,与列表里的真气泡无缝衔接
        final animatedBubbleTop =
            bubbleRect.top + (bubbleTop - bubbleRect.top) * t;
        final barTop = animatedBubbleTop - gap - barHeight;
        // 超长气泡(三段总高超屏)时菜单钉屏幕下缘,盖住气泡下半部
        // (菜单卡带影有层次),不再悬到屏外/叠中间
        final menuTop = math.min(
          animatedBubbleTop + bubbleHeight + gap,
          screen.height - bottomSafe - 12 - menuHeight,
        );
        return Stack(
          children: [
            // 背景:模糊 + 压暗,点击关闭
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8 * t, sigmaY: 8 * t),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.25 * t),
                  ),
                ),
              ),
            ),
            // 气泡副本(入场动画中从原位滑向腾挪位):轻微缩放蓄势
            // (0.97→1,按住弹起的手感);壳的底色/阴影随动画淡入,
            // 起始帧与列表裸正文形态一致,不再"凭空多出个气泡"
            Positioned(
              left: bubbleRect.left,
              top: animatedBubbleTop,
              width: bubbleRect.width,
              child: IgnorePointer(
                child: Transform.scale(
                  scale: 0.97 + 0.03 * t,
                  alignment: Alignment.centerLeft,
                  child: Opacity(
                    // 壳体(含底色)整体淡入:0.7 起步(较 0.55 减少半透明
                    // 叠模糊层的闪烁感),末段补到不透明
                    opacity: (0.7 + 0.3 * t).clamp(0.0, 1.0),
                    child: child!,
                  ),
                ),
              ),
            ),
            // 反应条(气泡上方,scale 从贴近气泡处长出)
            Positioned(
              top: barTop,
              left: anchorLeft,
              child: Transform.scale(
                scale: 0.6 + 0.4 * t,
                alignment: Alignment.bottomLeft,
                child: Opacity(
                  opacity: t,
                  child: _ReactionBar(
                    message: message,
                    quickReactions: quickReactions,
                    maxWidth: barMaxWidth,
                    onSelect: (emoji) => Navigator.pop(context, (null, emoji)),
                    onMore: () async {
                      final selected = await showChatEmojiPicker(
                        context,
                        desktop: false,
                      );
                      if (selected != null && context.mounted) {
                        Navigator.pop(context, (null, selected));
                      }
                    },
                  ),
                ),
              ),
            ),
            // 菜单卡(气泡下方)
            Positioned(
              top: menuTop,
              left: anchorLeft,
              child: Transform.scale(
                scale: 0.6 + 0.4 * t,
                alignment: Alignment.topLeft,
                child: Opacity(
                  opacity: t,
                  child: Material(
                    color: theme.colorScheme.surfaceContainerLow,
                    elevation: 6,
                    shadowColor: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: menuWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 6),
                          for (final item in items)
                            InkWell(
                              onTap: () =>
                                  Navigator.pop(context, (item.action, null)),
                              child: SizedBox(
                                height: 46,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          item.label,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                                color: item.destructive
                                                    ? theme.colorScheme.error
                                                    : theme
                                                          .colorScheme
                                                          .onSurface,
                                              ),
                                        ),
                                      ),
                                      Icon(
                                        item.icon,
                                        size: 20,
                                        color: item.destructive
                                            ? theme.colorScheme.error
                                            : theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 6),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 悬浮反应条:横排 emoji(可滚) + "+"
class _ReactionBar extends StatelessWidget {
  final ChatMessage message;
  final List<String> quickReactions;

  /// 可用宽度上限(由锚点右侧余量算出;超出的 emoji 走横滚)
  final double maxWidth;
  final void Function(String emoji) onSelect;
  final VoidCallback onMore;

  const _ReactionBar({
    required this.message,
    required this.quickReactions,
    required this.maxWidth,
    required this.onSelect,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final emoji in quickReactions)
                _ReactionBarButton(
                  emoji: emoji,
                  reacted: message.reactions.any(
                    (r) => r.emoji == emoji && r.reacted,
                  ),
                  onTap: () => onSelect(emoji),
                ),
              InkWell(
                onTap: onMore,
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: Icon(
                    Symbols.add_rounded,
                    size: 24,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactionBarButton extends StatelessWidget {
  final String emoji;
  final bool reacted;
  final VoidCallback onTap;

  const _ReactionBarButton({
    required this.emoji,
    required this.reacted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = EmojiHandler().getEmojiUrl(emoji);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        padding: const EdgeInsets.all(7),
        decoration: reacted
            ? BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                shape: BoxShape.circle,
              )
            : null,
        child: url.isEmpty
            ? Text(emoji, style: const TextStyle(fontSize: 22))
            : Image(image: emojiImageProvider(url), width: 26, height: 26),
      ),
    );
  }
}

// ======================= 桌面端:右键/更多 锚点菜单 =======================

/// 桌面锚点菜单(右键、hover 工具条"更多"共用):
/// 首行 reaction 条 + 动作项,showSwipeDismissibleMenu 外壳。
Future<ChatMessageMenuResult?> showChatMessageContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required ChatMessage message,
  required bool isSelf,
  required ChatMessageCaps caps,
  required List<String> quickReactions,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromLTRB(
    globalPosition.dx,
    globalPosition.dy,
    overlay.size.width - globalPosition.dx,
    overlay.size.height - globalPosition.dy,
  );
  final items = buildChatMenuItems(context, caps: caps, includeCopyText: true);
  return showSwipeDismissibleMenu<ChatMessageMenuResult>(
    context: context,
    position: position,
    items: [
      if (!message.isDeleted)
        _ReactionRowEntry(message: message, quickReactions: quickReactions),
      for (final item in items)
        PopupMenuItem<ChatMessageMenuResult>(
          value: (item.action, null),
          height: 42,
          child: Row(
            children: [
              Icon(
                item.icon,
                size: 20,
                color: item.destructive
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Text(
                item.label,
                style: item.destructive
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null,
              ),
            ],
          ),
        ),
    ],
  );
}

/// 弹出菜单首行:快速 reaction 行(自绘 entry,点击带值收起菜单)
class _ReactionRowEntry extends PopupMenuEntry<ChatMessageMenuResult> {
  final ChatMessage message;
  final List<String> quickReactions;

  const _ReactionRowEntry({
    required this.message,
    required this.quickReactions,
  });

  @override
  double get height => 48;

  @override
  bool represents(ChatMessageMenuResult? value) => false;

  @override
  State<_ReactionRowEntry> createState() => _ReactionRowEntryState();
}

class _ReactionRowEntryState extends State<_ReactionRowEntry> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final emoji in widget.quickReactions.take(5))
            _ReactionBarButton(
              emoji: emoji,
              reacted: widget.message.reactions.any(
                (r) => r.emoji == emoji && r.reacted,
              ),
              onTap: () => Navigator.pop(context, (null, emoji)),
            ),
          InkWell(
            onTap: () async {
              final selected = await showChatEmojiPicker(
                context,
                desktop: true,
              );
              if (selected != null && context.mounted) {
                Navigator.pop(context, (null, selected));
              }
            },
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Icon(
                Symbols.add_rounded,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================ 菜单项定义 ============================

/// 菜单项条目(内部与聊天页共用,故公开)
class ChatMenuItemSpec {
  final ChatMessageAction action;
  final IconData icon;
  final String label;
  final bool destructive;

  const ChatMenuItemSpec(
    this.action,
    this.icon,
    this.label, {
    this.destructive = false,
  });
}

/// 菜单项(顺序与网页版 secondaryActions 一致:链接/文本/回复/编辑/删除/恢复)
List<ChatMenuItemSpec> buildChatMenuItems(
  BuildContext context, {
  required ChatMessageCaps caps,
  required bool includeCopyText,
}) {
  final l10n = context.l10n;
  return [
    if (caps.canReply)
      ChatMenuItemSpec(
        ChatMessageAction.reply,
        Symbols.reply_rounded,
        l10n.chat_menuReply,
      ),
    ChatMenuItemSpec(
      ChatMessageAction.copyLink,
      Symbols.link_rounded,
      l10n.chat_menuCopyLink,
    ),
    ChatMenuItemSpec(
      ChatMessageAction.bookmark,
      caps.bookmarked
          ? Symbols.bookmark_remove_rounded
          : Symbols.bookmark_add_rounded,
      caps.bookmarked ? l10n.chat_menuRemoveBookmark : l10n.chat_menuBookmark,
    ),
    if (includeCopyText && !caps.canRestore)
      ChatMenuItemSpec(
        ChatMessageAction.copyText,
        Symbols.content_copy_rounded,
        l10n.chat_menuCopy,
      ),
    if (!caps.canRestore)
      ChatMenuItemSpec(
        ChatMessageAction.select,
        Symbols.checklist_rounded,
        l10n.chat_menuSelect,
      ),
    if (caps.canEdit)
      ChatMenuItemSpec(
        ChatMessageAction.edit,
        Symbols.edit_rounded,
        l10n.chat_menuEdit,
      ),
    if (caps.canManagePins)
      caps.pinned
          ? ChatMenuItemSpec(
              ChatMessageAction.unpin,
              Symbols.keep_off_rounded,
              l10n.chat_menuUnpin,
            )
          : ChatMenuItemSpec(
              ChatMessageAction.pin,
              Symbols.keep_rounded,
              l10n.chat_menuPin,
            ),
    if (caps.canFlag)
      ChatMenuItemSpec(
        ChatMessageAction.flag,
        Symbols.flag_rounded,
        l10n.chat_menuFlag,
      ),
    if (caps.canDelete)
      ChatMenuItemSpec(
        ChatMessageAction.delete,
        Symbols.delete_rounded,
        l10n.chat_menuDelete,
        destructive: true,
      ),
    if (caps.canRestore)
      ChatMenuItemSpec(
        ChatMessageAction.restore,
        Symbols.restore_from_trash_rounded,
        l10n.chat_menuRestore,
      ),
  ];
}

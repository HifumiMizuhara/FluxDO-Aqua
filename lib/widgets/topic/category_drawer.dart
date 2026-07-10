import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../providers/pinned_categories_provider.dart';
import '../../utils/font_awesome_helper.dart';
import '../../utils/url_helper.dart';
import '../../services/discourse_cache_manager.dart';
import '../../pages/category_topics_page.dart';
import '../../l10n/s.dart';
import 'topic_notification_button.dart' show getCategoryNotificationIcon;
import 'category_tab_manager_sheet.dart' show PinnedCategoryEditPage;

/// 首页分类侧栏：分类的管理中枢。
///
/// 以**根 Navigator 全屏透明路由**呈现（非 Scaffold.drawer：首页是
/// AdaptiveScaffold body 里的子树，内层 drawer 遮罩盖不住外层底栏与
/// FAB）。右缘大圆角面板。
///
/// 行上克制：常驻可点的只有「行本体」和「chevron（有子分类时）」——
/// 每行 🔔★ 常驻按钮版被否（按钮过密易误触）。收藏/订阅收进
/// **长按（桌面右键）分类操作菜单**；🔒 受限做成图标块右下角标。
///
/// - 收藏区：已 pin 分类，点行 → 切到对应首页 tab
/// - 全部分类区：全量分类按父子分组（子分类折叠，默认收起），
///   点行 → push 独立分类页浏览
/// - 长按任意分类行 → 菜单：收藏/取消收藏、订阅设置
/// - 「编辑」→ 收藏排序页（拖拽调序，复用 PinnedCategoryEditPage）
class CategoryDrawer extends ConsumerStatefulWidget {
  const CategoryDrawer({
    super.key,
    required this.onPinnedSelected,
    required this.onSubscriptionTap,
  });

  /// 点收藏分类：切换首页 tab（index 为 pinned 列表内序号）
  final ValueChanged<int> onPinnedSelected;

  /// 分类操作菜单选「订阅设置」：弹级别面板（宿主处理乐观更新/回退）
  final ValueChanged<Category> onSubscriptionTap;

  @override
  ConsumerState<CategoryDrawer> createState() => _CategoryDrawerState();
}

class _CategoryDrawerState extends ConsumerState<CategoryDrawer> {
  /// 已展开子分类的父分类 id 集合（默认全收起）
  final Set<int> _expandedIds = {};

  /// 长按/右键分类行：收藏与订阅的操作菜单（低频操作不常驻行上）
  Future<void> _showCategoryMenu(
    BuildContext rowContext,
    Category category, {
    required bool pinned,
    required CategoryNotificationLevel? level,
  }) async {
    final colorScheme = Theme.of(rowContext).colorScheme;
    final box = rowContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(rowContext).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      box.localToGlobal(Offset.zero, ancestor: overlay) & box.size,
      Offset.zero & overlay.size,
    );

    final action = await showMenu<Symbol>(
      context: rowContext,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        PopupMenuItem(
          value: #togglePin,
          child: Row(
            children: [
              Icon(
                Symbols.star_rounded,
                size: 18,
                fill: pinned ? 1 : 0,
                color: pinned ? colorScheme.primary : null,
              ),
              const SizedBox(width: 10),
              Text(
                pinned
                    ? S.current.category_unpin
                    : S.current.category_pinToTabs,
              ),
            ],
          ),
        ),
        if (level != null)
          PopupMenuItem(
            value: #subscription,
            child: Row(
              children: [
                Icon(
                  getCategoryNotificationIcon(level),
                  size: 18,
                  color: level != CategoryNotificationLevel.regular
                      ? colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 10),
                Text(S.current.topic_notificationSettings),
              ],
            ),
          ),
      ],
    );

    if (!mounted) return;
    switch (action) {
      case #togglePin:
        final notifier = ref.read(pinnedCategoriesProvider.notifier);
        pinned ? notifier.remove(category.id) : notifier.add(category.id);
      case #subscription:
        widget.onSubscriptionTap(category);
      default:
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final pinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final overrides = ref.watch(categoryNotificationOverridesProvider);

    CategoryNotificationLevel? levelFor(Category c) {
      if (!isLoggedIn) return null;
      return CategoryNotificationLevel.fromValue(
        overrides[c.id] ?? c.notificationLevel,
      );
    }

    return Drawer(
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
      ),
      child: SafeArea(
        child: categoriesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(child: Text(S.current.common_loadFailed)),
          data: (categories) {
            final categoryMap = {for (final c in categories) c.id: c};
            final pinned = pinnedIds
                .map((id) => categoryMap[id])
                .whereType<Category>()
                .toList();
            final pinnedSet = pinnedIds.toSet();

            // 父子分组（保持服务器顺序）：顶级分类 + 各自子分类;
            // 父不可见的孤儿子分类兜底提为顶级
            final childrenOf = <int, List<Category>>{};
            final topLevel = <Category>[];
            for (final c in categories) {
              final parentId = c.parentCategoryId;
              if (parentId != null && categoryMap.containsKey(parentId)) {
                (childrenOf[parentId] ??= []).add(c);
              } else {
                topLevel.add(c);
              }
            }

            Widget rowFor(
              Category category, {
              required bool indent,
              List<Category> children = const [],
            }) {
              final expanded = _expandedIds.contains(category.id);
              final isPinned = pinnedSet.contains(category.id);
              final hasChildren = children.isNotEmpty;
              return _CategoryRow(
                category: category,
                pinned: isPinned,
                indent: indent,
                expandState: hasChildren ? expanded : null,
                // 单一职责：带 chevron 的行只做展开/收起，不带的只做
                // 进页。父分类自身的话题列表走展开后的第一行
                // 「全部话题」入口（Amazon/Play 分类树范式）——
                // 消灭"同样的行为却不同"和 ↗ 小目标
                onTap: hasChildren
                    ? () => setState(() {
                        expanded
                            ? _expandedIds.remove(category.id)
                            : _expandedIds.add(category.id);
                      })
                    : () {
                        final navigator = Navigator.of(context);
                        navigator.pop();
                        navigator.push(
                          MaterialPageRoute(
                            builder: (_) =>
                                CategoryTopicsPage(category: category),
                          ),
                        );
                      },
                onLongPress: (rowContext) => _showCategoryMenu(
                  rowContext,
                  category,
                  pinned: isPinned,
                  level: levelFor(category),
                ),
              );
            }

            /// 展开后的首行：「全部话题」—— 父分类自身聚合页的入口
            Widget allTopicsRowFor(Category parent) {
              return _AllTopicsRow(
                parentColor: _parseColor(parent.color, colorScheme.primary),
                onTap: () {
                  final navigator = Navigator.of(context);
                  navigator.pop();
                  navigator.push(
                    MaterialPageRoute(
                      builder: (_) => CategoryTopicsPage(category: parent),
                    ),
                  );
                },
              );
            }

            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              children: [
                // —— 标题行 ——
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 0, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          S.current.topics_browseCategories,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      if (pinned.isNotEmpty)
                        IconButton(
                          icon: const Icon(Symbols.edit_rounded, size: 20),
                          tooltip: S.current.common_edit,
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            final navigator = Navigator.of(context);
                            navigator.pop();
                            navigator.push(
                              MaterialPageRoute(
                                builder: (_) => const PinnedCategoryEditPage(),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
                // —— 收藏区（点行切首页 tab，无展开语义）——
                if (pinned.isNotEmpty) ...[
                  _SectionLabel(text: S.current.category_myCategories),
                  for (var i = 0; i < pinned.length; i++)
                    _CategoryRow(
                      category: pinned[i],
                      pinned: true,
                      indent: false,
                      onTap: () {
                        Navigator.pop(context);
                        widget.onPinnedSelected(i);
                      },
                      onLongPress: (rowContext) => _showCategoryMenu(
                        rowContext,
                        pinned[i],
                        pinned: true,
                        level: levelFor(pinned[i]),
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                // —— 全部分类区（父子分组，子分类默认折叠）——
                _SectionLabel(text: S.current.category_allCategories),
                for (final parent in topLevel) ...[
                  rowFor(
                    parent,
                    indent: false,
                    children: childrenOf[parent.id] ?? const [],
                  ),
                  if (_expandedIds.contains(parent.id)) ...[
                    // 首行「全部话题」= 父分类自身聚合页入口
                    allTopicsRowFor(parent),
                    for (final child in childrenOf[parent.id] ?? const [])
                      rowFor(child, indent: true),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 分区小标题（大写风格次级文字）
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.pinned,
    required this.indent,
    required this.onTap,
    required this.onLongPress,
    this.expandState,
  });

  final Category category;
  final bool pinned;
  final bool indent;

  /// 行本体点击：有子分类 = 展开/收起，无子分类 = 进分类页
  final VoidCallback onTap;

  /// 长按/桌面右键：分类操作菜单（收藏/订阅）。传行的 context 供菜单
  /// 锚定在行位置
  final void Function(BuildContext rowContext) onLongPress;

  /// 子分类展开态（null = 无子分类，行尾无 chevron）
  final bool? expandState;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final categoryColor = _parseColor(category.color, colorScheme.primary);
    final expanded = expandState;

    return Padding(
      padding: EdgeInsets.only(left: indent ? 20 : 0, bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Builder(
          builder: (rowContext) => InkWell(
            onTap: onTap,
            onLongPress: () => onLongPress(rowContext),
            onSecondaryTap: () => onLongPress(rowContext),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    // 彩色图标块（🔒 受限为右下小角标）
                    _CategoryIconBlock(
                      category: category,
                      color: categoryColor,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: pinned
                              ? FontWeight.w500
                              : FontWeight.w400,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    // 收藏态：小 ★ 状态点缀（非按钮，长按菜单里操作）
                    if (pinned)
                      Icon(
                        Symbols.star_rounded,
                        size: 16,
                        fill: 1,
                        color: colorScheme.primary.withValues(alpha: 0.75),
                      ),
                    // 展开态指示（非按钮：整行即展开/收起）
                    if (expanded != null) ...[
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Symbols.keyboard_arrow_down_rounded,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开后的首行「全部话题」：父分类自身聚合页的入口。
/// 与子分类行同构（同 48 行高、同 32px 图标块规格），图标块继承
/// 父分类色，用列表符号代替分类图标 —— 融入分组又可辨识。
class _AllTopicsRow extends StatelessWidget {
  const _AllTopicsRow({required this.parentColor, required this.onTap});

  final Color parentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: parentColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Center(
                      child: Icon(
                        Symbols.clear_all_rounded,
                        size: 18,
                        color: parentColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      S.current.category_allTopics,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 分类彩色图标块：分类色 12% 底 + 图标/logo/色点居中；受限分类在
/// 右下角叠 🔒 小角标（元信息贴着身份元素，不占行上操作位）
class _CategoryIconBlock extends StatelessWidget {
  const _CategoryIconBlock({required this.category, required this.color});

  final Category category;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final block = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Center(child: _buildCategoryIcon(category, color, 18)),
    );
    if (!category.readRestricted) return block;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        block,
        Positioned(
          right: -3,
          bottom: -3,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Symbols.lock_rounded,
              size: 9,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

Color _parseColor(String hex, Color fallback) {
  try {
    return Color(int.parse('FF$hex', radix: 16));
  } catch (_) {
    return fallback;
  }
}

Widget _buildCategoryIcon(Category category, Color color, double size) {
  final logoUrl = category.uploadedLogo;
  final faIcon = FontAwesomeHelper.getIcon(category.icon);

  if (faIcon != null) {
    return FaIcon(faIcon, size: size * 0.85, color: color);
  }

  if (logoUrl != null && logoUrl.isNotEmpty) {
    return Image(
      image: discourseImageProvider(UrlHelper.resolveUrlWithCdn(logoUrl)),
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => _colorDot(color, size * 0.5),
    );
  }

  return _colorDot(color, size * 0.5);
}

Widget _colorDot(Color color, double size) {
  return Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

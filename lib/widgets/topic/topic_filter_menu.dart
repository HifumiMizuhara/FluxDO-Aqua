import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:common_ui/common_ui.dart';
import '../../providers/topic_list/filter_provider.dart';
import '../../providers/topic_list/sort_provider.dart';
import '../../providers/topic_list/tab_state_provider.dart';
import '../../providers/message_bus/topic_tracking_providers.dart';
import '../../l10n/s.dart';
import 'sort_and_tags_bar.dart' show filterOptions, filterLabel;

/// 忽略动作的菜单值哨兵（与筛选/排序/子过滤的枚举值区分）
const _dismissAllValue = #topicFilterMenuDismissAll;

/// 「添加标签」动作哨兵
const _selectTagsValue = #topicFilterMenuSelectTags;

/// 聚合筛选菜单：一颗按钮收编原「筛选下拉 + 新话题子过滤下拉 + 排序
/// 下拉 + 忽略按钮」四个分立控件，是首页头部三行瘦身为两行的支点。
///
/// 菜单结构：筛选模式（带计数）/「新」子过滤（仅该模式下出现）/
/// 排序级联子菜单（再选已选项切换升降序）/ 上下文动作（忽略）。
/// 按钮本体是 normal chip：当前筛选文案 + ▾；非默认排序时加 primary
/// 圆点标记（排序状态收进菜单后的最小可见性补救）。
class TopicFilterMenuButton extends ConsumerWidget {
  final TopicListFilter currentFilter;
  final bool isLoggedIn;
  final ValueChanged<TopicListFilter> onFilterChanged;
  final NewSubset currentSubset;
  final ValueChanged<NewSubset> onSubsetChanged;
  final TopicSortOrder currentOrder;
  final bool ascending;
  final ValueChanged<TopicSortOrder> onOrderChanged;
  final VoidCallback onToggleAscending;

  /// 非 null 时菜单尾部出现「忽略」动作项（new/unread 筛选的上下文动作）
  final VoidCallback? onDismissAll;

  /// 非 null 时菜单出现「按标签筛选」入口（拉起 TagSelectionSheet）；
  /// 已选标签数量 > 0 时入口带计数
  final VoidCallback? onSelectTags;
  final int selectedTagCount;

  /// 标题样式：按钮以页面标题形态呈现（加大加粗、无底色，Reddit
  /// `Home ▾` 顶栏模式）；false = 灰底 chip（列表页内嵌样式）
  final bool titleStyle;

  const TopicFilterMenuButton({
    super.key,
    required this.currentFilter,
    required this.isLoggedIn,
    required this.onFilterChanged,
    required this.currentSubset,
    required this.onSubsetChanged,
    required this.currentOrder,
    required this.ascending,
    required this.onOrderChanged,
    required this.onToggleAscending,
    this.onDismissAll,
    this.onSelectTags,
    this.selectedTagCount = 0,
    this.titleStyle = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    // 读取追踪状态计数（与原 FilterDropdown 同源）
    final trackingNotifier = ref.watch(topicTrackingStateProvider.notifier);
    final categoryId = ref.watch(currentTabCategoryIdProvider);
    // watch state 本身以触发 rebuild
    ref.watch(topicTrackingStateProvider);
    final newCount = isLoggedIn
        ? trackingNotifier.countNew(categoryId: categoryId)
        : 0;
    final unreadCount = isLoggedIn
        ? trackingNotifier.countUnread(categoryId: categoryId)
        : 0;

    String optionLabel(TopicListFilter filter, String baseLabel) {
      final count = _countForFilter(filter, newCount, unreadCount);
      return count > 0 ? '$baseLabel ($count)' : baseLabel;
    }

    String buttonLabel() {
      final base = filterLabel(currentFilter);
      final count = _countForFilter(currentFilter, newCount, unreadCount);
      return count > 0 ? '$base ($count)' : base;
    }

    final orderActive = currentOrder != TopicSortOrder.defaultOrder;

    return SwipeDismissiblePopupMenuButton<Object>(
      onSelected: (value) {
        if (value is TopicListFilter) {
          onFilterChanged(value);
        } else if (value is NewSubset) {
          onSubsetChanged(value);
        } else if (value is TopicSortOrder) {
          // 再选已选中的非默认排序 = 切换升降序（原 OrderDropdown 交互）
          if (value == currentOrder && value != TopicSortOrder.defaultOrder) {
            onToggleAscending();
          } else {
            onOrderChanged(value);
          }
        } else if (value == _dismissAllValue) {
          onDismissAll?.call();
        } else if (value == _selectTagsValue) {
          onSelectTags?.call();
        }
      },
      offset: const Offset(0, 36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tooltip: S.current.topic_filterTooltip(filterLabel(currentFilter)),
      itemBuilder: (context) {
        final items = <PopupMenuEntry<Object>>[];

        // —— 筛选模式 ——
        final visibleFilters = filterOptions.where(
          (option) =>
              isLoggedIn ||
              (option.$1 != TopicListFilter.newTopics &&
                  option.$1 != TopicListFilter.unread &&
                  option.$1 != TopicListFilter.unseen),
        );
        for (final option in visibleFilters) {
          items.add(
            PopupMenuItem<Object>(
              value: option.$1,
              child: Row(
                children: [
                  if (option.$1 == currentFilter)
                    Icon(
                      Symbols.check_rounded,
                      size: 16,
                      color: colorScheme.primary,
                    )
                  else
                    const SizedBox(width: 16),
                  const SizedBox(width: 8),
                  Text(optionLabel(option.$1, option.$2)),
                ],
              ),
            ),
          );
        }

        // ——「新」子过滤（仅该模式下展示，缩进呈现从属关系）——
        if (currentFilter == TopicListFilter.newTopics) {
          items.add(const PopupMenuDivider());
          for (final subset in NewSubset.values) {
            items.add(
              PopupMenuItem<Object>(
                value: subset,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    if (subset == currentSubset)
                      Icon(
                        Symbols.check_rounded,
                        size: 16,
                        color: colorScheme.primary,
                      )
                    else
                      const SizedBox(width: 16),
                    const SizedBox(width: 8),
                    Text(
                      _subsetLabel(subset),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
            );
          }
        }

        // —— 排序（级联子菜单；选中项带方向箭头）——
        items.add(const PopupMenuDivider());
        items.add(
          ExpandablePopupMenuEntry<Object>(
            icon: Symbols.sort_rounded,
            label: S.current.topic_sortTooltip(currentOrder.label),
            iconColor: orderActive ? colorScheme.primary : null,
            labelColor: orderActive ? colorScheme.primary : null,
            children: [
              for (final order in TopicSortOrder.values)
                ExpandableMenuChild<Object>(
                  value: order,
                  icon: _orderIcon(order),
                  label:
                      order == currentOrder &&
                          order != TopicSortOrder.defaultOrder
                      ? '${order.label} ${ascending ? '↑' : '↓'}'
                      : order.label,
                  selected: order == currentOrder,
                ),
            ],
          ),
        );

        // —— 按标签筛选（拉起 TagSelectionSheet）——
        if (onSelectTags != null) {
          items.add(const PopupMenuDivider());
          items.add(
            PopupMenuItem<Object>(
              value: _selectTagsValue,
              child: Row(
                children: [
                  Icon(
                    Symbols.label_rounded,
                    size: 16,
                    color: selectedTagCount > 0
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    selectedTagCount > 0
                        ? '${S.current.topic_addTags} ($selectedTagCount)'
                        : S.current.topic_addTags,
                    style: selectedTagCount > 0
                        ? TextStyle(color: colorScheme.primary)
                        : null,
                  ),
                ],
              ),
            ),
          );
        }

        // —— 上下文动作：忽略（全部已读）——
        if (onDismissAll != null) {
          items.add(const PopupMenuDivider());
          items.add(
            PopupMenuItem<Object>(
              value: _dismissAllValue,
              child: Row(
                children: [
                  Icon(
                    Symbols.done_all_rounded,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(S.current.topics_dismiss),
                ],
              ),
            ),
          );
        }

        return items;
      },
      child: titleStyle
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    buttonLabel(),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  if (orderActive)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.only(left: 5),
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  const SizedBox(width: 2),
                  Icon(
                    Symbols.keyboard_arrow_down_rounded,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            )
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    buttonLabel(),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  if (orderActive)
                    Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.only(left: 4),
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  const SizedBox(width: 2),
                  Icon(
                    Symbols.arrow_drop_down_rounded,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
    );
  }

  static int _countForFilter(
    TopicListFilter filter,
    int newCount,
    int unreadCount,
  ) {
    switch (filter) {
      case TopicListFilter.newTopics:
        return newCount + unreadCount;
      case TopicListFilter.unread:
        return unreadCount;
      default:
        return 0;
    }
  }

  static String _subsetLabel(NewSubset subset) {
    switch (subset) {
      case NewSubset.all:
        return S.current.topic_filterNewAllShort;
      case NewSubset.topics:
        return S.current.topic_filterNewTopicsShort;
      case NewSubset.replies:
        return S.current.topic_filterNewRepliesShort;
    }
  }

  static IconData _orderIcon(TopicSortOrder order) {
    switch (order) {
      case TopicSortOrder.defaultOrder:
        return Symbols.sort_rounded;
      case TopicSortOrder.activity:
        return Symbols.update_rounded;
      case TopicSortOrder.created:
        return Symbols.calendar_today_rounded;
      case TopicSortOrder.views:
        return Symbols.visibility_rounded;
      case TopicSortOrder.posts:
        return Symbols.chat_bubble_rounded;
      case TopicSortOrder.likes:
        return Symbols.favorite_rounded;
      case TopicSortOrder.posters:
        return Symbols.group_rounded;
    }
  }
}

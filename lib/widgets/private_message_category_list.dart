import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../l10n/s.dart';
import '../models/private_message_category.dart';
import '../models/topic.dart';
import 'topic/topic_item_builder.dart';

/// Categorized presentation of the private-message topic list.
///
/// Expansion state belongs to this widget, so it survives message/unread
/// updates during the page session and is discarded when the list is removed.
class PrivateMessageCategoryList extends StatefulWidget {
  final List<Topic> topics;
  final ScrollController controller;
  final int? selectedTopicId;
  final bool enableLongPress;
  final ValueChanged<Topic> onTopicTap;
  final Widget footer;
  final Widget Function(BuildContext context, Topic topic)? topicBuilder;

  const PrivateMessageCategoryList({
    super.key,
    required this.topics,
    required this.controller,
    required this.selectedTopicId,
    required this.enableLongPress,
    required this.onTopicTap,
    required this.footer,
    this.topicBuilder,
  });

  @override
  State<PrivateMessageCategoryList> createState() =>
      _PrivateMessageCategoryListState();
}

class _PrivateMessageCategoryListState
    extends State<PrivateMessageCategoryList> {
  static const _initialVisibleCount = 3;
  final Set<String> _collapsedCategories = <String>{};
  final Set<String> _showAllTopics = <String>{};

  @override
  void didUpdateWidget(covariant PrivateMessageCategoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final keys = groupPrivateMessages(
      widget.topics,
    ).map((category) => category.key).toSet();
    _collapsedCategories.removeWhere((key) => !keys.contains(key));
    _showAllTopics.removeWhere((key) => !keys.contains(key));
  }

  @override
  Widget build(BuildContext context) {
    final categories = groupPrivateMessages(widget.topics);
    return ListView(
      controller: widget.controller,
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        12 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        for (var index = 0; index < categories.length; index++)
          Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
            child: _buildCategory(context, categories[index]),
          ),
        widget.footer,
      ],
    );
  }

  Widget _buildCategory(BuildContext context, PrivateMessageCategory category) {
    final collapsed = _collapsedCategories.contains(category.key);
    final showAll = _showAllTopics.contains(category.key);
    final visibleTopics = collapsed
        ? const <Topic>[]
        : (showAll
              ? category.topics
              : category.topics.take(_initialVisibleCount).toList());
    final hasMore = category.topics.length > _initialVisibleCount;

    return SegmentedCardGroup(
      children: [
        _buildCategoryHeader(context, category, collapsed),
        if (!collapsed)
          for (final topic in visibleTopics)
            widget.topicBuilder?.call(context, topic) ??
                buildTopicItem(
                  context: context,
                  topic: topic,
                  isSelected: widget.selectedTopicId == topic.id,
                  onTap: () => widget.onTopicTap(topic),
                  enableLongPress: widget.enableLongPress,
                  messageStyle: true,
                ),
        if (!collapsed && hasMore)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  setState(() {
                    if (showAll) {
                      _showAllTopics.remove(category.key);
                    } else {
                      _showAllTopics.add(category.key);
                    }
                  });
                },
                icon: Icon(
                  showAll
                      ? Symbols.expand_less_rounded
                      : Symbols.expand_more_rounded,
                  size: 18,
                ),
                label: Text(
                  showAll
                      ? context.l10n.privateMessages_collapse
                      : context.l10n.privateMessages_showMore,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCategoryHeader(
    BuildContext context,
    PrivateMessageCategory category,
    bool collapsed,
  ) {
    final theme = Theme.of(context);
    final label = category.isGroupChat
        ? context.l10n.privateMessages_groupChat
        : category.peer?.username ?? 'DM #${category.topics.first.id}';

    return InkWell(
      onTap: () {
        setState(() {
          if (collapsed) {
            _collapsedCategories.remove(category.key);
          } else {
            _collapsedCategories.add(category.key);
          }
        });
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Icon(
              category.isGroupChat
                  ? Symbols.groups_rounded
                  : Symbols.person_rounded,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              collapsed
                  ? Symbols.expand_more_rounded
                  : Symbols.expand_less_rounded,
              color: theme.colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

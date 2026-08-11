import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification.dart';
import 'core_providers.dart';
import 'message_bus_providers.dart';

/// 最近通知 Notifier（非分页，供快捷面板和 messageBus 使用）
class RecentNotificationsNotifier
    extends AsyncNotifier<List<DiscourseNotification>> {
  @override
  Future<List<DiscourseNotification>> build() async {
    final service = ref.read(discourseServiceProvider);
    final response = await service.getRecentNotifications();
    return response.notifications;
  }

  /// 添加新通知（由 messageBus 调用）
  /// 高优先级未读通知排在最前
  void addNotification(DiscourseNotification notification) {
    final currentList = state.value;
    if (currentList == null) return;

    // 检查是否已存在
    if (currentList.any((n) => n.id == notification.id)) return;

    final newList = List<DiscourseNotification>.from(currentList);

    // 高优先级且未读 → 插入到位置 0
    // 其他 → 插入到第一个非高优先级或已读通知的位置
    int insertPosition = 0;
    if (!notification.highPriority || notification.read) {
      final nextPosition = newList.indexWhere((n) => !n.highPriority || n.read);
      if (nextPosition != -1) {
        insertPosition = nextPosition;
      }
    }

    newList.insert(insertPosition, notification);
    state = AsyncValue.data(newList);
  }

  /// 根据 messageBus 推送的 recent 字段同步通知列表
  /// 复刻 Discourse 逻辑：更新已读状态 + 移除不在 recent 中的过期通知
  void syncWithRecent(Map<int, bool> readStatusMap) {
    final currentList = state.value;
    if (currentList == null) return;

    // 与 Discourse 对齐：只保留 recent 中存在的通知，同时更新已读状态
    final newList = <DiscourseNotification>[];
    for (final n in currentList) {
      final newRead = readStatusMap[n.id];
      if (newRead != null) {
        newList.add(newRead != n.read ? n.copyWith(read: newRead) : n);
      }
      // 不在 readStatusMap 中的通知被移除（过期）
    }

    if (newList.length != currentList.length ||
        newList.any((n) {
          final old = currentList.firstWhere((o) => o.id == n.id);
          return old.read != n.read;
        })) {
      state = AsyncValue.data(newList);
    }
  }

  /// 标记单个通知为已读
  void markAsRead(int notificationId) {
    state.whenData((list) {
      state = AsyncValue.data(
        list.map((n) {
          if (n.id == notificationId && !n.read) {
            return n.copyWith(read: true);
          }
          return n;
        }).toList(),
      );
    });
  }

  /// 标记所有通知为已读
  Future<void> markAllAsRead() async {
    final service = ref.read(discourseServiceProvider);
    await service.markAllNotificationsRead();

    // 重置通知计数
    ref.read(notificationCountStateProvider.notifier).markAllRead();

    // 更新本地状态
    state.whenData((list) {
      state = AsyncValue.data(list.map((n) => n.copyWith(read: true)).toList());
    });
  }
}

final recentNotificationsProvider =
    AsyncNotifierProvider<
      RecentNotificationsNotifier,
      List<DiscourseNotification>
    >(() {
      return RecentNotificationsNotifier();
    });

import 'package:flutter/material.dart';
import '../common/skeleton.dart';

/// 通知列表骨架屏
class NotificationListSkeleton extends StatelessWidget {
  const NotificationListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: 10,
        itemBuilder: (context, index) => const _NotificationItemSkeleton(),
      ),
    );
  }
}

/// 单个通知项的骨架屏
class _NotificationItemSkeleton extends StatelessWidget {
  const _NotificationItemSkeleton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 头像占位
            Align(alignment: Alignment.center, child: SkeletonCircle(size: 40)),
            // 右上角图标占位
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 1.5,
                  ),
                ),
                child: SkeletonCircle(size: 14),
              ),
            ),
          ],
        ),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: double.infinity, height: 16),
          const SizedBox(height: 4),
          SkeletonBox(width: 150, height: 16),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            Expanded(child: SkeletonBox(width: double.infinity, height: 13)),
            const SizedBox(width: 8),
            SkeletonBox(width: 40, height: 12),
          ],
        ),
      ),
      trailing: SkeletonCircle(size: 8),
    );
  }
}

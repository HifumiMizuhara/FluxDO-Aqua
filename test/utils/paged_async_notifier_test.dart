import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/paged_async_notifier.dart';

final _pagedTestProvider = AsyncNotifierProvider<_PagedTestNotifier, List<int>>(
  _PagedTestNotifier.new,
);

class _PagedTestNotifier extends AsyncNotifier<List<int>>
    with PagedAsyncNotifierMixin<int> {
  bool failNextLoadMore = false;
  int loadMoreCalls = 0;

  final Map<int, List<int>> _responses = const {
    0: [1, 2],
    1: [3],
    2: [],
  };

  @override
  Future<List<int>> build() async {
    resetPagingState();
    return completePagedRefresh(
      PagedPage(items: _responses[0]!, hasMore: true),
    );
  }

  Future<void> loadMore() {
    return runPagedLoadMore((currentItems, nextPage) async {
      loadMoreCalls++;
      if (failNextLoadMore) {
        failNextLoadMore = false;
        throw StateError('load more failed');
      }

      final response = _responses[nextPage] ?? const <int>[];
      return PagedPage(
        items: [...currentItems, ...response],
        hasMore: response.isNotEmpty && nextPage < 2,
        advancePage: response.isNotEmpty,
      );
    });
  }

  Future<void> retryLoadMore() {
    return retryPagedLoadMore(loadMore);
  }
}

void main() {
  ProviderContainer createContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test(
    'runPagedLoadMore advances page only when response is non-empty',
    () async {
      final container = createContainer();
      expect(await container.read(_pagedTestProvider.future), [1, 2]);

      final notifier = container.read(_pagedTestProvider.notifier);
      expect(notifier.currentPage, 0);
      expect(notifier.hasMore, isTrue);

      await notifier.loadMore();
      expect(container.read(_pagedTestProvider).value, [1, 2, 3]);
      expect(notifier.currentPage, 1);
      expect(notifier.hasMore, isTrue);

      await notifier.loadMore();
      expect(container.read(_pagedTestProvider).value, [1, 2, 3]);
      expect(notifier.currentPage, 1);
      expect(notifier.hasMore, isFalse);
    },
  );

  test(
    'runPagedLoadMore keeps previous data on failure and retry reloads',
    () async {
      final container = createContainer();
      expect(await container.read(_pagedTestProvider.future), [1, 2]);

      final notifier = container.read(_pagedTestProvider.notifier);
      notifier.failNextLoadMore = true;

      await notifier.loadMore();
      expect(container.read(_pagedTestProvider).value, [1, 2]);
      expect(notifier.isLoadMoreFailed, isTrue);

      await notifier.loadMore();
      expect(notifier.loadMoreCalls, 1);

      await notifier.retryLoadMore();
      expect(container.read(_pagedTestProvider).value, [1, 2, 3]);
      expect(notifier.isLoadMoreFailed, isFalse);
    },
  );
}

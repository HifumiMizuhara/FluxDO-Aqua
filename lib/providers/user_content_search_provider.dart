import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../models/search_filter.dart';
import '../models/search_result.dart';
import 'core_providers.dart';
import 'search_settings_provider.dart';

/// 用户内容页面搜索状态
class UserContentSearchState {
  /// 是否处于搜索模式
  final bool isSearchMode;

  /// 当前搜索关键词
  final String query;

  /// 搜索过滤条件
  final SearchFilter filter;

  /// 搜索结果列表
  final List<SearchPost> results;

  /// 是否正在加载
  final bool isLoading;

  /// 是否有更多结果
  final bool hasMore;

  /// 加载更多是否失败
  final bool isLoadMoreFailed;

  /// 当前页码
  final int page;

  /// 错误信息
  final String? error;

  const UserContentSearchState({
    this.isSearchMode = false,
    this.query = '',
    this.filter = const SearchFilter(),
    this.results = const [],
    this.isLoading = false,
    this.hasMore = false,
    this.isLoadMoreFailed = false,
    this.page = 1,
    this.error,
  });

  UserContentSearchState copyWith({
    bool? isSearchMode,
    String? query,
    SearchFilter? filter,
    List<SearchPost>? results,
    bool? isLoading,
    bool? hasMore,
    bool? isLoadMoreFailed,
    int? page,
    String? error,
    bool clearError = false,
  }) {
    return UserContentSearchState(
      isSearchMode: isSearchMode ?? this.isSearchMode,
      query: query ?? this.query,
      filter: filter ?? this.filter,
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      isLoadMoreFailed: isLoadMoreFailed ?? this.isLoadMoreFailed,
      page: page ?? this.page,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 用户内容页面搜索 Notifier
class UserContentSearchNotifier extends StateNotifier<UserContentSearchState> {
  final Ref _ref;
  final SearchInType _inType;

  UserContentSearchNotifier(this._ref, this._inType)
    : super(UserContentSearchState(filter: SearchFilter(inType: _inType)));

  /// 进入搜索模式
  void enterSearchMode() {
    state = state.copyWith(isSearchMode: true);
  }

  /// 退出搜索模式，清除搜索状态
  void exitSearchMode() {
    state = UserContentSearchState(filter: SearchFilter(inType: _inType));
  }

  /// 更新搜索关键词（不执行搜索）
  void updateQuery(String query) {
    state = state.copyWith(query: query);
  }

  /// 设置分类过滤
  void setCategory({
    int? categoryId,
    String? categorySlug,
    String? categoryName,
    String? parentCategorySlug,
  }) {
    state = state.copyWith(
      filter: state.filter.copyWith(
        categoryId: categoryId,
        categorySlug: categorySlug,
        categoryName: categoryName,
        parentCategorySlug: parentCategorySlug,
        clearCategory: categoryId == null,
      ),
    );
  }

  /// 设置标签过滤
  void setTags(List<String> tags) {
    state = state.copyWith(filter: state.filter.copyWith(tags: tags));
  }

  /// 切换标签选中状态
  void toggleTag(String tag) {
    final currentTags = List<String>.from(state.filter.tags);
    if (currentTags.contains(tag)) {
      currentTags.remove(tag);
    } else {
      currentTags.add(tag);
    }
    state = state.copyWith(filter: state.filter.copyWith(tags: currentTags));
  }

  /// 移除标签
  void removeTag(String tag) {
    final newTags = state.filter.tags.where((t) => t != tag).toList();
    state = state.copyWith(filter: state.filter.copyWith(tags: newTags));
  }

  /// 设置状态过滤
  void setStatus(SearchStatus? status) {
    state = state.copyWith(
      filter: state.filter.copyWith(
        status: status,
        clearStatus: status == null,
      ),
    );
  }

  /// 设置时间范围
  void setDateRange({DateTime? after, DateTime? before}) {
    state = state.copyWith(
      filter: state.filter.copyWith(
        afterDate: after,
        beforeDate: before,
        clearDateRange: after == null && before == null,
      ),
    );
  }

  /// 清除所有过滤条件
  void clearFilters() {
    state = state.copyWith(filter: state.filter.clear());
  }

  /// 执行搜索
  Future<void> search(String query) async {
    final trimmedQuery = query.trim();

    state = state.copyWith(
      query: trimmedQuery,
      isLoading: true,
      page: 1,
      results: [],
      hasMore: false,
      isLoadMoreFailed: false,
      clearError: true,
    );

    if (trimmedQuery.isEmpty) {
      state = state.copyWith(isLoading: false);
      return;
    }

    try {
      final service = _ref.read(discourseServiceProvider);
      final sortOrder = _ref.read(searchSettingsProvider).sortOrder;

      // 构建完整的搜索查询
      final filterQuery = state.filter.toQueryString();
      String fullQuery = trimmedQuery;
      if (filterQuery.isNotEmpty) {
        fullQuery = '$trimmedQuery $filterQuery';
      }
      if (sortOrder.value != null) {
        fullQuery = '$fullQuery order:${sortOrder.value}';
      }

      final result = await service.search(
        query: fullQuery,
        page: 1,
        typeFilter: 'topic',
      );

      state = state.copyWith(
        results: result.posts,
        hasMore: result.hasMorePosts && result.posts.isNotEmpty,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// 加载更多结果
  Future<void> loadMore() async {
    if (state.isLoading ||
        !state.hasMore ||
        state.query.isEmpty ||
        state.isLoadMoreFailed) {
      return;
    }

    final nextPage = state.page + 1;
    state = state.copyWith(
      isLoading: true,
      isLoadMoreFailed: false,
      page: nextPage,
      clearError: true,
    );

    try {
      final service = _ref.read(discourseServiceProvider);
      final sortOrder = _ref.read(searchSettingsProvider).sortOrder;

      // 构建完整的搜索查询
      final filterQuery = state.filter.toQueryString();
      String fullQuery = state.query;
      if (filterQuery.isNotEmpty) {
        fullQuery = '${state.query} $filterQuery';
      }
      if (sortOrder.value != null) {
        fullQuery = '$fullQuery order:${sortOrder.value}';
      }

      final result = await service.search(
        query: fullQuery,
        page: nextPage,
        typeFilter: 'topic',
      );

      state = state.copyWith(
        results: [...state.results, ...result.posts],
        hasMore: result.hasMorePosts && result.posts.isNotEmpty,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        page: state.page - 1, // 恢复页码
        isLoadMoreFailed: true,
        error: e.toString(),
      );
    }
  }

  Future<void> retryLoadMore() async {
    if (!state.isLoadMoreFailed) return;
    state = state.copyWith(isLoadMoreFailed: false, clearError: true);
    await loadMore();
  }

  /// 使用当前过滤条件重新搜索
  Future<void> refreshWithCurrentFilters() async {
    if (state.query.isNotEmpty) {
      await search(state.query);
    }
  }
}

/// 用户内容搜索 Provider
/// 使用 family 参数区分不同的页面类型
final userContentSearchProvider =
    StateNotifierProvider.family<
      UserContentSearchNotifier,
      UserContentSearchState,
      SearchInType
    >((ref, inType) => UserContentSearchNotifier(ref, inType));

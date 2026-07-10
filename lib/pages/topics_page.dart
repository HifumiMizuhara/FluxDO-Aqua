import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import '../models/topic.dart';
import '../models/category.dart';
import '../providers/discourse_providers.dart';
import '../providers/message_bus_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/pinned_categories_provider.dart';
import 'login_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import '../models/search_filter.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/common/anchor_guard_sliver.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/keyword_filter_hint_bar.dart';
import '../widgets/topic/topic_filter_menu.dart';
import '../widgets/common/topic_badges.dart';
import '../widgets/common/search_capsule.dart';
import '../widgets/topic/category_drawer.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_notification_button.dart';
import '../widgets/common/tag_selection_sheet.dart';
import '../widgets/common/paged_list_footer.dart';
import '../navigation/nav_action_bus.dart';
import '../providers/app_state_refresher.dart';
import '../providers/preferences_provider.dart';
import '../utils/load_more_coordinator.dart';
import '../utils/topic_keyword_filter.dart';
import '../utils/responsive.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/loading_dialog.dart';
import '../widgets/common/fading_edge_scroll_view.dart';
import '../widgets/offline_indicator.dart';
import '../l10n/s.dart';
import '../models/shortcut_binding.dart';
import '../providers/shortcut_provider.dart';
import '../widgets/desktop_refresh_indicator.dart';
import '../services/toast_service.dart';
import '../services/navigation/app_route_observer.dart';
import '../utils/dialog_utils.dart';
import '../utils/platform_utils.dart';

class ScrollToTopNotifier extends StateNotifier<int> {
  ScrollToTopNotifier() : super(0);

  void trigger() => state++;
}

final scrollToTopProvider = StateNotifierProvider<ScrollToTopNotifier, int>((
  ref,
) {
  return ScrollToTopNotifier();
});

/// 顶栏/底栏可见性进度（0.0 = 完全隐藏, 1.0 = 完全显示）
final barVisibilityProvider = StateProvider<double>((ref) => 1.0);

/// FAB 是否处于刷新模式（用户正在向上滚动时为 true）
final fabRefreshModeProvider = StateProvider<bool>((ref) => false);

/// FAB 触发刷新信号
final fabRefreshSignalProvider =
    StateNotifierProvider<ScrollToTopNotifier, int>((ref) {
      return ScrollToTopNotifier();
    });

/// Header 区域常量。
///
/// 顶部 = 常驻工具栏 48px（☰ + 聚合筛选菜单标题「最新 ▾」+ 右簇
/// 🔕(条件)·搜索落位·🔔）。可折叠段三段式：搜索胶囊行 48（折叠时
/// 胶囊 Rect.lerp 连续 morph 缩进常驻行右簇的落位格 —— 头部内
/// "一镜到底"）→ 分类 chips 行 40 → 条件标签行 36。
const _toolbarRowHeight = 48.0;
const _capsuleRowHeight = 48.0;
const _navRowHeight = 40.0;
const _tagsRowHeight = 36.0;

/// 顶栏收放控制器：CoordinatorLayout `enterAlways|snap` 的 Flutter 等价物。
///
/// [offset] ∈ [0, [extent]]，由列表滚动增量驱动（边滚边收，1:1 跟手）；
/// snap/展开只动本 controller 的 offset —— 头部是 overlay 层自行收放，
/// **永不触碰列表 ScrollPosition**，从根上避开旧架构 NestedScrollView
/// coordinator 的整套坑（snap 拽列表、吸附误触发、forcePixels
/// workaround）。
class _HeaderCollapseController extends ChangeNotifier {
  _HeaderCollapseController({
    required TickerProvider vsync,
    required this.onVisibilityChanged,
    required bool locked,
    required double extent,
  }) : _vsync = vsync,
       _locked = locked,
       _extent = extent;

  final TickerProvider _vsync;

  /// 可见性联动（1 - offset/extent），供底栏滑出等外部消费。
  /// 通知发生在滚动回调/动画 tick（build 之外），可同步写 provider。
  final ValueChanged<double> onVisibilityChanged;

  AnimationController? _snapAnim;
  double _offset = 0.0;
  bool _locked;
  double _extent;
  double _lastReportedVisibility = 1.0;

  /// 当前收起量：0 = 全展开，[extent] = 收满
  double get offset => _offset;

  /// 可折叠总量（有自定义 tab=92：胶囊56+筛选行36；无=56：仅胶囊）
  double get extent => _extent;

  set extent(double value) {
    if (_extent == value) return;
    _extent = value;
    // setter 在 build 期被调（_syncTabsIfNeeded 路径），不能同步
    // notify/写 provider —— 头部本帧已随新 widget 配置重建;折叠段变短
    // (清空自定义 tab)时的夹紧与可见性重报都推迟到帧末。
    stopSnap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setOffset(_offset.clamp(0.0, _extent), force: true);
    });
  }

  bool get isSnapping => _snapAnim?.isAnimating ?? false;

  /// hideBarOnScroll 关闭时锁定全展开
  set locked(bool value) {
    if (_locked == value) return;
    _locked = value;
    if (value) {
      stopSnap();
      _setOffset(0.0);
    }
  }

  /// 消化一段列表滚动增量。上限取 min(pixels, 全量)：列表贴顶时头部
  /// 必然全展开（pull-to-refresh 永远发生在展开态，spinner 不会被盖）。
  void handleScrollDelta(double delta, double pixels) {
    if (_locked) return;
    stopSnap();
    final cap = pixels.clamp(0.0, _extent);
    _setOffset((_offset + delta).clamp(0.0, cap));
  }

  /// snap 到全展开(0)或收满([extent])
  void snapTo(double target, {Duration duration = _snapDuration}) {
    if (_locked) return;
    stopSnap();
    if (_offset == target) return;
    final controller = AnimationController(vsync: _vsync, duration: duration);
    _snapAnim = controller;
    final start = _offset;
    controller.addListener(() {
      final t = Curves.easeOutCubic.transform(controller.value);
      _setOffset(start + (target - start) * t);
    });
    controller.forward().whenComplete(() {
      if (identical(_snapAnim, controller)) _snapAnim = null;
      controller.dispose();
    });
  }

  /// 展开头部（切 tab、scrollToTop、关闭折叠偏好时调用）
  void expand({bool animate = true}) {
    if (animate && !_locked) {
      snapTo(0.0);
    } else {
      stopSnap();
      _setOffset(0.0);
    }
  }

  void stopSnap() {
    final anim = _snapAnim;
    if (anim == null) return;
    _snapAnim = null;
    anim.stop();
    anim.dispose();
  }

  static const _snapDuration = Duration(milliseconds: 250);

  void _setOffset(double value, {bool force = false}) {
    if (_offset == value && !force) return;
    _offset = value;
    notifyListeners();
    final visibility = (1.0 - _offset / _extent).clamp(0.0, 1.0);
    // 0.01 节流；端点必须精确送达（底栏全隐/全显判定依赖 0.0/1.0）
    if (visibility != _lastReportedVisibility &&
        ((visibility - _lastReportedVisibility).abs() > 0.01 ||
            visibility == 0.0 ||
            visibility == 1.0)) {
      _lastReportedVisibility = visibility;
      onVisibilityChanged(visibility);
    }
  }

  @override
  void dispose() {
    stopSnap();
    super.dispose();
  }
}

// ─── TopicsPage ───

/// 帖子列表页面 - 分类 Tab + 排序下拉 + 标签 Chips
class TopicsPage extends ConsumerStatefulWidget {
  const TopicsPage({super.key, this.isActive = true});

  /// 是否为底部导航的当前页（分类侧栏的左缘滑手势只在本页激活时生效，
  /// 否则其他 tab 页的左缘滑会误开侧栏）
  final bool isActive;

  @override
  ConsumerState<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends ConsumerState<TopicsPage>
    with TickerProviderStateMixin, RouteAware {
  late TabController _tabController;
  late final ShortcutScopeBinding _tabShortcutBinding = ShortcutScopeBinding(
    ref: ref,
    scope: ShortcutScope.master,
  );
  int _tabLength = 1; // 初始只有"全部"
  int _currentTabIndex = 0;
  List<int> _visiblePinnedIds = []; // 过滤后的可见分类 ID
  ScrollDirection? _lastScrollDirection;

  late final _HeaderCollapseController _headerController;
  bool _invalidateScheduled = false;
  Timer? _pointerScrollIdleTimer;
  bool _pointerScrolling = false;
  bool _isSnapping = false;

  /// 各 tab 列表的滚动控制器。页面持有：snap 通过驱动当前列表实现
  /// 头部+内容一体回弹。
  final Map<int?, ScrollController> _listControllers = {};

  ScrollController _listControllerFor(int? categoryId) =>
      _listControllers.putIfAbsent(categoryId, ScrollController.new);

  /// 分类侧栏：DrawerController 常驻根 Overlay。
  /// 拿到原生抽屉全套手势（左缘拖出、拖拽/甩动关闭、遮罩跟手渐变——
  /// 透明路由版做不到跟手，用户点名），又因挂在根 Overlay 而盖得住
  /// 外层底栏与 FAB（嵌套 Scaffold.drawer 的翻车点）。
  final GlobalKey<DrawerControllerState> _drawerKey =
      GlobalKey<DrawerControllerState>();
  OverlayEntry? _drawerEntry;
  LocalHistoryEntry? _drawerHistoryEntry;

  /// 宿主路由是否被其他页面压顶（详情页等）。drawer entry 在根 Overlay
  /// 里位于路由条目之上，不随路由栈遮挡 —— 压顶期间必须禁用左缘手势，
  /// 否则在详情页上左缘滑会误开首页的分类侧栏。
  bool _routeCovered = false;
  ModalRoute<dynamic>? _subscribedRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _subscribedRoute) {
      if (_subscribedRoute != null) appRouteObserver.unsubscribe(this);
      _subscribedRoute = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _routeCovered = true;
    _drawerEntry?.markNeedsBuild();
  }

  @override
  void didPopNext() {
    _routeCovered = false;
    _drawerEntry?.markNeedsBuild();
  }

  @override
  void initState() {
    super.initState();
    _visiblePinnedIds = ref.read(pinnedCategoriesProvider);
    _tabLength = 1 + _visiblePinnedIds.length;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
    _headerController = _HeaderCollapseController(
      vsync: this,
      locked: !ref.read(preferencesProvider).hideBarOnScroll,
      extent: _collapsibleExtentFor(
        _visiblePinnedIds,
        ref.read(tabTagsProvider(null)),
      ),
      // 同步写入（通知源是滚动回调/动画 tick，不在 build 期），
      // 底栏与头部同帧联动，消除旧架构 postFrameCallback 的滞后一帧
      onVisibilityChanged: (v) =>
          ref.read(barVisibilityProvider.notifier).state = v,
    );
    // Overlay.insert 会 setState，避开首帧 build 期
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _insertDrawerOverlay();
    });
  }

  @override
  void didUpdateWidget(covariant TopicsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      // 左缘滑手势只在本页为当前底部 tab 时启用
      _drawerEntry?.markNeedsBuild();
    }
  }

  void _insertDrawerOverlay() {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null || _drawerEntry != null) return;
    _drawerEntry = OverlayEntry(
      builder: (context) => DrawerController(
        key: _drawerKey,
        alignment: DrawerAlignment.start,
        // 关闭态只剩 ~20px 左缘手势条（translucent，不挡点击）;
        // 其他底部 tab 激活、或本页被详情页等压顶时，连手势条也不留
        enableOpenDragGesture: widget.isActive && !_routeCovered,
        drawerCallback: _handleDrawerToggled,
        child: CategoryDrawer(
          onRequestClose: () => _drawerKey.currentState?.close(),
          onSubscriptionTap: _openCategorySubscription,
          onPinnedSelected: (pinnedIndex) {
            final target = pinnedIndex + 1; // +1: index 0 是"全部"
            if (target < _tabController.length &&
                _tabController.index != target) {
              _tabController.animateTo(target);
            }
          },
        ),
      ),
    );
    overlay.insert(_drawerEntry!);
  }

  /// 抽屉开合联动返回键：开 = 往宿主路由挂 LocalHistoryEntry（Android
  /// 返回键/侧滑返回先关抽屉而不是退页;DrawerController 自带的这套在
  /// Overlay 场景失效 —— 它 ModalRoute.of 到的是 null）。CategoryDrawer
  /// 内部的 Navigator.pop 同样经由该 entry 收敛为"关抽屉"。
  void _handleDrawerToggled(bool isOpened) {
    if (isOpened) {
      final route = ModalRoute.of(context);
      if (route != null && _drawerHistoryEntry == null) {
        _drawerHistoryEntry = LocalHistoryEntry(
          onRemove: () {
            _drawerHistoryEntry = null;
            _drawerKey.currentState?.close();
          },
        );
        route.addLocalHistoryEntry(_drawerHistoryEntry!);
      }
    } else {
      final entry = _drawerHistoryEntry;
      _drawerHistoryEntry = null;
      entry?.remove();
    }
  }

  /// 可折叠量：胶囊行恒在；chips 导航行仅有收藏分类时存在（无收藏时
  /// 只有"全部"+"＋"是空壳，不值得占一行）；标签行仅选了标签时存在
  static double _collapsibleExtentFor(List<int> pinnedIds, List<String> tags) =>
      _capsuleRowHeight +
      (pinnedIds.isEmpty ? 0.0 : _navRowHeight) +
      (tags.isEmpty ? 0.0 : _tagsRowHeight);

  void _registerTabShortcuts() {
    if (!mounted) return;
    _tabShortcutBinding.register(context, {
      ShortcutAction.previousTab: () {
        if (_tabController.index > 0) {
          _tabController.animateTo(_tabController.index - 1);
        }
      },
      ShortcutAction.nextTab: () {
        if (_tabController.index < _tabController.length - 1) {
          _tabController.animateTo(_tabController.index + 1);
        }
      },
    });
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _drawerHistoryEntry?.remove();
    _drawerEntry?.remove();
    _drawerEntry?.dispose();
    _headerController.dispose();
    _pointerScrollIdleTimer?.cancel();
    for (final controller in _listControllers.values) {
      controller.dispose();
    }
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    if (PlatformUtils.isDesktop) {
      _tabShortcutBinding.disposeDeferred();
    }
    super.dispose();
  }

  /// 全局筛选/排序变化时：刷新当前 tab，非活跃 tab 标记 stale
  /// 使用微任务去抖，避免多个参数连续变化时重复请求（如登出时重置筛选+排序+方向）
  void _invalidateTopicTabs(List<int> pinnedIds) {
    if (_invalidateScheduled) return;
    _invalidateScheduled = true;
    Future.microtask(() {
      _invalidateScheduled = false;
      if (!mounted) return;
      final currentCategoryId = _currentCategoryId(pinnedIds);
      // 当前活跃 tab：调用 refresh() 显式设置纯 loading 状态，确保骨架屏显示
      ref.read(topicListProvider(currentCategoryId).notifier).refresh();
      // 非活跃 tab：标记 stale，切换时再刷新
      final staleTabs = <int?>{};
      for (final categoryId in [null, ...pinnedIds]) {
        if (categoryId == currentCategoryId) continue;
        staleTabs.add(categoryId);
      }
      final existing = ref.read(staleTabsProvider);
      ref.read(staleTabsProvider.notifier).state = {...existing, ...staleTabs};
    });
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    if (_currentTabIndex == _tabController.index) return;
    // overlay 头部不属于任何 tab 的滚动系统，切 tab 动画展开：
    // 消除新 tab 列表贴顶时头部收起造成的顶部空隙，也更利于定位
    _headerController.expand();
    setState(() {
      _currentTabIndex = _tabController.index;
    });
    final categoryId = _currentCategoryId();

    // 先处理 stale：在设置 currentTab 之前调用 refresh()，
    // 这样 widget rebuild 时 provider 已处于 loading 状态，不会闪旧数据
    final staleTabs = ref.read(staleTabsProvider);
    if (staleTabs.contains(categoryId)) {
      ref.read(topicListProvider(categoryId).notifier).refresh();
      ref.read(staleTabsProvider.notifier).state = staleTabs.difference({
        categoryId,
      });
    }

    ref.read(currentTabCategoryIdProvider.notifier).state = categoryId;
    ref.read(activeSidebarCategoryIdProvider.notifier).state = categoryId;
  }

  /// 检测 pinnedCategories 变化，重建 TabController
  void _syncTabsIfNeeded(List<int> pinnedIds) {
    final desiredLength = 1 + pinnedIds.length;
    _visiblePinnedIds = pinnedIds;
    if (desiredLength == _tabLength) return;

    final oldIndex = _tabController.index;
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _tabLength = desiredLength;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
    _currentTabIndex = oldIndex < _tabLength ? oldIndex : 0;
    _tabController.index = _currentTabIndex;
  }

  Future<void> _goToLogin() async {
    final result = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const LoginPage()));
    if (result == true && mounted) {
      final loading = LoadingDialog.show(
        context,
        message: context.l10n.common_loadingData,
      );
      try {
        // 等加载弹框完成首帧构建后再刷新 Riverpod provider，避免在
        // OverlayEntry build 过程中触发 ProviderScope markNeedsBuild。
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;

        AppStateRefresher.refreshAll(
          ProviderScope.containerOf(context, listen: false),
        );

        await Future.wait([
          ref.read(currentUserProvider.future),
          ref.read(topicListProvider(null).future),
        ]).timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('[TopicsPage] 登录后刷新失败/超时: $e');
      } finally {
        loading.hide();
      }
    }
  }

  void _showTopicIdDialog(BuildContext context) {
    final controller = TextEditingController();
    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.topics_jumpToTopic),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: context.l10n.topics_topicId,
            hintText: context.l10n.topics_topicIdHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              final id = int.tryParse(controller.text.trim());
              Navigator.pop(context);
              if (id != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TopicDetailPage(
                      topicId: id,
                      autoSwitchToMasterDetail: true,
                    ),
                  ),
                );
              }
            },
            child: Text(context.l10n.topics_jump),
          ),
        ],
      ),
    );
  }

  /// 打开分类侧栏（☰ / chips 行 ＋）。
  ///
  /// 侧栏是常驻根 Overlay 的 [DrawerController]（见 [_insertDrawerOverlay]）：
  /// 原生抽屉手势全套跟手，且盖得住外层底栏与 FAB。
  void _openCategoryDrawer() {
    _drawerKey.currentState?.open();
  }

  Future<void> _openTagSelection() async {
    final categoryId = _currentCategoryId();
    final currentTags = ref.read(tabTagsProvider(categoryId));
    final tagsAsync = ref.read(tagsProvider);
    final availableTags = tagsAsync.when(
      data: (tags) => tags,
      loading: () => <String>[],
      error: (e, s) => <String>[],
    );

    final result = await showAppBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TagSelectionSheet(
        categoryId: categoryId,
        availableTags: availableTags,
        selectedTags: currentTags,
        maxTags: 99,
      ),
    );

    if (result != null && mounted) {
      ref.read(tabTagsProvider(categoryId).notifier).state = result;
    }
  }

  /// 获取当前选中分类 Tab 对应的 Category（仅非"全部"时返回）
  Category? _getCurrentCategory(
    List<int> pinnedIds,
    Map<int, Category>? categoryMap,
  ) {
    if (_currentTabIndex == 0 || categoryMap == null) return null;
    if (_currentTabIndex - 1 >= pinnedIds.length) return null;
    final categoryId = pinnedIds[_currentTabIndex - 1];
    return categoryMap[categoryId];
  }

  /// 获取当前 tab 对应的 categoryId
  int? _currentCategoryId([List<int>? pinnedIds]) {
    if (_currentTabIndex == 0) return null;
    final List<int> ids = pinnedIds ?? _visiblePinnedIds;
    if (_currentTabIndex - 1 < ids.length) {
      return ids[_currentTabIndex - 1];
    }
    return null;
  }

  /// 分类订阅设置：拉起级别选择面板（乐观更新 + 失败回退）。
  /// 入口在聚合筛选菜单内（分类 tab 时出现）—— 独立铃铛按钮与
  /// 工具栏"我的通知"铃铛同框语义打架，菜单条目以文字消歧。
  void _openCategorySubscription(Category category) {
    final overrides = ref.read(categoryNotificationOverridesProvider);
    final effectiveLevel = overrides[category.id] ?? category.notificationLevel;
    final level = CategoryNotificationLevel.fromValue(effectiveLevel);
    showCategoryNotificationLevelSheet(context, level, (newLevel) async {
      final oldLevel = effectiveLevel;
      // 乐观更新
      ref.read(categoryNotificationOverridesProvider.notifier).state = {
        ...ref.read(categoryNotificationOverridesProvider),
        category.id: newLevel.value,
      };
      try {
        final service = ref.read(discourseServiceProvider);
        await service.setCategoryNotificationLevel(
          category.id,
          newLevel.value,
        );
      } catch (_) {
        // 失败时回退
        if (mounted) {
          final current = ref.read(categoryNotificationOverridesProvider);
          if (oldLevel != null) {
            ref.read(categoryNotificationOverridesProvider.notifier).state = {
              ...current,
              category.id: oldLevel,
            };
          } else {
            ref.read(categoryNotificationOverridesProvider.notifier).state =
                Map.from(current)..remove(category.id);
          }
        }
      }
    });
  }

  void _showDismissConfirmDialog(TopicListFilter currentFilter) {
    final label = _dismissLabel(currentFilter);
    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.topics_dismissConfirmTitle),
        content: Text(context.l10n.topics_dismissConfirmContent(label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _doDismiss();
            },
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  String _dismissLabel(TopicListFilter filter) {
    if (filter == TopicListFilter.newTopics) {
      final subset = ref.read(topicNewSubsetProvider);
      switch (subset) {
        case NewSubset.topics:
          return context.l10n.topic_filterNewTopicsShort;
        case NewSubset.replies:
          return context.l10n.topic_filterNewRepliesShort;
        case NewSubset.all:
          return context.l10n.topic_filterNewAllShort;
      }
    }
    return context.l10n.topics_unreadTopics;
  }

  Future<void> _doDismiss() async {
    final categoryId = _currentCategoryId();
    try {
      await ref.read(topicListProvider(categoryId).notifier).dismissAll();
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.common_operationFailed(e.toString()));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 桌面端：注册分类 Tab 切换快捷键（在 build 中确保每次重建都刷新）
    if (PlatformUtils.isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _registerTabShortcuts();
      });
    }

    final topPadding = MediaQuery.of(context).padding.top;
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final allPinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoryMapAsync = ref.watch(categoryMapProvider);
    final categoryMap = categoryMapAsync.value;
    // 过滤掉当前用户无权限访问的分类（不在可见分类集合中的）
    final visibleIds = ref.watch(visibleCategoryIdsProvider);
    final pinnedIds = visibleIds != null
        ? allPinnedIds.where((id) => visibleIds.contains(id)).toList()
        : allPinnedIds;
    final currentFilter = ref.watch(topicFilterProvider);
    _syncTabsIfNeeded(pinnedIds);

    // 监听侧栏分类选中变化，同步切换 tab
    ref.listen(activeSidebarCategoryIdProvider, (prev, next) {
      if (next == null && _tabController.index != 0) {
        _tabController.animateTo(0);
      } else if (next != null) {
        final latestVisibleIds = ref.read(visibleCategoryIdsProvider);
        final latestPinnedIds = ref.read(pinnedCategoriesProvider);
        final effectivePinnedIds = latestVisibleIds != null
            ? latestPinnedIds
                  .where((id) => latestVisibleIds.contains(id))
                  .toList()
            : latestPinnedIds;
        final targetIndex = effectivePinnedIds.indexOf(next);
        if (targetIndex >= 0 && _tabController.index != targetIndex + 1) {
          _tabController.animateTo(targetIndex + 1);
        }
      }
    });

    final currentCategoryId = _currentCategoryId(pinnedIds);
    final currentTags = ref.watch(tabTagsProvider(currentCategoryId));

    // 监听全局筛选/排序变化：刷新当前 tab，清除非活跃 tab 数据
    // 所有全局参数统一聚合在 topicListGlobalParamsSignal 中，
    // 未来新增参数只需在信号 provider 中添加 ref.watch
    ref.listen(topicListGlobalParamsSignal, (_, _) {
      _invalidateTopicTabs(pinnedIds);
    });

    // 关闭滚动折叠时，锁定头部全展开
    ref.listen(preferencesProvider.select((p) => p.hideBarOnScroll), (
      prev,
      next,
    ) {
      _headerController.locked = !next;
    });

    // 监听滚动到顶部的通知：动画展开头部；列表回顶由 _TopicListState
    // 各自监听同一信号处理（overlay 头部与列表滚动已解耦）
    ref.listen(scrollToTopProvider, (previous, next) {
      ref.read(fabRefreshModeProvider.notifier).state = false;
      _headerController.expand();
    });

    // 外部写 barVisibility=1.0（main.dart 切底部 tab、书签工作台退出等）
    // 时同步展开头部，避免"底栏已显示、回到首页头部却还收着"的错位。
    // 页面此时通常在 IndexedStack 后台，直接跳变不做动画。
    ref.listen(barVisibilityProvider, (prev, next) {
      if (next == 1.0 && _headerController.offset > 0) {
        _headerController.expand(animate: false);
      }
    });

    // chips 行随有无收藏、标签行随有无标签动态存在，可折叠量跟着变
    // （setter 的副作用推迟帧末，build 期调用安全）
    _headerController.extent = _collapsibleExtentFor(pinnedIds, currentTags);

    // 聚合筛选菜单（筛选/子过滤/排序/标签/忽略五合一）
    final filterMenu = _buildFilterMenu(isLoggedIn, currentFilter);

    return Listener(
      onPointerDown: (_) => _cancelSnap(cancelPointerScrollSession: true),
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && _shouldHandlePointerScroll(event)) {
          _onPointerScroll(event);
        }
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: ScrollConfiguration(
          // 禁用自动 Scrollbar（TabBarView 多 ScrollPosition 下 Scrollbar
          // 会报错）与 overscroll indicator，保持既有视觉行为
          behavior: ScrollConfiguration.of(
            context,
          ).copyWith(scrollbars: false, overscroll: false),
          child: Stack(
            children: [
              // 列表区全屏，顶部让出常驻区（状态栏 + 紧凑工具栏）的恒定
              // 高度;可折叠段（chips 导航行/标签行）悬浮在列表上方，
              // 收放只动 overlay 自身，不牵动列表布局
              Positioned.fill(
                top: topPadding + _toolbarRowHeight,
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTabPage(null),
                    for (final id in pinnedIds) _buildTabPage(id),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _CollapsibleHeader(
                  controller: _headerController,
                  statusBarHeight: topPadding,
                  toolbarChild: _buildToolbar(isLoggedIn, filterMenu),
                  onSearchTap: _openSearch,
                  bellVisible:
                      isLoggedIn && !Responsive.showNavigationRail(context),
                  collapsibleChild: Column(
                    children: [
                      // 无收藏分类时不显示 chips 行（只有"全部"+"＋"
                      // 是空壳）;分类主入口在 ☰ 侧栏
                      if (pinnedIds.isNotEmpty)
                        _buildNavRow(pinnedIds, categoryMap),
                      if (currentTags.isNotEmpty) _buildTagsRow(currentTags),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 常驻工具栏（48px，永不折叠）。左=☰ 分类侧栏 + 聚合筛选菜单标题
  /// 「最新 ▾」（Reddit `Home ▾` 模式），右=搜索落位格（折叠时张开
  /// 迎接胶囊 morph 成的图标）+ 🔔。图标 glyph 统一默认 24（与全 app
  /// AppBar 一致），compact 密度只收触控目标不缩 glyph;左右缘 8 +
  /// compact 按钮内边 8 = glyph 距屏 16（M3 基线）。
  Widget _buildToolbar(bool isLoggedIn, Widget filterMenu) {
    return SizedBox(
      height: _toolbarRowHeight,
      child: Row(
        children: [
          const SizedBox(width: 8),
          // ☰ 全平台常显：分类侧栏的显性入口（侧栏走根 Navigator
          // 路由，rail/底栏任何布局形态下都可用）
          IconButton(
            icon: const Icon(Symbols.menu_rounded),
            onPressed: _openCategoryDrawer,
            tooltip: context.l10n.topics_browseCategories,
            visualDensity: VisualDensity.compact,
          ),
          filterMenu,
          const Spacer(),
          // 搜索落位格：展开态零宽（右簇紧凑无空洞），折叠时随 morph
          // 同曲线张开迎接胶囊缩成的图标（胶囊本体在
          // _CollapsibleHeader 的 overlay 层绘制，这里只占位）
          _SearchSlotSpacer(controller: _headerController),
          if (isLoggedIn && !Responsive.showNavigationRail(context))
            const NotificationIconButton(compact: true),
          if (kDebugMode)
            IconButton(
              icon: const Icon(Symbols.bug_report_rounded),
              visualDensity: VisualDensity.compact,
              onPressed: () => _showTopicIdDialog(context),
              tooltip: context.l10n.topics_debugJump,
            ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  void _openSearch() {
    final pinnedIds = _visiblePinnedIds;
    final categoryMap = ref.read(categoryMapProvider).value;
    final currentCategory = _getCurrentCategory(pinnedIds, categoryMap);
    SearchFilter? filter;
    if (currentCategory != null) {
      String? parentSlug;
      if (currentCategory.parentCategoryId != null) {
        parentSlug = categoryMap?[currentCategory.parentCategoryId]?.slug;
      }
      filter = SearchFilter(
        categoryId: currentCategory.id,
        categorySlug: currentCategory.slug,
        categoryName: currentCategory.name,
        parentCategorySlug: parentSlug,
      );
    }
    // fade 路由：全局 Cupertino 滑动转场会带着整页横移，毁掉胶囊 →
    // 搜索框的 Hero morph（一镜到底）;搜索页单独用淡入配合 Hero 飞行
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, _, _) =>
            SearchPage(initialFilter: filter, heroCapsule: true),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  /// 分类 chips 导航行（可折叠段，40px，仅有收藏分类时存在）：
  /// 全部 + 收藏分类 + ＋。TabBar 降为 chips（YouTube 首页同款），
  /// 与 TabBarView 仍由 _tabController 双向同步；＋ 打开分类侧栏
  /// （分类主入口，订阅设置也在侧栏分类行上）。
  Widget _buildNavRow(List<int> pinnedIds, Map<int, Category>? categoryMap) {
    return SizedBox(
      height: _navRowHeight,
      child: FadingEdgeScrollView(
        child: _CategoryChipsRow(
          tabController: _tabController,
          pinnedIds: pinnedIds,
          categoryMap: categoryMap,
          onReselect: () => ref.read(scrollToTopProvider.notifier).trigger(),
          onManageCategories: _openCategoryDrawer,
        ),
      ),
    );
  }

  /// 已选标签行（可折叠段，仅选了标签时存在）：chips + 紧凑 ＋
  Widget _buildTagsRow(List<String> currentTags) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentCategoryId = _currentCategoryId();
    return SizedBox(
      height: _tagsRowHeight,
      child: Align(
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              for (final tag in currentTags)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: RemovableTagBadge(
                    name: tag,
                    onDeleted: () {
                      final tags = ref.read(tabTagsProvider(currentCategoryId));
                      ref
                          .read(tabTagsProvider(currentCategoryId).notifier)
                          .state = tags
                          .where((t) => t != tag)
                          .toList();
                    },
                    size: const BadgeSize(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      radius: 6,
                      iconSize: 12,
                      fontSize: 12,
                    ),
                  ),
                ),
              InkWell(
                onTap: _openTagSelection,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Symbols.add_rounded,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 聚合筛选菜单按钮。用 Consumer 局部订阅排序/子过滤状态，收放轻壳
  /// 与 State 整树都不因排序变化而重建。
  Widget _buildFilterMenu(bool isLoggedIn, TopicListFilter currentFilter) {
    final showDismiss =
        isLoggedIn &&
        (currentFilter == TopicListFilter.newTopics ||
            currentFilter == TopicListFilter.unread);
    return Consumer(
      builder: (context, ref, _) {
        final order = ref.watch(topicSortOrderProvider);
        final ascending = ref.watch(topicSortAscendingProvider);
        final subset = ref.watch(topicNewSubsetProvider);
        final tagCount = ref
            .watch(tabTagsProvider(_currentCategoryId()))
            .length;
        return TopicFilterMenuButton(
          currentFilter: currentFilter,
          isLoggedIn: isLoggedIn,
          titleStyle: true,
          onFilterChanged: (filter) {
            ref.read(topicFilterProvider.notifier).setFilter(filter);
          },
          currentSubset: subset,
          onSubsetChanged: (s) =>
              ref.read(topicNewSubsetProvider.notifier).setSubset(s),
          currentOrder: order,
          ascending: ascending,
          onOrderChanged: (o) =>
              ref.read(topicSortOrderProvider.notifier).setOrder(o),
          onToggleAscending: () =>
              ref.read(topicSortAscendingProvider.notifier).toggle(),
          onSelectTags: _openTagSelection,
          selectedTagCount: tagCount,
          onDismissAll: showDismiss
              ? () => _showDismissConfirmDialog(currentFilter)
              : null,
        );
      },
    );
  }

  bool _shouldHandlePointerScroll(PointerScrollEvent event) {
    if (kIsWeb) return false;
    if (!Platform.isMacOS) return false;
    final dx = event.scrollDelta.dx.abs();
    final dy = event.scrollDelta.dy.abs();
    return dy > dx;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    // 只关心列表的垂直滚动；TabBarView 横滑/TabBar/标签条横向滚动
    // （axis horizontal）全部排除
    if (notification.metrics.axis != Axis.vertical) {
      // TabBarView 横滑起步即展开头部：滑入的相邻 tab 列表若贴顶，
      // 其滚动深度可能小于头部收起量，会在顶部露出空隙；提前展开
      // 消除（PageMetrics 判别排除 TabBar/标签条自身的横向滚动）
      if (notification is ScrollStartNotification &&
          notification.metrics is PageMetrics &&
          _headerController.offset > 0) {
        _headerController.expand();
      }
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      // 边滚边收：滚动增量 1:1 驱动头部收放（CoordinatorLayout
      // enterAlways 同款跟手感），列表位置不受任何反向影响
      final delta = notification.scrollDelta;
      final metrics = notification.metrics;
      // 底部越界回弹免疫：滚过 maxScrollExtent（iOS 弹性 + 触底加载
      // 的 overscroll）后弹簧回弹是一串负向 delta，会被误读成"用户
      // 向上滚"→ header/底栏无故展开。位移起点或终点在越界区的
      // delta 一律不喂（顶部越界已有 offset≤pixels 的 cap 免疫）。
      final beyondBottom =
          metrics.pixels > metrics.maxScrollExtent ||
          (delta != null &&
              metrics.pixels - delta > metrics.maxScrollExtent);
      if (delta != null && delta != 0 && !beyondBottom) {
        _headerController.handleScrollDelta(delta, metrics.pixels);
      }
      // 发布"距顶进度"到 NavActionBus，底栏据此做动态图标切换
      _publishHomeScrollProgress(metrics.pixels);

      // 列表到达顶部时恢复创建模式
      if (metrics.pixels <= 0 && ref.read(fabRefreshModeProvider)) {
        ref.read(fabRefreshModeProvider.notifier).state = false;
      }
    }

    // 用 UserScrollNotification 追踪用户主动滚动方向，避免回弹/惯性误触发
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.forward) {
        _lastScrollDirection = ScrollDirection.forward;
        // 向上滚动（朝顶部方向）→ 刷新模式
        if (!ref.read(fabRefreshModeProvider)) {
          ref.read(fabRefreshModeProvider.notifier).state = true;
        }
      } else if (notification.direction == ScrollDirection.reverse) {
        _lastScrollDirection = ScrollDirection.reverse;
        // 向下滚动（深入列表）→ 创建模式
        if (ref.read(fabRefreshModeProvider)) {
          ref.read(fabRefreshModeProvider.notifier).state = false;
        }
      }
    }

    // 拖拽滚动开始时，清理 pointer scroll 的状态，避免影响松手吸附
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _pointerScrollIdleTimer?.cancel();
      _pointerScrolling = false;
    }

    if (notification is ScrollEndNotification) {
      // macOS 鼠标滚轮会产生大量离散的 ScrollEnd，若每次都立即
      // snap 会反复吸附抖动;pointer scrolling 期间跳过，改由
      // onPointerSignal 的 idle 定时器统一触发一次
      if (_pointerScrolling) return false;
      // ScrollEnd 是在 beginActivity() 内部【同步】派发的（SDK 顺序:
      // didEndScroll → 旧 activity.dispose → 换新）。此刻直接 animateTo,
      // 新建的动画 activity 会被外层 beginActivity 随手 dispose —— snap
      // 胎死腹中,触屏上表现为"根本没有吸附"。挪到帧末执行,旧架构同款
      // 时序。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _snapHeader();
      });
    }

    return false;
  }

  void _onPointerScroll(PointerScrollEvent event) {
    _headerController.stopSnap();
    _pointerScrolling = true;
    _pointerScrollIdleTimer?.cancel();
    final delay = event.kind == PointerDeviceKind.mouse
        ? const Duration(milliseconds: 450)
        : const Duration(milliseconds: 250);
    _pointerScrollIdleTimer = Timer(delay, () {
      _pointerScrolling = false;
      if (!mounted) return;
      _snapHeader(preferDirection: true);
    });
  }

  /// 取消正在进行的 snap
  void _cancelSnap({bool cancelPointerScrollSession = false}) {
    if (cancelPointerScrollSession) {
      _pointerScrollIdleTimer?.cancel();
      _pointerScrolling = false;
    }
    _headerController.stopSnap();
  }

  /// 松手吸附：Telegram 式一体回弹。
  ///
  /// snap 通过**当前列表的 animateTo** 驱动：滚动增量经
  /// [_HeaderCollapseController.handleScrollDelta] 同步带动头部收放，
  /// 内容与头部一体移动、首行可见位置（pixels - offset）不变。
  /// 小幅滑动未过半 → 整体弹回原位（这次滑动如同没发生）；
  /// 过半 → 一体收满。没有"头部单独动"造成的脱节感。
  ///
  /// [preferDirection] 为 true（滚轮/触控板路径）时优先按最近滚动方向
  /// 决定目标：向下则收起，向上则展开；无方向记录再退回过半规则。
  void _snapHeader({bool preferDirection = false}) {
    if (_isSnapping || _headerController.isSnapping) return;
    final offset = _headerController.offset;
    final extent = _headerController.extent;
    if (offset <= 0 || offset >= extent) return;

    double target;
    if (preferDirection && _lastScrollDirection == ScrollDirection.reverse) {
      target = extent;
    } else if (preferDirection &&
        _lastScrollDirection == ScrollDirection.forward) {
      target = 0.0;
    } else {
      target = offset > extent / 2 ? extent : 0.0;
    }

    final controller = _listControllers[_currentCategoryId()];
    if (controller == null ||
        !controller.hasClients ||
        controller.positions.length != 1) {
      // 拿不到当前列表（理论不发生）：退化为头部单独展开，不碰内容
      if (target == 0.0) _headerController.snapTo(0.0);
      return;
    }

    final position = controller.position;
    if (target > offset &&
        position.maxScrollExtent - position.pixels < target - offset) {
      // 列表剩余滚动量不足以收满（短列表），改为弹回展开
      target = 0.0;
    }
    final delta = target - offset;
    if (delta == 0) return;
    _snapListBy(controller, delta);
  }

  Future<void> _snapListBy(ScrollController controller, double delta) async {
    _isSnapping = true;
    try {
      await controller.animateTo(
        controller.position.pixels + delta,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    } finally {
      _isSnapping = false;
    }
  }

  void _publishHomeScrollProgress(double pixels) {
    final progress = pixels < 0 ? 0.0 : pixels;
    final current = ref.read(navScrollProgressProvider(NavEntryIds.home));
    // 节流：变化 >= 4 像素 才更新；或跨越"回顶"阈值 / 过 0 时立即同步
    final atZero = progress == 0 && current != 0;
    final crossed =
        (progress >= navScrollIconThreshold) !=
        (current >= navScrollIconThreshold);
    if (!atZero && !crossed && (progress - current).abs() < 4.0) return;
    ref.read(navScrollProgressProvider(NavEntryIds.home).notifier).state =
        progress;
  }

  /// 构建单个 tab 页面（带水平间距，圆角裁剪在列表内部处理）
  Widget _buildTabPage(int? categoryId) {
    // 每个 tab 的顶部 inset 跟随各自的标签行有无（与头部可折叠量的
    // 计算同源，该 tab 激活时两者必然一致）
    final tags = ref.watch(tabTagsProvider(categoryId));
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 12),
      child: _TopicList(
        key: ValueKey(categoryId),
        categoryId: categoryId,
        scrollController: _listControllerFor(categoryId),
        topInset: _collapsibleExtentFor(_visiblePinnedIds, tags),
        onLoginRequired: _goToLogin,
      ),
    );
  }
}

// ─── Collapsible Header ───

/// overlay 顶栏：状态栏 + 常驻工具栏（☰ + 筛选标题 + 🔕·搜索落位·🔔）
/// + 可折叠段（搜索胶囊行 → 分类 chips 行 → 条件标签行）。
///
/// ## 胶囊 morph（头部内一镜到底）
///
/// 胶囊不放在 Column 流里，而是 Stack overlay 层用 [Rect.lerp] 连续
/// 定位：展开态 = 胶囊行内整行胶囊（40 高、圆角 20），折叠第一段
/// (p1: 0→1) 中收缩宽度、上移，最终停进工具栏右簇的 40×40 落位格 ——
/// 圆角恒定 20，宽度收到 40 时自然成圆形图标；hint 文字随 p1 淡出。
/// Column 里只放一个高度随 p1 收缩的占位，chips/标签段在其下方
/// 正常折叠（p2/p3）。
///
/// 两端 rect 全由行高/边距常量推算（不做运行时测量）：
/// - 起点：left 12, top 状态栏+工具栏+4, size (W-24)×40
/// - 终点：工具栏右簇落位格。从右往左：8(右缘) + [debug 40] +
///   [🔔 40] + 4(间隔) → 落位格右缘；top = 状态栏+(48-40)/2。
///   落位格是否有 🔔/debug 由 [bellVisible] 传入。
///
/// 收放由 [_HeaderCollapseController] 驱动，ListenableBuilder 每帧只
/// 重组轻壳与 rect；工具栏/chips 等重 child 由 State.build 预构建，
/// identical 短路。
class _CollapsibleHeader extends StatelessWidget {
  const _CollapsibleHeader({
    required this.controller,
    required this.statusBarHeight,
    required this.toolbarChild,
    required this.collapsibleChild,
    required this.onSearchTap,
    required this.bellVisible,
  });

  final _HeaderCollapseController controller;
  final double statusBarHeight;

  /// 常驻工具栏（含 40×40 搜索落位空格）
  final Widget toolbarChild;

  /// 可折叠段（chips 导航行 + 条件标签行；胶囊行由本组件负责）
  final Widget collapsibleChild;

  final VoidCallback onSearchTap;

  /// 工具栏右簇是否有 🔔（决定落位格的横向位置）
  final bool bellVisible;

  @override
  Widget build(BuildContext context) {
    final bgColor = Theme.of(context).scaffoldBackgroundColor;

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final offset = controller.offset;
        // 三段折叠进度：胶囊行(0-48) → chips 行(48-88) → 标签行(88-)
        final p1 = (offset / _capsuleRowHeight).clamp(0.0, 1.0);
        final rest = offset - _capsuleRowHeight;
        final restExtent = controller.extent - _capsuleRowHeight;
        final pRest = restExtent <= 0
            ? 0.0
            : (rest / restExtent).clamp(0.0, 1.0);

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            // morph 两端 rect（常量推算，见类文档）
            final expandedRect = Rect.fromLTWH(
              12,
              statusBarHeight + _toolbarRowHeight + 4,
              width - 24,
              40,
            );
            // 右簇（从右缘往左）：8 边距 + [debug 40] + [🔔 40]（compact
            // IconButton 触控目标 40，glyph 24）；再往左是落位 spacer
            // （满宽 44 = 40 图标格 + 4 呼吸位），图标格贴住 🔔 左缘
            final debugW = kDebugMode ? 40.0 : 0.0;
            final bellW = bellVisible ? 40.0 : 0.0;
            final slotRight = width - 8 - debugW - bellW;
            final collapsedRect = Rect.fromLTWH(
              slotRight - 40,
              statusBarHeight + (_toolbarRowHeight - 40) / 2,
              40,
              40,
            );
            final t = Curves.easeInOutCubic.transform(p1);
            final capsuleRect = Rect.lerp(expandedRect, collapsedRect, t)!;

            return Stack(
              children: [
                Column(
                  children: [
                    // 背景色只垫到头部实体（窗檐在其下方，需要中间透出
                    // 列表内容，不能被整块背景垫死）
                    ColoredBox(
                      color: bgColor,
                      child: Column(
                        children: [
                          SizedBox(height: statusBarHeight),
                          // 常驻工具栏（搜索落位格在其右簇内空置）
                          toolbarChild,
                          // 胶囊行占位：高度随 p1 收缩（胶囊本体在 overlay 层）
                          SizedBox(height: _capsuleRowHeight * (1.0 - p1)),
                          // chips/标签段（完全折叠后跳过子树构建）
                          if (pRest < 1.0)
                            ClipRect(
                              child: Align(
                                alignment: Alignment.topCenter,
                                heightFactor: 1.0 - pRest,
                                child: Opacity(
                                  opacity: 1.0 - pRest,
                                  child: collapsibleChild,
                                ),
                              ),
                            ),
                          // 离线提示条：并入头部下缘，在线时零高
                          const OfflineIndicator(),
                        ],
                      ),
                    ),
                    // 列表圆角窗檐：头部下缘的内凹圆角遮罩。列表自身的
                    // ClipRRect 固定在 viewport 顶（工具栏下缘），展开态
                    // 被可折叠段盖住 —— 内容滑入头部下方时上缘露直角。
                    // 此层跟随头部下缘裁出顶部圆角（收起态与列表
                    // ClipRRect 重合，无副作用）
                    const _ListCornerShim(),
                  ],
                ),
                // 胶囊 morph 层（Hero 起点：跨页一镜到底的另一段）
                Positioned.fromRect(
                  rect: capsuleRect,
                  child: Hero(
                    tag: kSearchCapsuleHeroTag,
                    flightShuttleBuilder: searchCapsuleFlightShuttle,
                    child: SearchCapsule(
                      onTap: onSearchTap,
                      hintOpacity: (1.0 - t * 1.6).clamp(0.0, 1.0),
                      // 落位后 glyph 24（与 🔔 等同大）;左内边同步收
                      // 使图标在 40 格内居中 (40-24)/2=8
                      iconSize: 20 + 4 * t,
                      iconLeftPadding: 16 - 8 * t,
                      // 收尾阶段灰底渐隐：落位后是纯图标，与 🔔 等
                      // 裸图标按钮同族（带色块停在图标簇里很突兀）
                      backgroundOpacity: (1.0 - (t - 0.55) / 0.4).clamp(
                        0.0,
                        1.0,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 头部下缘的"列表圆角窗檐"：12px 高，画背景色 + 左右上角 12 圆角的
/// 内凹镂空。列表内容滑到头部下方时，从镂空里露出来的部分天然带
/// 顶部圆角 —— 等效于列表 ClipRRect 的圆角跟着头部下缘走。
class _ListCornerShim extends StatelessWidget {
  const _ListCornerShim();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 12),
      painter: _ListCornerShimPainter(
        Theme.of(context).scaffoldBackgroundColor,
      ),
    );
  }
}

class _ListCornerShimPainter extends CustomPainter {
  _ListCornerShimPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 整条背景减去"左右 12 边距 + 上圆角 12 的圆角矩形"，得到窗檐形
    // （列表水平内边距 12 与 _topBorderRadius 12 同参）
    final outer = Path()..addRect(Offset.zero & size);
    final inner = Path()
      ..addRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(12, 0, size.width - 24, size.height),
          topLeft: const Radius.circular(12),
          topRight: const Radius.circular(12),
        ),
      );
    final shim = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(shim, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ListCornerShimPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 工具栏搜索落位 spacer：展开态零宽（右簇紧凑无空洞），随折叠进度
/// 张开到 44px（40 图标格 + 4 间隔），与胶囊 morph 同曲线 —— 🔔 等
/// 右侧成员不动（Spacer 吸收），左侧的分类铃铛被自然推开。
class _SearchSlotSpacer extends StatelessWidget {
  const _SearchSlotSpacer({required this.controller});

  final _HeaderCollapseController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final p1 = (controller.offset / _capsuleRowHeight).clamp(0.0, 1.0);
        final t = Curves.easeInOutCubic.transform(p1);
        return SizedBox(width: 44 * t);
      },
    );
  }
}

/// 分类 chips 导航行：全部 + 已 pin 分类 + ＋（管理入口）。
///
/// 与 [TabBarView] 共用同一个 [TabController]：点 chip →
/// animateTo(index)；横滑列表 → 监听 controller.animation 高亮跟手
/// 迁移（用四舍五入的 index 判定，滑过半即切换选中态，无需等
/// settle）。选中 chip 重复点击触发 [onReselect]（回顶）。
///
/// chip 内不挂任何随选中态增减的附件（曾试过选中 chip 尾部长订阅
/// 铃铛：宽度随选中迁移变化，整行弹宽必抖，已废）——分类的操作
/// （订阅/收藏）统一在 ☰ 侧栏的分类行上。
class _CategoryChipsRow extends StatelessWidget {
  const _CategoryChipsRow({
    required this.tabController,
    required this.pinnedIds,
    required this.categoryMap,
    required this.onReselect,
    required this.onManageCategories,
  });

  final TabController tabController;
  final List<int> pinnedIds;
  final Map<int, Category>? categoryMap;
  final VoidCallback onReselect;
  final VoidCallback onManageCategories;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      S.current.common_all,
      for (final id in pinnedIds) categoryMap?[id]?.name ?? '...',
    ];

    return AnimatedBuilder(
      animation: tabController.animation ?? tabController,
      builder: (context, _) {
        final selected = (tabController.animation?.value ?? 0).round().clamp(
          0,
          labels.length - 1,
        );
        return ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _CategoryChip(
                  label: labels[i],
                  selected: i == selected,
                  onTap: () {
                    if (i == tabController.index) {
                      onReselect();
                    } else {
                      tabController.animateTo(i);
                    }
                  },
                ),
              ),
            // ＋：分类管理入口（pin/调序/订阅都在侧栏里）
            _CategoryChip(
              label: '＋',
              selected: false,
              isAction: true,
              tooltip: S.current.topics_browseCategories,
              onTap: onManageCategories,
            ),
          ],
        );
      },
    );
  }
}

/// 单个分类 chip：药丸形（YouTube 首页同款）——选中 = onSurface 反色
/// 填充 + 加粗，未选中 = surfaceContainerHigh 灰底；[isAction] 的 ＋
/// 入口用更淡的底色与次级前景，视觉上是"操作"不是"分类"
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.isAction = false,
    this.tooltip,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool isAction;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    if (selected) {
      bg = colorScheme.onSurface;
      fg = colorScheme.surface;
    } else if (isAction) {
      bg = colorScheme.surfaceContainerHighest.withValues(alpha: 0.35);
      fg = colorScheme.onSurfaceVariant.withValues(alpha: 0.8);
    } else {
      bg = colorScheme.surfaceContainerHigh;
      fg = colorScheme.onSurface.withValues(alpha: 0.85);
    }
    final chip = Material(
      color: bg,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              height: 1.0,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ),
    );
    final sized = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: chip,
    );
    return tooltip == null ? sized : Tooltip(message: tooltip!, child: sized);
  }
}

// ─── TopicList ───

/// 话题列表（每个 tab 一个实例，根据 categoryId + topicFilterProvider 获取数据）
class _TopicList extends ConsumerStatefulWidget {
  final VoidCallback onLoginRequired;
  final int? categoryId;

  /// 页面持有的滚动控制器（snap 需要从页面驱动当前列表）
  final ScrollController scrollController;

  /// 顶部恒定 inset（悬浮可折叠段的高度，随有无自定义 tab 变化）
  final double topInset;

  const _TopicList({
    super.key,
    required this.onLoginRequired,
    required this.scrollController,
    required this.topInset,
    this.categoryId,
  });

  @override
  ConsumerState<_TopicList> createState() => _TopicListState();
}

class _TopicListState extends ConsumerState<_TopicList>
    with AutomaticKeepAliveClientMixin {
  final _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();

  /// overlay 头部架构下无 NestedScrollView 注入的 PrimaryScrollController，
  /// 回顶/键盘导航都走页面下发的控制器
  ScrollController get _scrollController => widget.scrollController;
  late final ShortcutScopeBinding _listShortcutBinding = ShortcutScopeBinding(
    ref: ref,
    scope: ShortcutScope.master,
  );
  bool _isLoadingNewTopics = false;

  /// 需要高亮的话题 IDs（loadBefore 插入后设置，渐变消失后清除）
  final Set<int> _highlightedTopicIds = {};

  /// 话题卡片实例缓存(key: topic.id):返回本页(pop)或任意 provider
  /// 更新引发的整列表 rebuild 中,输入未变的卡片直接复用实例,框架在
  /// Element.updateChild 处整棵短路(诊断数据:pop 返回列表后整页
  /// rebuild 单次 35~45ms,大头是可见卡片全量重建)。Topic 为不可变
  /// 数据,引用同即内容同;卡片外观偏好由 TopicCard 内部 Consumer
  /// 自行订阅,复用实例不影响其响应。theme/断点变化时整体失效。
  final Map<int, ({Object signature, Widget widget})> _topicItemCache = {};

  /// keyed reconcile 的行 key 常量(pill/提示条/footer 三个固定行)
  static const _pillKeyValue = 'topics-pill';
  static const _filterHintKeyValue = 'topics-filter-hint';
  static const _footerKeyValue = 'topics-footer';

  /// topic.id → 可见列表 index,供 findChildIndexCallback O(1) 反查。
  /// 行 key 化 + 该回调是列表版"锚定"的身份基础:顶部插入新话题 / pill
  /// 出现导致全列表 index 平移时,Element/RenderObject 跟随 topic.id
  /// 迁移而不是按 index 换内容(无 key 时视口内每行会"换脸"成上一条),
  /// 迁移残留的布局位移再由列表尾部的 AnchorGuardSliver 同帧修正。
  List<Topic>? _visibleIndexSource;
  Map<int, int> _topicIdToVisibleIndex = const {};

  /// 上次 build 的列表头部行数(pill/过滤提示),变化 = 行 index 平移
  int? _lastHeaderOffset;

  Map<int, int> _visibleIndexMapFor(List<Topic> topics) {
    if (!identical(_visibleIndexSource, topics)) {
      final hadPrevious = _visibleIndexSource != null;
      _visibleIndexSource = topics;
      _topicIdToVisibleIndex = <int, int>{
        for (var i = 0; i < topics.length; i++) topics[i].id: i,
      };
      // 列表数据换代(顶部插入/全量替换/单行刷新):静默结构变化落地帧,
      // 武装锚定哨兵补偿 keyed 迁移产生的位移。首建不武装。
      if (hadPrevious) {
        AnchorGuardSliver.arm();
      }
    }
    return _topicIdToVisibleIndex;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _topicItemCache.clear();
  }

  /// 本地缓存的话题数据，非当前 tab 时使用此缓存渲染，不订阅 provider
  AsyncValue<List<Topic>>? _cachedTopicsAsync;

  /// 键盘焦点索引（J/K 导航用）
  int _keyboardFocusIndex = -1;

  /// J/K 防抖：上次触发时间
  DateTime _lastKeyNavTime = DateTime(0);

  final TopicLoadMoreCoordinator _loadMoreCoordinator =
      TopicLoadMoreCoordinator();
  List<String> _lastAutoLoadKeywords = const [];
  Set<String> _lastAutoLoadBlockedUsernames = const <String>{};
  bool? _lastAutoLoadWholeWord;

  @override
  bool get wantKeepAlive => true;

  /// 列表区域顶部圆角
  static const _topBorderRadius = BorderRadius.only(
    topLeft: Radius.circular(12),
    topRight: Radius.circular(12),
  );

  /// overlay 头部可折叠段悬浮在列表上方，列表内容顶部让出的恒定 inset
  double get _headerInset => widget.topInset;

  void scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 清除当前 tab 的高亮和"新话题"计数
  void _clearIncomingState() {
    _highlightedTopicIds.clear();
    ref
        .read(latestChannelProvider.notifier)
        .clearNewTopicsForCategory(widget.categoryId);
  }

  /// J/K 键盘导航：移动焦点（含 150ms 防抖）
  void _moveKeyboardFocus(int delta, AsyncValue<List<Topic>> topicsAsync) {
    final now = DateTime.now();
    if (now.difference(_lastKeyNavTime).inMilliseconds < 150) return;
    _lastKeyNavTime = now;

    final topics = topicsAsync.asData?.value;
    if (topics == null || topics.isEmpty) return;

    final anchorIndex = _resolveKeyboardAnchorIndex(topics);
    final newIndex = (anchorIndex + delta).clamp(0, topics.length - 1);
    if (newIndex == _keyboardFocusIndex) return;

    setState(() => _keyboardFocusIndex = newIndex);

    final topic = topics[newIndex];
    _openTopic(topic);

    // 滚动到可见区域
    if (_scrollController.hasClients) {
      // 估算位置（顶部 inset + 每个 item 约 80px 高度）
      final estimatedPosition = _headerInset + newIndex * 80.0;
      final viewport = _scrollController.position.viewportDimension;
      final current = _scrollController.position.pixels;

      if (estimatedPosition < current ||
          estimatedPosition > current + viewport - 80) {
        _scrollController.animateTo(
          estimatedPosition.clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  /// Enter 键打开当前焦点话题
  void _openFocusedTopic(AsyncValue<List<Topic>> topicsAsync) {
    final topics = topicsAsync.asData?.value;
    if (topics == null || topics.isEmpty) return;
    final focusIndex = _resolveKeyboardAnchorIndex(topics);
    if (focusIndex < 0 || focusIndex >= topics.length) return;

    final topic = topics[focusIndex];
    // 强制用 Navigator push 打开（而非 Master-Detail 内选中）
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
        ),
      ),
    );
  }

  int _resolveKeyboardAnchorIndex(List<Topic> topics) {
    final selectedTopicId = ref.read(selectedTopicProvider).topicId;
    final selectedIndex = selectedTopicId == null
        ? -1
        : topics.indexWhere((topic) => topic.id == selectedTopicId);

    if (_keyboardFocusIndex >= 0 && _keyboardFocusIndex < topics.length) {
      if (selectedIndex != -1 &&
          topics[_keyboardFocusIndex].id != selectedTopicId) {
        return selectedIndex;
      }
      return _keyboardFocusIndex;
    }

    if (selectedIndex != -1) {
      return selectedIndex;
    }

    return -1;
  }

  void _syncKeyboardFocusToIndex(int index) {
    if (_keyboardFocusIndex == index) return;
    setState(() => _keyboardFocusIndex = index);
  }

  /// 触发 loadMore，并在关键词命中率高、可见增量不足时自动续加载，
  /// 避免用户在话题列表里看到「滑到底但只多了 1-2 条」。
  Future<void> _triggerLoadMore(int? providerKey) async {
    final notifier = ref.read(topicListProvider(providerKey).notifier);

    final prefs = ref.read(preferencesProvider);
    final keywords = prefs.normalizedFilterKeywords;
    final wholeWord = prefs.topicFilterWholeWord;
    final blockedUsernames = prefs.normalizedBlockedUsernames;

    int itemCount() {
      return ref.read(topicListProvider(providerKey)).value?.length ?? 0;
    }

    int visibleItemCount() {
      final raw =
          ref.read(topicListProvider(providerKey)).value ?? const <Topic>[];
      final (visible, _, _) = TopicKeywordFilter.apply(
        raw,
        normalizedKeywords: keywords,
        wholeWord: wholeWord,
        blockedUsernames: blockedUsernames,
      );
      return visible.length;
    }

    await _loadMoreCoordinator.loadTopicPage(
      loadMore: notifier.loadMore,
      hasMore: () => notifier.hasMore,
      isActive: () => mounted,
      itemCount: itemCount,
      visibleItemCount: visibleItemCount,
      hasKeywordFilter: keywords.isNotEmpty || blockedUsernames.isNotEmpty,
    );
  }

  void _syncAutoLoadFilter(
    List<String> keywords,
    bool wholeWord,
    Set<String> blockedUsernames,
  ) {
    if (listEquals(_lastAutoLoadKeywords, keywords) &&
        _lastAutoLoadWholeWord == wholeWord &&
        setEquals(_lastAutoLoadBlockedUsernames, blockedUsernames)) {
      return;
    }
    _lastAutoLoadKeywords = List.unmodifiable(keywords);
    _lastAutoLoadWholeWord = wholeWord;
    _lastAutoLoadBlockedUsernames = Set.unmodifiable(blockedUsernames);
    _loadMoreCoordinator.resetCooldown();
  }

  void _openTopic(Topic topic) {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    if (canShowDetailPane) {
      ref
          .read(selectedTopicProvider.notifier)
          .select(
            topicId: topic.id,
            initialTitle: topic.title,
            scrollToPostNumber: topic.lastReadPostNumber,
          );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
          autoSwitchToMasterDetail: true,
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) {
      _listShortcutBinding.disposeDeferred();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 需要

    final providerKey = widget.categoryId;
    final isCurrentTab =
        ref.watch(currentTabCategoryIdProvider) == widget.categoryId;

    // 当前 tab：watch provider 建立订阅，并缓存到本地
    // 非当前 tab：stale 显示 loading，否则显示缓存数据；均不订阅 provider
    final AsyncValue<List<Topic>> topicsAsync;
    if (isCurrentTab) {
      topicsAsync = ref.watch(topicListProvider(providerKey));
      _cachedTopicsAsync = topicsAsync;

      // 以下 listener 仅当前 tab 需要
      ref.listen(fabRefreshSignalProvider, (_, _) {
        _refreshIndicatorKey.currentState?.show();
      });
      // 回顶信号：头部展开由 _TopicsPageState 处理，列表回滚在这里
      ref.listen(scrollToTopProvider, (_, _) {
        scrollToTop();
      });
      ref.listen(tabTagsProvider(widget.categoryId), (prev, next) {
        if (prev != next) {
          _loadMoreCoordinator.resetCooldown();
          ref.read(topicListProvider(widget.categoryId).notifier).refresh();
          _clearIncomingState();
        }
      });
      ref.listen(topicListGlobalParamsSignal, (_, _) {
        _loadMoreCoordinator.resetCooldown();
        _clearIncomingState();
      });
    } else {
      // stale 时直接显示 loading，滑动动画中就能看到骨架屏
      final isStale = ref.watch(staleTabsProvider).contains(widget.categoryId);
      topicsAsync = isStale
          ? const AsyncValue.loading()
          : (_cachedTopicsAsync ?? const AsyncValue.loading());
    }

    final keywords = ref.watch(
      preferencesProvider.select((p) => p.normalizedFilterKeywords),
    );
    final wholeWord = ref.watch(
      preferencesProvider.select((p) => p.topicFilterWholeWord),
    );
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    _syncAutoLoadFilter(keywords, wholeWord, blockedUsernames);
    var hiddenCount = 0;
    var hiddenByBlocked = 0;
    final visibleTopicsAsync = topicsAsync.whenData((topics) {
      final (visible, hidden, byBlocked) = TopicKeywordFilter.apply(
        topics,
        normalizedKeywords: keywords,
        wholeWord: wholeWord,
        blockedUsernames: blockedUsernames,
      );
      hiddenCount = hidden;
      hiddenByBlocked = byBlocked;
      return visible;
    });
    final selectedTopicId = ref.watch(selectedTopicProvider).topicId;

    // 桌面端：注册 J/K/Enter 导航到主面板快捷键
    if (PlatformUtils.isDesktop && isCurrentTab) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _listShortcutBinding.register(context, {
          ShortcutAction.nextItem: () =>
              _moveKeyboardFocus(1, visibleTopicsAsync),
          ShortcutAction.previousItem: () =>
              _moveKeyboardFocus(-1, visibleTopicsAsync),
          ShortcutAction.openItem: () => _openFocusedTopic(visibleTopicsAsync),
        });
      });
    } else if (PlatformUtils.isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _listShortcutBinding.clear();
      });
    }

    return visibleTopicsAsync.when(
      data: (topics) {
        if (topics.isEmpty) {
          return RefreshIndicator(
            edgeOffset: _headerInset,
            onRefresh: () async {
              _loadMoreCoordinator.resetCooldown();
              try {
                // ignore: unused_result
                await ref.refresh(topicListProvider(providerKey).future);
              } catch (_) {}
            },
            child: ClipRRect(
              borderRadius: _topBorderRadius,
              child: ListView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(top: _headerInset),
                children: [
                  const SizedBox(height: 100),
                  Center(child: Text(context.l10n.topics_noTopics)),
                ],
              ),
            ),
          );
        }

        final incomingState = ref.watch(latestChannelProvider);
        final currentFilter = ref.read(topicFilterProvider);
        final hasNewTopics =
            currentFilter == TopicListFilter.latest &&
            incomingState.hasIncomingForCategory(widget.categoryId);
        final newTopicCount = incomingState.incomingCountForCategory(
          widget.categoryId,
        );
        final newTopicOffset = hasNewTopics ? 1 : 0;
        final hintOffset = hiddenCount > 0 ? 1 : 0;
        final headerOffset = newTopicOffset + hintOffset;
        final idToIndex = _visibleIndexMapFor(topics);
        // pill/过滤提示行出现或消失 = 全列表行 index 平移(数据身份未变,
        // _visibleIndexMapFor 检测不到),同样属于静默结构变化,武装哨兵
        if (_lastHeaderOffset != null && _lastHeaderOffset != headerOffset) {
          AnchorGuardSliver.arm();
        }
        _lastHeaderOffset = headerOffset;

        return DesktopRefreshIndicator(
          refreshIndicatorKey: _refreshIndicatorKey,
          refreshNotifier: masterRefreshNotifier,
          // 头部可折叠段悬浮在列表上方;列表贴顶时头部必然全展开
          // （见 _HeaderCollapseController.handleScrollDelta 的上限规则），
          // spinner 固定从展开头部下缘冒出
          edgeOffset: _headerInset,
          shouldRefresh: () =>
              ref.read(currentTabCategoryIdProvider) == widget.categoryId,
          onRefresh: () async {
            _loadMoreCoordinator.resetCooldown();
            try {
              // ignore: unused_result
              await ref.refresh(topicListProvider(providerKey).future);
            } catch (_) {}
            if (ref.read(topicFilterProvider) == TopicListFilter.latest) {
              ref
                  .read(latestChannelProvider.notifier)
                  .clearNewTopicsForCategory(widget.categoryId);
            }
          },
          child: ClipRRect(
            borderRadius: _topBorderRadius,
            child: NotificationListener<ScrollUpdateNotification>(
              onNotification: (notification) {
                if (notification.depth == 0) {
                  final distance =
                      notification.metrics.maxScrollExtent -
                      notification.metrics.pixels;
                  if (_loadMoreCoordinator.shouldTriggerForDistance(distance)) {
                    _triggerLoadMore(providerKey);
                  }
                }
                return false;
              },
              child: CustomScrollView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    // 底部让出 extendBody 注入的底栏高度（底栏滑出式后
                    // 内容延伸到底栏后面）
                    padding: EdgeInsets.only(
                      top: _headerInset + 8,
                      bottom: 12 + MediaQuery.paddingOf(context).bottom,
                    ),
                    sliver: SliverList.builder(
                      itemCount: topics.length + headerOffset + 1,
                      // keyed reconcile:pill 出现/新话题插入/全量替换导致
                      // index 平移时,已有行的 Element/RenderObject 按 key
                      // 迁移,而不是按 index 复用"换脸"(无 key 时视口内
                      // 每行会瞬间变成相邻一条的内容)。迁移残留的布局
                      // 位移由列表尾部的 AnchorGuardSliver 同帧修正。
                      findChildIndexCallback: (key) {
                        if (key is! ValueKey<String>) return null;
                        final value = key.value;
                        if (value == _pillKeyValue) {
                          return hasNewTopics ? 0 : null;
                        }
                        if (value == _filterHintKeyValue) {
                          return hintOffset > 0 ? newTopicOffset : null;
                        }
                        if (value == _footerKeyValue) {
                          return topics.length + headerOffset;
                        }
                        if (value.startsWith('topic-')) {
                          final id = int.tryParse(value.substring(6));
                          final topicIndex = id == null ? null : idToIndex[id];
                          if (topicIndex != null) {
                            return topicIndex + headerOffset;
                          }
                        }
                        return null;
                      },
                      itemBuilder: (context, index) {
                        if (hasNewTopics && index == 0) {
                          return KeyedSubtree(
                            key: const ValueKey(_pillKeyValue),
                            child: _buildNewTopicIndicator(
                              context,
                              newTopicCount,
                              providerKey,
                            ),
                          );
                        }
                        if (hintOffset > 0 && index == newTopicOffset) {
                          return KeyedSubtree(
                            key: const ValueKey(_filterHintKeyValue),
                            child: KeywordFilterHintBar(
                              hiddenCount: hiddenCount,
                              hiddenByBlocked: hiddenByBlocked,
                            ),
                          );
                        }
                        final topicIndex = index - headerOffset;
                        if (topicIndex >= topics.length) {
                          final notifier = ref.watch(
                            topicListProvider(providerKey).notifier,
                          );
                          return KeyedSubtree(
                            key: const ValueKey(_footerKeyValue),
                            child: PagedListFooter(
                              hasMore: notifier.hasMore,
                              isLoadingMore: notifier.isLoadingMore,
                              isLoadMoreFailed: notifier.isLoadMoreFailed,
                              onRetry: notifier.retryLoadMore,
                            ),
                          );
                        }

                        final topic = topics[topicIndex];
                        final rowKey = ValueKey('topic-${topic.id}');
                        final enableLongPress = ref
                            .watch(preferencesProvider)
                            .longPressPreview;
                        final shouldHighlight = _highlightedTopicIds.contains(
                          topic.id,
                        );

                        if (shouldHighlight) {
                          final theme = Theme.of(context);
                          // 卡片正常背景色（需与 TopicCard / CompactTopicCard 的默认 color 一致）
                          final normalColor = topic.pinned
                              ? theme.colorScheme.surfaceContainerLow
                                    .withValues(alpha: 0.5)
                              : theme.cardTheme.color ??
                                    theme.colorScheme.surfaceContainerHighest;
                          final highlightColor = theme
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.3);
                          return KeyedSubtree(
                            key: rowKey,
                            child: TweenAnimationBuilder<Color?>(
                              tween: ColorTween(
                                begin: highlightColor,
                                end: normalColor,
                              ),
                              duration: const Duration(milliseconds: 2000),
                              curve: const Interval(
                                0.2,
                                1.0,
                                curve: Curves.easeOut,
                              ),
                              onEnd: () =>
                                  _highlightedTopicIds.remove(topic.id),
                              builder: (context, color, _) {
                                return buildTopicItem(
                                  context: context,
                                  topic: topic,
                                  isSelected: topic.id == selectedTopicId,
                                  onTap: () {
                                    _syncKeyboardFocusToIndex(topicIndex);
                                    _openTopic(topic);
                                  },
                                  enableLongPress: enableLongPress,
                                  highlightColor: color,
                                );
                              },
                            ),
                          );
                        }

                        final signature = (
                          topic: topic,
                          isSelected: topic.id == selectedTopicId,
                          enableLongPress: enableLongPress,
                          index: topicIndex,
                        );
                        final cached = _topicItemCache[topic.id];
                        if (cached != null && cached.signature == signature) {
                          return KeyedSubtree(
                            key: rowKey,
                            child: cached.widget,
                          );
                        }
                        final item = buildTopicItem(
                          context: context,
                          topic: topic,
                          isSelected: topic.id == selectedTopicId,
                          onTap: () {
                            _syncKeyboardFocusToIndex(topicIndex);
                            _openTopic(topic);
                          },
                          enableLongPress: enableLongPress,
                        );
                        _topicItemCache[topic.id] = (
                          signature: signature,
                          widget: item,
                        );
                        return KeyedSubtree(key: rowKey, child: item);
                      },
                    ),
                  ),
                  // 滚动锚定哨兵:keyed 迁移会把"index 格子的旧账"分给新
                  // 住户(framework 按 index 搬 layoutOffset),整窗因此
                  // 平移约一行高 —— 在这里被同帧修正;贴顶时哨兵自带
                  // 顶部抑制,pill/新话题自然推入视野(浏览器同款语义)。
                  const AnchorGuardSliver(),
                ],
              ),
            ),
          ),
        );
      },
      loading: () => ClipRRect(
        borderRadius: _topBorderRadius,
        child: TopicListSkeleton(
          padding: EdgeInsets.only(top: _headerInset + 8, bottom: 12),
        ),
      ),
      error: (error, stack) => ClipRRect(
        borderRadius: _topBorderRadius,
        child: Padding(
          padding: EdgeInsets.only(top: _headerInset),
          child: ErrorView(
            error: error,
            stackTrace: stack,
            onRetry: () => ref.refresh(topicListProvider(providerKey)),
          ),
        ),
      ),
    );
  }

  Widget _buildNewTopicIndicator(
    BuildContext context,
    int count,
    int? providerKey,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(
          context,
        ).colorScheme.primaryContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _isLoadingNewTopics
              ? null
              : () async {
                  setState(() {
                    _isLoadingNewTopics = true;
                  });
                  try {
                    // 对齐网页版 showInserted：按 topic_ids 增量加载并插入顶部
                    final incomingState = ref.read(latestChannelProvider);
                    final topicIds = incomingState.incomingTopicIdsForCategory(
                      providerKey,
                    );
                    final insertedIds = await ref
                        .read(topicListProvider(providerKey).notifier)
                        .loadBefore(topicIds);
                    ref
                        .read(latestChannelProvider.notifier)
                        .clearIncoming(topicIds);

                    if (mounted && insertedIds.isNotEmpty) {
                      // 标记插入的话题以显示高亮动画
                      _highlightedTopicIds.addAll(insertedIds);
                      // 定时清除高亮，避免不可见卡片的动画无法触发 onEnd
                      final idsToRemove = insertedIds.toSet();
                      Future.delayed(const Duration(milliseconds: 2500), () {
                        if (!mounted) return;
                        final hadHighlights = _highlightedTopicIds
                            .intersection(idsToRemove)
                            .isNotEmpty;
                        _highlightedTopicIds.removeAll(idsToRemove);
                        if (hadHighlights) setState(() {});
                      });
                      scrollToTop();
                    }
                  } finally {
                    if (mounted) {
                      setState(() {
                        _isLoadingNewTopics = false;
                      });
                    }
                  }
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _isLoadingNewTopics
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.arrow_upward_rounded,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          context.l10n.topics_viewNewTopics(count),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
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

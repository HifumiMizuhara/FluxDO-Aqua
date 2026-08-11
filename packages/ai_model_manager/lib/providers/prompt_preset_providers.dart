import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:uuid/uuid.dart';

import '../models/prompt_preset.dart';
import '../services/prompt_preset_storage.dart';
import 'ai_provider_providers.dart';

/// 内置 preset 列表（由主项目注入）
///
/// 主项目应该在 ProviderScope.overrides 中提供这个 provider，
/// 在 override 函数内部 ref.watch 主项目的 localeProvider，
/// 这样 locale 切换时内置 preset 会自动重建（i18n 文本随之更新）。
final builtInPresetsProvider = Provider<List<PromptPreset>>(
  (_) => const [],
);

/// PromptPreset 持久化服务
final promptPresetStorageProvider = Provider<PromptPresetStorage>((ref) {
  final prefs = ref.watch(aiSharedPreferencesProvider);
  return PromptPresetStorage(prefs);
});

/// 全部 preset（内置 + 自定义合并后）
///
/// 内置 preset 通过 [builtInPresetsProvider] 拿到原始数据，再 merge 用户的
/// [PresetCustomization]（pin/hide/sortOrder 等），加上自定义 preset，按
/// (sortOrder, pinned desc) 排序。
final promptPresetListProvider =
    StateNotifierProvider<PromptPresetNotifier, List<PromptPreset>>((ref) {
  final builtIns = ref.watch(builtInPresetsProvider);
  final storage = ref.watch(promptPresetStorageProvider);
  return PromptPresetNotifier(
    builtIns: builtIns,
    storage: storage,
  );
});

/// 按类型过滤
final promptPresetsByTypeProvider =
    Provider.family<List<PromptPreset>, PromptType>((ref, type) {
  return ref
      .watch(promptPresetListProvider)
      .where((p) => p.type == type && !p.hidden)
      .toList(growable: false);
});

/// 已 pinned 的 preset（聊天页底部 chip 区显示）
final pinnedPromptPresetsProvider =
    Provider.family<List<PromptPreset>, PromptType>((ref, type) {
  return ref
      .watch(promptPresetsByTypeProvider(type))
      .where((p) => p.pinned)
      .toList(growable: false);
});

class PromptPresetNotifier extends StateNotifier<List<PromptPreset>> {
  PromptPresetNotifier({
    required this.builtIns,
    required this.storage,
  }) : super(const []) {
    _loadAndMerge();
  }

  final List<PromptPreset> builtIns;
  final PromptPresetStorage storage;
  static const _uuid = Uuid();

  /// 当前持久化的 customization 与 userPresets（内存缓存）
  List<PresetCustomization> _customizations = const [];
  List<PromptPreset> _userPresets = const [];

  /// 当 [builtInPresetsProvider] 因 locale 切换重建时，重新合并
  void rebuildFromBuiltIns(List<PromptPreset> newBuiltIns) {
    // 注意: 实际 locale 切换由 builtInPresetsProvider 重建触发整个
    // promptPresetListProvider 重建（StateNotifier 会被 dispose 重建），
    // 所以这个方法目前没有调用方；保留只是说明设计意图。
    _merge(newBuiltIns);
  }

  void _loadAndMerge() {
    final loaded = storage.load();
    _customizations = loaded.customizations;
    _userPresets = loaded.userPresets;
    _merge(builtIns);
  }

  void _merge(List<PromptPreset> source) {
    final byId = {for (final c in _customizations) c.id: c};
    final mergedBuiltIns = source.map((p) {
      final c = byId[p.id];
      return c == null ? p : c.apply(p);
    }).toList();
    final all = [...mergedBuiltIns, ..._userPresets];
    all.sort((a, b) {
      final cmp = a.sortOrder.compareTo(b.sortOrder);
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });
    state = all;
  }

  Future<void> _persist() async {
    await storage.save(
      customizations: _customizations,
      userPresets: _userPresets,
    );
  }

  /// 修改单个 customization（pin/hide/sortOrder/...）
  Future<void> _upsertCustomization(
    String id,
    PresetCustomization Function(PresetCustomization existing) update, {
    PresetCustomization? defaultIfMissing,
  }) async {
    final list = [..._customizations];
    final idx = list.indexWhere((c) => c.id == id);
    if (idx == -1) {
      list.add(update(defaultIfMissing ?? PresetCustomization(id: id)));
    } else {
      list[idx] = update(list[idx]);
    }
    _customizations = list;
    await _persist();
    _merge(builtIns);
  }

  /// 切换 pin 状态（内置和自定义都可）
  Future<void> togglePin(String id) async {
    final preset = state.firstWhere((p) => p.id == id);
    if (preset.builtIn) {
      await _upsertCustomization(id, (c) {
        return PresetCustomization(
          id: id,
          pinned: !preset.pinned,
          hidden: c.hidden,
          sortOrder: c.sortOrder,
          dimensionValues: c.dimensionValues,
          aspectRatio: c.aspectRatio,
        );
      });
    } else {
      _userPresets = _userPresets
          .map((p) => p.id == id ? p.copyWith(pinned: !p.pinned) : p)
          .toList();
      await _persist();
      _merge(builtIns);
    }
  }

  /// 隐藏内置 preset（自定义请用 deletePreset）
  Future<void> hide(String id) async {
    await _upsertCustomization(id, (c) {
      return PresetCustomization(
        id: id,
        pinned: c.pinned,
        hidden: true,
        sortOrder: c.sortOrder,
        dimensionValues: c.dimensionValues,
        aspectRatio: c.aspectRatio,
      );
    });
  }

  /// 取消隐藏内置 preset
  Future<void> unhide(String id) async {
    await _upsertCustomization(id, (c) {
      return PresetCustomization(
        id: id,
        pinned: c.pinned,
        hidden: false,
        sortOrder: c.sortOrder,
        dimensionValues: c.dimensionValues,
        aspectRatio: c.aspectRatio,
      );
    });
  }

  /// 添加自定义 preset，返回新 id
  Future<String> addUserPreset(PromptPreset preset) async {
    final id = preset.id.isEmpty ? _uuid.v4() : preset.id;
    final created = preset.copyWith(
      id: id,
      builtIn: false,
      hidden: false,
      sortOrder: _nextUserSortOrder(),
    );
    _userPresets = [..._userPresets, created];
    await _persist();
    _merge(builtIns);
    return id;
  }

  /// 更新现有 preset
  ///
  /// - 自定义 preset: 直接覆盖
  /// - 内置 preset: 仅 pin/hidden/sortOrder/dimensionValues/aspectRatio 走 customization；
  ///   name/promptTemplate/icon/dimensions 等不可改（编辑时会复制为自定义）
  Future<void> updatePreset(PromptPreset preset) async {
    if (preset.builtIn) {
      await _upsertCustomization(preset.id, (c) {
        return PresetCustomization(
          id: preset.id,
          pinned: preset.pinned,
          hidden: preset.hidden,
          sortOrder: preset.sortOrder,
          dimensionValues: preset.defaultDimensionValues,
          aspectRatio: preset.aspectRatio,
        );
      });
    } else {
      _userPresets =
          _userPresets.map((p) => p.id == preset.id ? preset : p).toList();
      await _persist();
      _merge(builtIns);
    }
  }

  /// 删除自定义 preset
  Future<void> deletePreset(String id) async {
    _userPresets = _userPresets.where((p) => p.id != id).toList();
    await _persist();
    _merge(builtIns);
  }

  /// 重新排序：传入分组内（builtin 或 user）的新顺序，sortOrder 重新分配
  Future<void> reorderInGroup(
      PromptType type, bool builtIn, List<String> orderedIds) async {
    if (builtIn) {
      final toUpdate = <PresetCustomization>[];
      for (var i = 0; i < orderedIds.length; i++) {
        final id = orderedIds[i];
        final existing = _customizations.firstWhere(
          (c) => c.id == id,
          orElse: () => PresetCustomization(id: id),
        );
        toUpdate.add(PresetCustomization(
          id: id,
          pinned: existing.pinned,
          hidden: existing.hidden,
          sortOrder: i,
          dimensionValues: existing.dimensionValues,
          aspectRatio: existing.aspectRatio,
        ));
      }
      // merge: 保留不在 orderedIds 里的 customization
      final keeperIds = orderedIds.toSet();
      _customizations = [
        ..._customizations.where((c) => !keeperIds.contains(c.id)),
        ...toUpdate,
      ];
    } else {
      // 自定义 preset 通过 sortOrder 排序
      final orderMap = {
        for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i,
      };
      _userPresets = _userPresets.map((p) {
        final idx = orderMap[p.id];
        return idx == null ? p : p.copyWith(sortOrder: idx);
      }).toList();
    }
    await _persist();
    _merge(builtIns);
  }

  /// 恢复所有内置 preset 为默认（清掉 customization；不影响自定义）
  Future<void> resetBuiltInsToDefault() async {
    _customizations = const [];
    await _persist();
    _merge(builtIns);
  }

  int _nextUserSortOrder() {
    if (_userPresets.isEmpty) return 1000;
    final maxOrder =
        _userPresets.map((p) => p.sortOrder).reduce((a, b) => a > b ? a : b);
    return maxOrder + 1;
  }
}

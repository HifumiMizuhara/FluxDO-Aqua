// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/theme_provider.dart'; // sharedPreferencesProvider
import '../providers/user_content_providers.dart';
import '../services/notion/notion_config.dart';

/// 仓库单例：复用全局 SharedPreferences。
final notionConfigRepositoryProvider = Provider<NotionConfigRepository>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return NotionConfigRepository(prefs);
});

/// 当前账号的 Notion 配置。
///
/// 故意不 watch [currentUsernameProvider]：那样会在 username 解析完成的瞬间
/// 让整个 provider 重建,旧 notifier 被销毁、新 notifier 用 `repo.read()`
/// 拿到磁盘上"上一秒"的旧值,刚发起的 update 写入虽然成功,UI 上却看不到。
/// 改用 `ref.listen` —— notifier 始终是同一个实例,username 解析完成后
/// 把账号 id 推给它,它再异步加载一次磁盘。
final notionConfigProvider =
    StateNotifierProvider<NotionConfigNotifier, NotionConfig>((ref) {
      final repo = ref.watch(notionConfigRepositoryProvider);
      final notifier = NotionConfigNotifier(
        repo: repo,
        accountIdResolver: () => ref.read(currentUsernameProvider.future),
      );
      ref.listen<AsyncValue<String?>>(currentUsernameProvider, (prev, next) {
        final id = next.asData?.value;
        if (id != null && id.isNotEmpty) {
          notifier.onAccountIdResolved(id);
        }
      }, fireImmediately: true);
      return notifier;
    });

class NotionConfigNotifier extends StateNotifier<NotionConfig> {
  NotionConfigNotifier({
    required NotionConfigRepository repo,
    required Future<String?> Function() accountIdResolver,
  }) : _repo = repo,
       _resolveAccountId = accountIdResolver,
       super(const NotionConfig());

  final NotionConfigRepository _repo;
  final Future<String?> Function() _resolveAccountId;
  String? _accountId;

  /// 外部 (provider 的 ref.listen) 把解析好的 username 推进来时调用。
  /// 同时把磁盘上的配置加载到 state。重复调用同一 id 是幂等的。
  void onAccountIdResolved(String accountId) {
    if (_accountId == accountId) return;
    _accountId = accountId;
    final cfg = _repo.read(accountId);
    if (!mounted) return;
    state = cfg;
  }

  /// 主动确保配置已从磁盘加载。用于在 provider 首次被访问、
  /// `ref.listen(currentUsernameProvider)` 异步推送尚未到达时,
  /// 业务方(如自动同步 hook)同步路径上拿到的 state 仍然是空的场景。
  Future<void> ensureLoaded() async {
    await _ensureAccountId();
  }

  Future<String?> _ensureAccountId() async {
    if (_accountId != null && _accountId!.isNotEmpty) return _accountId;
    final id = await _resolveAccountId();
    if (id != null && id.isNotEmpty) {
      onAccountIdResolved(id);
    }
    return _accountId;
  }

  Future<void> update(NotionConfig config) async {
    final accountId = await _ensureAccountId();
    if (accountId == null) return;
    await _repo.write(accountId, config);
    if (!mounted) return;
    state = config;
  }

  Future<void> clear() async {
    final accountId = await _ensureAccountId();
    if (accountId == null) return;
    await _repo.clear(accountId);
    if (!mounted) return;
    state = const NotionConfig();
  }
}

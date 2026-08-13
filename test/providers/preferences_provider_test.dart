import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/signature_svg_webview_mode.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _createContainer({
  Map<String, Object> initialValues = const {},
}) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  test('单次返回退出默认关闭并可以持久化', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    expect(container.read(preferencesProvider).exitOnSingleBack, isFalse);

    await container
        .read(preferencesProvider.notifier)
        .setExitOnSingleBack(true);

    final prefs = container.read(sharedPreferencesProvider);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);

    expect(reloaded.read(preferencesProvider).exitOnSingleBack, isTrue);
  });

  test('书签默认打开方式默认值为 defaultRoute', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    final preferences = container.read(preferencesProvider);

    expect(preferences.bookmarksOpenMode, BookmarksOpenMode.defaultRoute);
  });

  test('切换到标签页模式后重建 provider 仍会恢复', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    await container
        .read(preferencesProvider.notifier)
        .setBookmarksOpenMode(BookmarksOpenMode.tabbedWorkspace);

    final prefs = container.read(sharedPreferencesProvider);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);

    expect(
      reloaded.read(preferencesProvider).bookmarksOpenMode,
      BookmarksOpenMode.tabbedWorkspace,
    );
  });

  test('非法持久化值会回退到 defaultRoute', () async {
    final container = await _createContainer(
      initialValues: {'pref_bookmarks_open_mode': 'unexpected'},
    );
    addTearDown(container.dispose);

    expect(
      container.read(preferencesProvider).bookmarksOpenMode,
      BookmarksOpenMode.defaultRoute,
    );
  });

  test('AI 翻译偏好可以持久化并恢复', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    final notifier = container.read(preferencesProvider.notifier);
    await notifier.setAiTranslationEnabled(true);
    await notifier.setAiTranslationTargetLanguage('ja');
    await notifier.setAiTranslationModelKey('provider:model');

    final prefs = container.read(sharedPreferencesProvider);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);

    final state = reloaded.read(preferencesProvider);
    expect(state.aiTranslationEnabled, isTrue);
    expect(state.aiTranslationTargetLanguage, 'ja');
    expect(state.aiTranslationModelKey, 'provider:model');
  });

  test('SVG 签名 WebView 默认使用原生渲染和两个池槽位', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    final preferences = container.read(preferencesProvider);
    expect(preferences.signatureSvgWebViewMode, SignatureSvgWebViewMode.native);
    expect(
      preferences.signatureSvgWebViewPoolSize,
      kSignatureSvgWebViewPoolDefaultSize,
    );
  });

  test('旧版 WebView 开关开启时迁移到 WebView Pool', () async {
    final container = await _createContainer(
      initialValues: {'pref_signature_svg_webview': true},
    );
    addTearDown(container.dispose);

    expect(
      container.read(preferencesProvider).signatureSvgWebViewMode,
      SignatureSvgWebViewMode.webViewPool,
    );
  });

  test('SVG 签名 WebView 模式和池大小可以持久化并恢复', () async {
    final container = await _createContainer();
    addTearDown(container.dispose);

    final notifier = container.read(preferencesProvider.notifier);
    await notifier.setSignatureSvgWebViewMode(
      SignatureSvgWebViewMode.webViewPool,
    );
    await notifier.setSignatureSvgWebViewPoolSize(3);

    final prefs = container.read(sharedPreferencesProvider);
    final reloaded = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(reloaded.dispose);

    final state = reloaded.read(preferencesProvider);
    expect(
      state.signatureSvgWebViewMode,
      SignatureSvgWebViewMode.webViewPool,
    );
    expect(state.signatureSvgWebViewPoolSize, 3);
  });

  test('SVG 签名 WebView 池大小被限制在 1 到 3', () async {
    final container = await _createContainer(
      initialValues: {'pref_signature_svg_webview_pool_size': 99},
    );
    addTearDown(container.dispose);

    expect(container.read(preferencesProvider).signatureSvgWebViewPoolSize, 3);

    await container
        .read(preferencesProvider.notifier)
        .setSignatureSvgWebViewPoolSize(0);
    expect(container.read(preferencesProvider).signatureSvgWebViewPoolSize, 1);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'preloaded_data_service.dart';
import 'cook/cook_js_engine_stub.dart'
    if (dart.library.io) 'cook/cook_js_engine_io.dart';

/// Discourse 1:1 cook 服务。
///
/// 在 app 内跑 Discourse 官方 markdown-it cook 管线（与服务端 MiniRacer
/// 同一份 JS，由 tools/discourse-cook-bundle 打成 assets/cook/discourse-cook.js），
/// 把 raw markdown cook 成与服务端一致的 cooked HTML，供编辑器预览直接
/// 喂 FluxdoRender。
///
/// 失败面（web 平台 / bundle eval 失败 / 站点数据未加载 / JS 抛错）统一
/// 返回 null，由调用方降级到旧的 Dart 近似预览管线。
class DiscourseCookService {
  static final DiscourseCookService _instance =
      DiscourseCookService._internal();
  factory DiscourseCookService() => _instance;
  DiscourseCookService._internal();

  CookJsEngine? _engine;
  Future<bool>? _initFuture;
  bool _unavailable = false;

  /// 预热：编辑器打开时 fire-and-forget 调用，把「读 551K bundle + eval +
  /// init 站点数据」的开销挪到用户切预览之前。
  void warmUp() {
    unawaited(ensureInitialized());
  }

  /// 幂等初始化。失败后置为不可用（本次进程内不再重试 eval 大 bundle，
  /// 站点数据缺失导致的失败除外——那种情况保留重试机会）。
  Future<bool> ensureInitialized() {
    if (_unavailable) return Future.value(false);
    return _initFuture ??= _initialize().then((ok) {
      if (!ok) _initFuture = null; // 允许下次重试（如站点数据晚到）
      return ok;
    });
  }

  Future<bool> _initialize() async {
    if (!cookJsSupported) {
      _unavailable = true;
      return false;
    }

    // 1. 站点数据（cook 需要 siteSettings/site/customEmoji/baseUri）
    final preloaded = PreloadedDataService();
    Map<String, dynamic>? siteSettings;
    Map<String, dynamic>? site;
    try {
      await preloaded.ensureLoaded();
      siteSettings = preloaded.siteSettingsSync;
      site = await preloaded.getSite();
    } catch (e) {
      debugPrint('[DiscourseCook] 站点数据未就绪，暂不初始化: $e');
      return false;
    }
    if (siteSettings == null || site == null) {
      debugPrint('[DiscourseCook] siteSettings/site 为空，暂不初始化');
      return false;
    }

    // 2. eval bundle（一次性大开销，放 warmUp 阶段做）
    try {
      final bundleJs = await rootBundle.loadString(
        'assets/cook/discourse-cook.js',
      );
      final engine = CookJsEngine();
      String? evalError;
      engine.evaluate(bundleJs, onError: (e) => evalError = e);
      if (evalError != null) {
        debugPrint('[DiscourseCook] bundle eval 失败: $evalError');
        _unavailable = true;
        return false;
      }

      // 3. 注入站点数据建 engine
      final initJson = jsonEncode({
        'baseUri': preloaded.baseUri,
        'siteSettings': siteSettings,
        'site': {
          'censored_regexp': site['censored_regexp'],
          'watched_words_replace': site['watched_words_replace'],
          'watched_words_link': site['watched_words_link'],
          'custom_emoji_translation': site['custom_emoji_translation'],
          'denied_emojis': site['denied_emojis'],
          'markdown_additional_options': site['markdown_additional_options'],
          'hashtag_configurations': site['hashtag_configurations'],
          'hashtag_icons': site['hashtag_icons'],
          'categories': site['categories'],
        },
        'customEmoji': preloaded.customEmoji,
        'tagNames': _extractTagNames(site),
      });
      String? initError;
      final initResult = engine.evaluate(
        '__fluxdoCook.init(${jsonEncode(initJson)})',
        onError: (e) => initError = e,
      );
      if (initResult != 'ok') {
        debugPrint('[DiscourseCook] init 失败: ${initError ?? initResult}');
        _unavailable = true;
        return false;
      }

      _engine = engine;
      debugPrint('[DiscourseCook] 初始化完成');
      return true;
    } catch (e) {
      debugPrint('[DiscourseCook] 初始化异常: $e');
      _unavailable = true;
      return false;
    }
  }

  /// top_tags 兼容新旧格式（对齐 PreloadedDataService.getTopTags）
  static List<String> _extractTagNames(Map<String, dynamic> site) {
    final topTags = site['top_tags'] as List?;
    if (topTags == null) return const [];
    return topTags
        .map((t) => t is Map<String, dynamic> ? (t['name'] as String? ?? '') : t.toString())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  /// cook raw markdown → cooked HTML。任何失败返回 null（调用方降级）。
  Future<String?> cook(String raw) async {
    if (raw.trim().isEmpty) return '';
    if (!await ensureInitialized()) return null;
    final engine = _engine;
    if (engine == null) return null;

    String? cookError;
    final cooked = engine.evaluate(
      '__fluxdoCook.cook(${jsonEncode(raw)})',
      onError: (e) => cookError = e,
    );
    if (cooked == null) {
      debugPrint('[DiscourseCook] cook 失败: $cookError');
      return null;
    }
    return postProcessCooked(cooked, baseUri: PreloadedDataService().baseUri);
  }

  /// 客户端 cook 输出的 Dart 后处理（纯函数，可单测）。
  ///
  /// mention：客户端 cook 输出 `<span class="mention">@user</span>`（服务端
  /// 的 `<a class="mention">` 是 Ruby 后处理），fluxdo_render 只识别
  /// a.mention → 这里补成锚点，href 确定性拼 {baseUri}/u/{username}。
  /// code/pre 内的同形文本已被 cook 转义成 `&lt;span`，不会误伤。
  @visibleForTesting
  static String postProcessCooked(String cooked, {required String baseUri}) {
    return cooked.replaceAllMapped(_mentionSpanRe, (m) {
      final username = m.group(1)!;
      return '<a class="mention" href="$baseUri/u/$username">@$username</a>';
    });
  }

  static final RegExp _mentionSpanRe = RegExp(
    r'<span class="mention">@([^<]+)</span>',
  );
}

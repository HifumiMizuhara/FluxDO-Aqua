import 'package:emoji_extension/emoji_extension.dart';
import 'package:flutter/foundation.dart';

import '../models/emoji.dart' as discourse_emoji;
import 'discourse/discourse_service.dart';

/// Unicode emoji -> Discourse 官方 shortcode 名解析器。
///
/// 不直接信任 `emoji_extension` 自带的各平台命名表(Discord/Github/...)——
/// 它们与 Discourse(gemoji 系)的命名存在差异,例如:
/// - 👍 Discord 叫 `thumbsup`,Discourse 叫 `+1`
/// - 💩 Discord 叫 `poop`,Discourse 叫 `hankey`
/// - 🖕 Discord 平台甚至没有这条记录
///
/// 因此改为:枚举该 emoji 在各平台下的候选名,逐个与站点真实的 emoji 名
/// 集合(来自 `/emojis.json`,见 [emojiGroupsProvider] 及其快照,或
/// [ensureLoaded] 的独立兜底请求)比对,命中已知名才转换;集合未就绪或
/// 没有命中候选时返回 null——宁可不转,也不要把生僻 emoji 转成站点根本
/// 没有的图。与 [EmojiAliasService] 对 "转换前提是先确认名字真实存在"
/// 的取舍一致。
class EmojiShortcodeMapper {
  static final EmojiShortcodeMapper instance = EmojiShortcodeMapper._();
  EmojiShortcodeMapper._();

  Set<String>? _knownNames;
  Future<void>? _inflight;

  /// 是否已有可用的 Discourse emoji 名集合。
  bool get hasKnownNames => _knownNames != null;

  /// 用 Discourse 真实 emoji 名(及别名)刷新已知名集合。
  void updateKnownNames(Iterable<String> names) {
    _knownNames = {for (final n in names) n.toLowerCase()};
  }

  /// 从 `/emojis.json` 分组数据(标准 + 自定义)提取名字与别名,刷新
  /// 已知名集合。[emojiGroupsProvider] 与 [ensureLoaded] 共用这份逻辑,
  /// 无论数据从哪条路径拿到,mapper 状态都是同一份。
  void updateKnownNamesFromGroups(
    Map<String, List<discourse_emoji.Emoji>> groups,
  ) {
    final names = <String>{};
    for (final emojis in groups.values) {
      for (final emoji in emojis) {
        names.add(emoji.name);
        names.addAll(emoji.searchAliases);
      }
    }
    if (names.isNotEmpty) updateKnownNames(names);
  }

  /// 确保已知名集合可用。
  ///
  /// [emojiGroupsProvider] 只在打开 emoji 面板时才会被 watch——用户光是
  /// 在输入框敲 Unicode emoji、从不打开面板的话,mapper 会一直拿不到
  /// 数据,导致「Emoji 转 Discourse shortcode」实验功能形同虚设。这里
  /// 独立兜底发起一次 `/emojis.json` 请求,与面板路径互不阻塞、谁先到
  /// 谁写入。已有数据或请求已在途时直接复用,不重复发请求。
  Future<void> ensureLoaded() {
    if (_knownNames != null) return Future.value();
    return _inflight ??= _fetch().whenComplete(() => _inflight = null);
  }

  Future<void> _fetch() async {
    try {
      final raw = await DiscourseService().getEmojisRaw();
      updateKnownNamesFromGroups(parseEmojiGroups(raw));
    } catch (e) {
      debugPrint('EmojiShortcodeMapper: emoji 名索引拉取失败 $e');
    }
  }

  /// 仅供测试:直接注入已知名集合。
  void debugSetKnownNames(Iterable<String> names) => updateKnownNames(names);

  /// 仅供测试:清空已知名集合。
  void debugReset() {
    _knownNames = null;
    _inflight = null;
  }

  /// 解析单个 Unicode emoji 字符对应的 Discourse shortcode 名(不含冒号)。
  /// 无法确认时返回 null,调用方应保留原始 Unicode 字符不转换。
  String? resolve(String value) {
    final known = _knownNames;
    if (known == null || known.isEmpty) return null;

    final emoji = Emojis.getOneOrNull(value);
    if (emoji == null) return null;

    // 带肤色修饰符的 emoji 在 Discourse 走 `:name:tN:` 语法,与本表的
    // 候选命名体系不同,交给专门逻辑前先跳过,避免转换成错误的名字。
    if (emoji.hasSkinTone) return null;

    for (final candidate in _candidateNames(emoji)) {
      final normalized = candidate.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      if (known.contains(normalized)) return normalized;
    }
    return null;
  }

  /// 按优先级枚举候选名:Github(gemoji 系,与 Discourse 血缘最近)→
  /// Default → Discord → Slack → CLDR → alsoKnownAs。
  Iterable<String> _candidateNames(Emoji emoji) sync* {
    const priority = [
      Platform.Github,
      Platform.Default,
      Platform.Discord,
      Platform.Slack,
      Platform.CLDR,
    ];
    for (final platform in priority) {
      for (final shortcode in emoji.shortcodes) {
        if (shortcode.platform == platform) {
          yield* shortcode.values;
        }
      }
    }
    yield* emoji.alsoKnownAs;
  }
}

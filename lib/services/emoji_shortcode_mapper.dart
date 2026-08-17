import 'package:emoji_extension/emoji_extension.dart';

/// Unicode emoji -> Discourse 官方 shortcode 名解析器。
///
/// 不直接信任 `emoji_extension` 自带的各平台命名表(Discord/Github/...)——
/// 它们与 Discourse(gemoji 系)的命名存在差异,例如:
/// - 👍 Discord 叫 `thumbsup`,Discourse 叫 `+1`
/// - 💩 Discord 叫 `poop`,Discourse 叫 `hankey`
/// - 🖕 Discord 平台甚至没有这条记录
///
/// 因此改为:枚举该 emoji 在各平台下的候选名,逐个与站点真实的 emoji 名
/// 集合(来自 `/emojis.json`,见 [emojiGroupsProvider] 及其快照)比对,
/// 命中已知名才转换;集合未就绪或没有命中候选时返回 null——宁可不转,
/// 也不要把生僻 emoji 转成站点根本没有的图。与 [EmojiAliasService] 对
/// "转换前提是先确认名字真实存在" 的取舍一致。
class EmojiShortcodeMapper {
  static final EmojiShortcodeMapper instance = EmojiShortcodeMapper._();
  EmojiShortcodeMapper._();

  Set<String>? _knownNames;

  /// 是否已有可用的 Discourse emoji 名集合。
  bool get hasKnownNames => _knownNames != null;

  /// 用 Discourse 真实 emoji 名(及别名)刷新已知名集合。
  void updateKnownNames(Iterable<String> names) {
    _knownNames = {for (final n in names) n.toLowerCase()};
  }

  /// 仅供测试:直接注入已知名集合。
  void debugSetKnownNames(Iterable<String> names) => updateKnownNames(names);

  /// 仅供测试:清空已知名集合。
  void debugReset() => _knownNames = null;

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

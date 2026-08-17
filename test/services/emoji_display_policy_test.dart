import 'package:flutter_test/flutter_test.dart';

import 'package:fluxdo/services/emoji_display_policy.dart';
import 'package:fluxdo/services/emoji_shortcode_mapper.dart';

void main() {
  setUp(() {
    // 用一份最小的"站点真实 emoji 名"注入 mapper,让转换逻辑有名字可比对。
    EmojiShortcodeMapper.instance.debugSetKnownNames(['grinning']);
  });

  tearDown(() {
    EmojiDisplayPolicy.configure(false);
    EmojiShortcodeMapper.instance.debugReset();
  });

  test('converts Unicode emoji to Discourse shortcodes when enabled', () {
    EmojiDisplayPolicy.configure(true);

    expect(
      EmojiDisplayPolicy.normalizeUnicodeEmoji('Hello 😀'),
      'Hello :grinning:',
    );
  });

  test('does not change Unicode emoji when disabled', () {
    expect(EmojiDisplayPolicy.normalizeUnicodeEmoji('Hello 😀'), 'Hello 😀');
  });

  test('preserves Markdown code while normalizing visible text', () {
    EmojiDisplayPolicy.configure(true);

    final normalized = EmojiDisplayPolicy.normalizeMarkdown(
      'Visible 😀 `inline 😀`\n```\nblock 😀\n```',
    );

    expect(normalized, contains('Visible :grinning:'));
    expect(normalized, contains('`inline 😀`'));
    expect(normalized, contains('block 😀'));
  });

  test('converts raw Unicode in cooked HTML to emoji images', () {
    EmojiDisplayPolicy.configure(true);

    final html = EmojiDisplayPolicy.normalizeCookedHtml(
      '<p>Visible 😀</p><p><code>Keep 😀</code></p>',
    );

    expect(html, contains('<img'));
    expect(html, contains('alt=":grinning:"'));
    expect(html, contains('<code>Keep 😀</code>'));
  });

  test('matches Discourse shortcode names, not Discord ones', () {
    // Discourse(gemoji系)は 👍 を `+1`、💩 を `hankey` と呼ぶ。
    // emoji_extension の Discord命名(thumbsup/poop)と食い違うケース。
    EmojiShortcodeMapper.instance.debugSetKnownNames(['+1', 'hankey']);
    EmojiDisplayPolicy.configure(true);

    expect(EmojiDisplayPolicy.normalizeUnicodeEmoji('👍'), ':+1:');
    expect(EmojiDisplayPolicy.normalizeUnicodeEmoji('💩'), ':hankey:');
  });

  test('leaves emoji unconverted when the name is not known to the site', () {
    EmojiShortcodeMapper.instance.debugSetKnownNames(['grinning']);
    EmojiDisplayPolicy.configure(true);

    // 👍 はknownNamesに含まれていないので、誤変換せずUnicodeのまま残す。
    expect(EmojiDisplayPolicy.normalizeUnicodeEmoji('👍'), '👍');
  });
}

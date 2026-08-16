import 'package:flutter_test/flutter_test.dart';

import 'package:fluxdo/services/emoji_display_policy.dart';

void main() {
  tearDown(() => EmojiDisplayPolicy.configure(false));

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
}

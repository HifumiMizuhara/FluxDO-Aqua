import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/emoji_handler.dart';
import 'package:fluxdo/utils/emoji_shortcodes.dart';
import 'package:flutter/services.dart';

void main() {
  group('emoji shortcode helpers', () {
    test('normalize emoji shortcode names', () {
      expect(normalizeEmojiShortcodeName(':heart:'), 'heart');
      expect(normalizeEmojiShortcodeName('wave:t3'), 'wave:t3');
      expect(normalizeEmojiShortcodeName('  :smile:  '), 'smile');
    });

    test('counts emoji shortcodes as a single visible character', () {
      expect(visibleLengthWithEmojiShortcodes('abc'), 3);
      expect(visibleLengthWithEmojiShortcodes(':smile:'), 1);
      expect(visibleLengthWithEmojiShortcodes('Hi :smile:!'), 5);
      expect(visibleLengthWithEmojiShortcodes(':wave:t3::heart:'), 2);
    });

    test('expands deletion ranges to full emoji shortcode boundaries', () {
      expect(
        expandRangeToEmojiShortcodeBoundaries(
          ':smile::heart:',
          const TextRange(start: 6, end: 8),
        ),
        const TextRange(start: 0, end: 14),
      );
      expect(
        expandRangeToEmojiShortcodeBoundaries(
          'a:smile:b',
          const TextRange(start: 2, end: 3),
        ),
        const TextRange(start: 1, end: 8),
      );
    });

    test('deletes an emoji shortcode as a whole on backspace', () {
      const formatter = EmojiShortcodeDeleteFormatter();

      final result = formatter.formatEditUpdate(
        const TextEditingValue(
          text: ':smile:',
          selection: TextSelection.collapsed(offset: 7),
        ),
        const TextEditingValue(
          text: ':smile',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );

      expect(result.text, '');
      expect(result.selection, const TextSelection.collapsed(offset: 0));
    });

    test('snaps a collapsed selection out of emoji shortcode boundaries', () {
      expect(
        normalizeEmojiShortcodeSelection(
          ':smile:abc',
          const TextSelection.collapsed(offset: 3),
          preferEnd: true,
        ),
        const TextSelection.collapsed(offset: 7),
      );
    });

    test(
      'expands replacement selection to full emoji shortcode boundaries',
      () {
        expect(
          normalizeEmojiShortcodeSelection(
            'a:smile:b',
            const TextSelection(baseOffset: 2, extentOffset: 3),
            expandSelection: true,
          ),
          const TextSelection(baseOffset: 1, extentOffset: 8),
        );
      },
    );

    test('keeps plain text deletion unchanged', () {
      const formatter = EmojiShortcodeDeleteFormatter();

      final result = formatter.formatEditUpdate(
        const TextEditingValue(
          text: 'ab',
          selection: TextSelection.collapsed(offset: 2),
        ),
        const TextEditingValue(
          text: 'a',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );

      expect(result.text, 'a');
      expect(result.selection, const TextSelection.collapsed(offset: 1));
    });

    test('builds tone emoji urls with discourse path format', () {
      expect(
        EmojiHandler().getEmojiUrl('wave:t3'),
        endsWith('/images/emoji/twitter/wave/t3.png?v=12'),
      );
    });
  });
}

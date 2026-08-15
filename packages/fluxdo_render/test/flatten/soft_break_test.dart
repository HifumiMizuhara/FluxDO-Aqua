import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/flatten/soft_break.dart';

void main() {
  group('insertSoftBreaks', () {
    test('短串 / 空串原样返回(不插)', () {
      expect(insertSoftBreaks(''), '');
      expect(insertSoftBreaks('abc'), 'abc');
      expect(insertSoftBreaks('hello world'), 'hello world');
    });

    test('超长无空格 ASCII 串逐字符插 U+200B', () {
      final s = 'a' * 40;
      final out = insertSoftBreaks(s);
      expect(out.contains(kSoftBreakChar), isTrue);
      // 40 字符间 39 个断点 → split 出 40 段
      expect(out.split(kSoftBreakChar).length, 40);
      // strip 后还原原文(复制/导出口径)
      expect(out.replaceAll(kSoftBreakChar, ''), s);
    });

    test('含空格的长句:每个词都短于阈值 → 不插', () {
      final s = List.filled(12, 'word').join(' ');
      expect(insertSoftBreaks(s), s);
    });

    test('长串夹在空格之间:只拆长 run,前后原样', () {
      final long = 'x' * 35;
      final s = 'ok $long end';
      final out = insertSoftBreaks(s);
      expect(out.contains(kSoftBreakChar), isTrue);
      expect(out.startsWith('ok '), isTrue);
      expect(out.endsWith(' end'), isTrue);
      expect(out.replaceAll(kSoftBreakChar, ''), s);
    });

    test('CJK 长串不插(逐字本身可换行)', () {
      final s = '中' * 40;
      expect(insertSoftBreaks(s), s);
    });

    test('截图场景:长 asdf 串 + 连着的 code 段能被拆', () {
      final s = '${'asdf' * 8}codex'; // 37 连续无空格
      final out = insertSoftBreaks(s);
      expect(out.contains(kSoftBreakChar), isTrue);
      expect(out.replaceAll(kSoftBreakChar, ''), s);
    });
  });
}

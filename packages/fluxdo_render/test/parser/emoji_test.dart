import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser emoji 识别', () {
    test('img.emoji 产生 EmojiRun', () {
      final result = parser.parse(
        '<p>x <img src="https://e.com/heart.png" alt=":heart:" '
        'class="emoji" title=":heart:"> y</p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(3));
      expect(p.inlines[0], const TextRun('x '));
      final emoji = p.inlines[1] as EmojiRun;
      expect(emoji.name, 'heart');
      expect(emoji.url, 'https://e.com/heart.png');
      expect(emoji.isOnlyEmoji, isFalse);
      expect(p.inlines[2], const TextRun(' y'));
    });

    test('class="emoji only-emoji" 解析 isOnlyEmoji', () {
      final result = parser.parse(
        '<p><img src="https://e.com/tada.png" alt=":tada:" '
        'class="emoji only-emoji" title=":tada:"></p>',
      );
      final p = result[0] as ParagraphNode;
      final emoji = p.inlines[0] as EmojiRun;
      expect(emoji.isOnlyEmoji, isTrue);
    });

    test('附加自定义 class(emoji-custom)不影响识别', () {
      final result = parser.parse(
        '<p><img src="x.gif" alt=":bili:" class="emoji emoji-custom" '
        'title=":bili:"></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines[0], isA<EmojiRun>());
      expect((p.inlines[0] as EmojiRun).isOnlyEmoji, isFalse);
    });

    test('title 优先于 alt 作 name', () {
      final result = parser.parse(
        '<p><img src="x.png" alt=":alt_name:" class="emoji" '
        'title=":title_name:"></p>',
      );
      final p = result[0] as ParagraphNode;
      expect((p.inlines[0] as EmojiRun).name, 'title_name');
    });

    test('只有 alt 没 title 时用 alt', () {
      final result = parser.parse(
        '<p><img src="x.png" alt=":only_alt:" class="emoji"></p>',
      );
      final p = result[0] as ParagraphNode;
      expect((p.inlines[0] as EmojiRun).name, 'only_alt');
    });

    test('name 自动去掉首尾冒号', () {
      final result = parser.parse(
        '<p><img src="x.png" alt=":heart:" class="emoji"></p>',
      );
      final p = result[0] as ParagraphNode;
      expect((p.inlines[0] as EmojiRun).name, 'heart');
    });

    test('alt/title 全无时 name 为空串', () {
      final result = parser.parse('<p><img src="x.png" class="emoji"></p>');
      final p = result[0] as ParagraphNode;
      expect((p.inlines[0] as EmojiRun).name, '');
    });

    test('emoji 嵌套在 link 内', () {
      final result = parser.parse(
        '<p><a href="/x"><img src="h.png" alt=":heart:" class="emoji"> link</a></p>',
      );
      final p = result[0] as ParagraphNode;
      final link = p.inlines[0] as LinkRun;
      expect(link.children, hasLength(2));
      expect(link.children[0], isA<EmojiRun>());
      expect(link.children[1], const TextRun(' link'));
    });

    test('非 emoji 的 img 暂时被忽略(留给阶段 2 image 节点)', () {
      final result = parser.parse(
        '<p>x <img src="/foo.png" alt="not emoji"> y</p>',
      );
      final p = result[0] as ParagraphNode;
      // 普通 img 不进 EmojiRun,跳过 → 只剩 "x " + " y"
      expect(p.inlines.whereType<EmojiRun>(), isEmpty);
    });

    test('==/hashCode 按 name + url + isOnlyEmoji 比较', () {
      const a = EmojiRun(name: 'heart', url: 'x.png');
      const b = EmojiRun(name: 'heart', url: 'x.png');
      const c = EmojiRun(name: 'heart', url: 'x.png', isOnlyEmoji: true);
      const d = EmojiRun(name: 'fire', url: 'x.png');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser mention 识别', () {
    test('a.mention 产生 MentionRun', () {
      final result = parser.parse(
        '<p>欢迎 <a class="mention" href="/u/alice">@alice</a> 加入。</p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(3));
      expect(p.inlines[0], const TextRun('欢迎 '));
      final m = p.inlines[1] as MentionRun;
      expect(m.username, 'alice');
      expect(m.href, '/u/alice');
      expect(m.statusEmoji, isNull);
      expect(p.inlines[2], const TextRun(' 加入。'));
    });

    test('a 没有 class=mention 时产生 LinkRun(不走 mention 分支)', () {
      final result = parser.parse('<p><a href="/u/bob">@bob</a></p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines[0], isA<LinkRun>());
      expect(p.inlines[0], isNot(isA<MentionRun>()));
    });

    test('username 自动去 @ 前缀', () {
      final result = parser.parse(
        '<p><a class="mention" href="/u/x">@xUser</a></p>',
      );
      final p = result[0] as ParagraphNode;
      expect((p.inlines[0] as MentionRun).username, 'xUser');
    });

    test('多个 mention 紧邻', () {
      final result = parser.parse(
        '<p><a class="mention" href="/u/a">@a</a> '
        '<a class="mention" href="/u/b">@b</a></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines.whereType<MentionRun>(), hasLength(2));
    });

    test('mention 含 mention-status emoji 填到 statusEmoji 字段', () {
      final result = parser.parse(
        '<p><a class="mention" href="/u/alice">@alice'
        '<img src="https://x/fire.png" class="emoji mention-status" '
        'alt=":fire:" title=":fire:"></a></p>',
      );
      final p = result[0] as ParagraphNode;
      final m = p.inlines[0] as MentionRun;
      expect(m.username, 'alice');
      expect(m.statusEmoji, isNotNull);
      expect(m.statusEmoji!.name, 'fire');
      expect(m.statusEmoji!.url, 'https://x/fire.png');
    });

    test('group mention(用户名带下划线)正常解析', () {
      final result = parser.parse(
        '<p><a class="mention" href="/g/team_support">@team_support</a></p>',
      );
      final p = result[0] as ParagraphNode;
      expect((p.inlines[0] as MentionRun).username, 'team_support');
    });

    test('空 href 时 mention 也降级到展平(跟 link 同策略)', () {
      final result = parser.parse('<p><a class="mention" href="">@x</a></p>');
      final p = result[0] as ParagraphNode;
      // 空 href 走纯样式分支(在 class=mention 检测之前),展平为 TextRun
      expect(p.inlines.whereType<MentionRun>(), isEmpty);
      expect(p.inlines.whereType<LinkRun>(), isEmpty);
    });

    test('==/hashCode 按 username + href + statusEmoji', () {
      const a = MentionRun(username: 'x', href: '/u/x');
      const b = MentionRun(username: 'x', href: '/u/x');
      const c = MentionRun(username: 'y', href: '/u/x');
      const d = MentionRun(
        username: 'x',
        href: '/u/x',
        statusEmoji: EmojiRun(name: 'fire', url: 'x.png'),
      );
      expect(a, b);
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });
  });
}

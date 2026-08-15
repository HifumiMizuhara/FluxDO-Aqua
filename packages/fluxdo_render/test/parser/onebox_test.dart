import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser onebox 识别', () {
    test('aside.onebox.allowlistedgeneric → defaultKind + 提取关键字段', () {
      final result = parser.parse('''
<aside class="onebox allowlistedgeneric" data-onebox-src="https://example.com/x">
  <header class="source">
    <img src="https://example.com/favicon.ico" class="site-icon">
    <a href="https://example.com/x">example.com</a>
  </header>
  <article>
    <img src="https://example.com/thumb.jpg" class="thumbnail">
    <h3><a href="https://example.com/x">Title</a></h3>
    <p>Description text.</p>
  </article>
</aside>
''');
      expect(result, hasLength(1));
      final box = result[0] as OneboxNode;
      expect(box.kind, OneboxKind.defaultKind);
      expect(box.url, 'https://example.com/x');
      expect(box.title, 'Title');
      expect(box.description, 'Description text.');
      expect(box.faviconUrl, 'https://example.com/favicon.ico');
      expect(box.thumbnailUrl, 'https://example.com/thumb.jpg');
      expect(box.sourceName, 'example.com');
      expect(box.rawHtml, contains('class="onebox allowlistedgeneric"'));
    });

    test('github 子类 class 都识别为 OneboxKind.github', () {
      for (final cls in [
        'githubrepo',
        'githubblob',
        'githubissue',
        'githubpullrequest',
        'githubcommit',
        'githubgist',
        'githubfolder',
      ]) {
        final result = parser.parse(
          '<aside class="onebox $cls"><h3><a href="https://github.com/x">$cls</a></h3></aside>',
        );
        final box = result[0] as OneboxNode;
        expect(box.kind, OneboxKind.github, reason: 'fail on $cls');
      }
    });

    test('video 类 class 识别为 OneboxKind.video', () {
      for (final cls in [
        'youtube-onebox',
        'vimeo-onebox',
        'loom-onebox',
        'lazyYT',
      ]) {
        final result = parser.parse(
          '<aside class="onebox $cls"><h3>v</h3></aside>',
        );
        expect(
          (result[0] as OneboxNode).kind,
          OneboxKind.video,
          reason: 'fail on $cls',
        );
      }
    });

    test('social 类识别', () {
      for (final cls in [
        'twitter-tweet',
        'reddit-onebox',
        'instagram-onebox',
        'threads-onebox',
        'tiktok-onebox',
      ]) {
        final result = parser.parse('<aside class="onebox $cls"></aside>');
        expect(
          (result[0] as OneboxNode).kind,
          OneboxKind.social,
          reason: 'fail on $cls',
        );
      }
    });

    test('tech 类识别', () {
      for (final cls in [
        'stackexchange-onebox',
        'stackoverflow-onebox',
        'hackernews-onebox',
        'pastebin-onebox',
        'googledocs-onebox',
        'pdf-onebox',
        'amazon-onebox',
      ]) {
        final result = parser.parse('<aside class="onebox $cls"></aside>');
        expect(
          (result[0] as OneboxNode).kind,
          OneboxKind.tech,
          reason: 'fail on $cls',
        );
      }
    });

    test('user-onebox 识别', () {
      final result = parser.parse('<aside class="onebox user-onebox"></aside>');
      expect((result[0] as OneboxNode).kind, OneboxKind.user);
    });

    test('data-onebox-src 优先于 header a href', () {
      final result = parser.parse(
        '<aside class="onebox" data-onebox-src="https://a/data-src">'
        '<header><a href="https://b/header">b</a></header></aside>',
      );
      expect((result[0] as OneboxNode).url, 'https://a/data-src');
    });

    test('h4 a 后备(无 h3)', () {
      final result = parser.parse(
        '<aside class="onebox"><h4><a href="/x">T</a></h4></aside>',
      );
      final box = result[0] as OneboxNode;
      expect(box.url, '/x');
      expect(box.title, 'T');
    });

    test('rawHtml 保留 outerHtml', () {
      final result = parser.parse('<aside class="onebox"><p>x</p></aside>');
      final box = result[0] as OneboxNode;
      expect(box.rawHtml, startsWith('<aside class="onebox"'));
      expect(box.rawHtml, contains('<p>x</p>'));
    });

    test('quote 不会被误识别为 onebox(优先 quote)', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x"><blockquote></blockquote></aside>',
      );
      expect(result[0], isA<QuoteCardNode>());
      expect(result[0], isNot(isA<OneboxNode>()));
    });

    test('aside 内既无 onebox class 也无 quote class 走 fallback', () {
      final result = parser.parse('<aside><p>x</p></aside>');
      expect(result.whereType<OneboxNode>(), isEmpty);
    });
  });
}

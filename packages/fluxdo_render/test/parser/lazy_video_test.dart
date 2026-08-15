import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser lazy_video 识别', () {
    test('YouTube 基础形态 → LazyVideoNode + provider=youtube', () {
      final result = parser.parse(
        '<div class="lazy-video-container" data-provider-name="youtube" '
        'data-video-id="abc123" data-video-title="标题" data-video-start-time="">'
        '<a class="title-link" href="https://youtube.com/watch?v=abc123">'
        '<img src="https://img.youtube.com/vi/abc123/hq.jpg"></a>'
        '</div>',
      );
      expect(result, hasLength(1));
      final v = result[0] as LazyVideoNode;
      expect(v.provider, LazyVideoProvider.youtube);
      expect(v.videoId, 'abc123');
      expect(v.title, '标题');
      expect(v.startTime, '');
      expect(v.url, 'https://youtube.com/watch?v=abc123');
      expect(v.thumbnailUrl, 'https://img.youtube.com/vi/abc123/hq.jpg');
    });

    test('Vimeo + start-time', () {
      final result = parser.parse(
        '<div class="lazy-video-container" data-provider-name="vimeo" '
        'data-video-id="999" data-video-title="x" data-video-start-time="1m30s">'
        '<a class="title-link" href="https://vimeo.com/999"><img src="t.jpg"></a>'
        '</div>',
      );
      final v = result[0] as LazyVideoNode;
      expect(v.provider, LazyVideoProvider.vimeo);
      expect(v.startTime, '1m30s');
    });

    test('TikTok 无标题 → title="" 不影响识别', () {
      final result = parser.parse(
        '<div class="lazy-video-container" data-provider-name="tiktok" '
        'data-video-id="7234567890">'
        '<a class="title-link" href="https://tiktok.com/@x/video/7234567890">'
        '<img src="t.jpg"></a></div>',
      );
      final v = result[0] as LazyVideoNode;
      expect(v.provider, LazyVideoProvider.tiktok);
      expect(v.title, '');
    });

    test('未知 provider → LazyVideoProvider.other', () {
      final result = parser.parse(
        '<div class="lazy-video-container" data-provider-name="bilibili" '
        'data-video-id="BVxxx"><a href="https://b23.tv/xxx">x</a></div>',
      );
      final v = result[0] as LazyVideoNode;
      expect(v.provider, LazyVideoProvider.other);
    });

    test('a.title-link 缺失 → fallback 第一个 a', () {
      final result = parser.parse(
        '<div class="lazy-video-container" data-provider-name="youtube" '
        'data-video-id="x"><a href="/some/path"><img src="t.jpg"></a></div>',
      );
      final v = result[0] as LazyVideoNode;
      expect(v.url, '/some/path');
    });

    test('完全无 a → url 为空', () {
      final result = parser.parse(
        '<div class="lazy-video-container" data-provider-name="youtube" '
        'data-video-id="x"><img src="t.jpg"></div>',
      );
      final v = result[0] as LazyVideoNode;
      expect(v.url, '');
      expect(v.thumbnailUrl, 't.jpg');
    });

    test('缺 img → thumbnailUrl 为空', () {
      final result = parser.parse(
        '<div class="lazy-video-container" data-provider-name="youtube" '
        'data-video-id="x"><a href="/x">x</a></div>',
      );
      final v = result[0] as LazyVideoNode;
      expect(v.thumbnailUrl, '');
    });

    test('countImageRuns 不计入视频缩略图', () {
      final result = parser.parse(
        '<p><img src="a.png"></p>'
        '<div class="lazy-video-container" data-provider-name="youtube" '
        'data-video-id="x"><img src="thumb.jpg"></div>',
      );
      // 只 a.png 一张
      expect(countImageRuns(result), 1);
    });

    test('普通 div 不会被识别为视频', () {
      final result = parser.parse(
        '<div data-provider-name="youtube" data-video-id="x">'
        '<a href="/x">x</a></div>',
      );
      expect(result.whereType<LazyVideoNode>(), isEmpty);
    });

    test('LazyVideoProvider.fromName 别名映射', () {
      expect(LazyVideoProvider.fromName('youtube'), LazyVideoProvider.youtube);
      expect(LazyVideoProvider.fromName('vimeo'), LazyVideoProvider.vimeo);
      expect(LazyVideoProvider.fromName('tiktok'), LazyVideoProvider.tiktok);
      expect(LazyVideoProvider.fromName(''), LazyVideoProvider.other);
      expect(LazyVideoProvider.fromName('YOUTUBE'), LazyVideoProvider.other);
    });
  });
}

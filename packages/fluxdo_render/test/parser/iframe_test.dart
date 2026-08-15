import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser iframe 识别', () {
    test('基础 iframe → IframeNode + src/width/height/title', () {
      final result = parser.parse(
        '<iframe src="https://example.com/embed" width="560" height="315" '
        'title="嵌入"></iframe>',
      );
      expect(result, hasLength(1));
      final n = result[0] as IframeNode;
      expect(n.src, 'https://example.com/embed');
      expect(n.width, 560);
      expect(n.height, 315);
      expect(n.title, '嵌入');
      expect(n.lazyLoad, isFalse);
      expect(n.allowFullscreen, isFalse);
    });

    test('allowfullscreen 属性识别(裸属性 / "" / "true" / allow 含 fullscreen)', () {
      for (final attr in const [
        '<iframe src="x" allowfullscreen></iframe>',
        '<iframe src="x" allowfullscreen=""></iframe>',
        '<iframe src="x" allowfullscreen="true"></iframe>',
        '<iframe src="x" allow="fullscreen; autoplay"></iframe>',
      ]) {
        final result = parser.parse(attr);
        final n = result[0] as IframeNode;
        expect(n.allowFullscreen, isTrue, reason: 'failed for: $attr');
      }
    });

    test('sandbox / allow 拆分', () {
      final result = parser.parse(
        '<iframe src="x" sandbox="allow-scripts allow-same-origin" '
        'allow="autoplay; encrypted-media; picture-in-picture"></iframe>',
      );
      final n = result[0] as IframeNode;
      expect(n.sandboxFlags, {'allow-scripts', 'allow-same-origin'});
      expect(n.allowFlags, {
        'autoplay',
        'encrypted-media',
        'picture-in-picture',
      });
    });

    test('loading="lazy" → lazyLoad=true', () {
      final result = parser.parse('<iframe src="x" loading="lazy"></iframe>');
      expect((result[0] as IframeNode).lazyLoad, isTrue);
    });

    test('referrerpolicy 提取', () {
      final result = parser.parse(
        '<iframe src="x" referrerpolicy="no-referrer"></iframe>',
      );
      expect((result[0] as IframeNode).referrerPolicy, 'no-referrer');
    });

    test('src 缺失 → fallback data-src', () {
      final result = parser.parse(
        '<iframe data-src="https://lazy.example.com/v"></iframe>',
      );
      expect((result[0] as IframeNode).src, 'https://lazy.example.com/v');
    });

    test('src 和 data-src 都有时优先 src', () {
      final result = parser.parse(
        '<iframe src="https://primary.com" data-src="https://fallback.com"></iframe>',
      );
      expect((result[0] as IframeNode).src, 'https://primary.com');
    });

    test('class 集合保留', () {
      final result = parser.parse(
        '<iframe src="x" class="tiktok-onebox embed"></iframe>',
      );
      expect(
        (result[0] as IframeNode).cssClasses,
        containsAll({'tiktok-onebox', 'embed'}),
      );
    });

    test('width/height 非数字 → null', () {
      final result = parser.parse(
        '<iframe src="x" width="100%" height="auto"></iframe>',
      );
      final n = result[0] as IframeNode;
      expect(n.width, isNull);
      expect(n.height, isNull);
    });

    test('countImageRuns 不计 iframe(webview 内部不感知)', () {
      final result = parser.parse(
        '<p><img src="a.png"></p><iframe src="x"></iframe>',
      );
      expect(countImageRuns(result), 1);
    });

    test('id 全局唯一(多个 iframe)', () {
      final result = parser.parse(
        '<iframe src="a"></iframe><iframe src="b"></iframe>',
      );
      expect(result, hasLength(2));
      final n1 = result[0] as IframeNode;
      final n2 = result[1] as IframeNode;
      expect(n1.id, isNot(n2.id));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';

void main() {
  group('DiscourseCookService.postProcessCooked', () {
    test('span.mention 转成 a.mention 并拼 baseUri', () {
      const cooked = '<p>hi <span class="mention">@sam_saffron</span>!</p>';
      final result = DiscourseCookService.postProcessCooked(
        cooked,
        baseUri: '',
      );
      expect(
        result,
        '<p>hi <a class="mention" href="/u/sam_saffron">@sam_saffron</a>!</p>',
      );
    });

    test('子路径部署时 href 带 baseUri 前缀', () {
      const cooked = '<p><span class="mention">@alice</span></p>';
      final result = DiscourseCookService.postProcessCooked(
        cooked,
        baseUri: '/forum',
      );
      expect(result, contains('href="/forum/u/alice"'));
    });

    test('多个 mention 全部转换', () {
      const cooked =
          '<p><span class="mention">@a</span> 和 <span class="mention">@b</span></p>';
      final result = DiscourseCookService.postProcessCooked(
        cooked,
        baseUri: '',
      );
      expect(result, contains('href="/u/a"'));
      expect(result, contains('href="/u/b"'));
      expect(result, isNot(contains('<span class="mention">')));
    });

    test('code 块内被转义的 mention 形态不受影响', () {
      // cook 会把 code 内的 < 转义成 &lt;，正则匹配不到，保持原样
      const cooked =
          '<pre><code>&lt;span class="mention"&gt;@x&lt;/span&gt;</code></pre>';
      final result = DiscourseCookService.postProcessCooked(
        cooked,
        baseUri: '',
      );
      expect(result, cooked);
    });

    test('无 mention 时原样返回', () {
      const cooked = '<p>普通段落</p>';
      expect(
        DiscourseCookService.postProcessCooked(cooked, baseUri: ''),
        cooked,
      );
    });
  });

  group('DiscourseCookService.extractOneboxTargets', () {
    test('块级 a.onebox 提取到 blockUrls', () {
      const cooked =
          '<p><a href="https://example.com/page" class="onebox" target="_blank">https://example.com/page</a></p>';
      final t = DiscourseCookService.extractOneboxTargets(cooked);
      expect(t.blockUrls, ['https://example.com/page']);
      expect(t.inlineUrls, isEmpty);
    });

    test('行内 inline-onebox-loading 提取到 inlineUrls', () {
      const cooked =
          '<p>参考 <a href="https://example.com/deep/path" class="inline-onebox-loading">https://example.com/deep/path</a> 这篇</p>';
      final t = DiscourseCookService.extractOneboxTargets(cooked);
      expect(t.blockUrls, isEmpty);
      expect(t.inlineUrls, ['https://example.com/deep/path']);
    });

    test('已展开的 inline-onebox 不再提取', () {
      const cooked =
          '<p><a href="https://example.com/a" class="inline-onebox">标题</a></p>';
      final t = DiscourseCookService.extractOneboxTargets(cooked);
      expect(t.blockUrls, isEmpty);
      expect(t.inlineUrls, isEmpty);
    });

    test('普通链接与 mention 不提取，href 实体解码，重复去重', () {
      const cooked =
          '<p><a href="https://x.com">普通</a>'
          '<a class="mention" href="/u/sam">@sam</a>'
          '<a href="https://example.com/q?a=1&amp;b=2" class="onebox">x</a>'
          '<a href="https://example.com/q?a=1&amp;b=2" class="onebox">x</a></p>';
      final t = DiscourseCookService.extractOneboxTargets(cooked);
      expect(t.blockUrls, ['https://example.com/q?a=1&b=2']);
      expect(t.inlineUrls, isEmpty);
    });
  });
}

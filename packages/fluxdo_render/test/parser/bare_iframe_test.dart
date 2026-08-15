/// 裸 `<p><iframe>` 的块级提升(oEmbed 类 onebox,如 Spotify)。
///
/// 多数 onebox 包一层 `<aside class="onebox">`,但部分 oEmbed 引擎
/// 直接产出 `<p><iframe ...></iframe></p>` —— 之前 _mediaBlockFromElement
/// 不认 iframe,被当成未知行内元素丢弃,整条消息内容"消失"。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  test('<p> 内裸 iframe 提升为 IframeNode,内容不丢', () {
    final result = parser.parse(
      '<p><iframe src="https://open.spotify.com/embed/track/x" '
      'height="152" allowfullscreen></iframe></p>',
    );
    final iframe = result.whereType<IframeNode>().single;
    expect(iframe.src, contains('open.spotify.com'));
  });

  test('iframe 前后的文字仍在(段落拆分不吞内容)', () {
    final result = parser.parse(
      '<p>听这个 <iframe src="https://open.spotify.com/embed/track/x">'
      '</iframe> 超好听</p>',
    );
    expect(result.whereType<IframeNode>().length, 1);
    final texts = result
        .whereType<ParagraphNode>()
        .expand((p) => p.inlines)
        .whereType<TextRun>()
        .map((t) => t.text)
        .join();
    expect(texts, contains('听这个'));
    expect(texts, contains('超好听'));
  });

  test('顶层裸 iframe(不在 p 里)维持既有行为', () {
    final result = parser.parse(
      '<iframe src="https://example.com/embed"></iframe>',
    );
    expect(result.whereType<IframeNode>().length, 1);
  });
}

/// 站内话题 onebox 展开物(aside.quote + data-fluxdo-onebox-url 标记)
/// 的序列化:必须写回裸 URL,不许固化 [quote] 块(毁帖)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  const url = 'https://linux.do/t/topic/2587100';

  test('带标记的 aside.quote → oneboxUrl 落字段 → 序列化回裸 URL', () {
    const html =
        '<aside class="quote" data-username="someone" '
        'data-topic="2587100" data-post="1" '
        'data-fluxdo-onebox-url="$url">'
        '<div class="title"><a href="$url">话题标题</a></div>'
        '<blockquote>首楼摘要文字</blockquote></aside>';
    final nodes = ParagraphParser().parse(html);
    final quote = nodes.whereType<QuoteCardNode>().single;
    expect(quote.oneboxUrl, url);

    var n = 0;
    final doc = blockNodesToDoc(nodes, () => 'e_${n++}');
    expect(docToMarkdown(doc), url, reason: 'raw = 裸 URL 非 [quote] 块');
  });

  test('无标记的真引用卡(服务端 cooked)不受影响,仍写 [quote]', () {
    const html =
        '<aside class="quote" data-username="someone" '
        'data-topic="123" data-post="1">'
        '<blockquote>引用内容</blockquote></aside>';
    final nodes = ParagraphParser().parse(html);
    final quote = nodes.whereType<QuoteCardNode>().single;
    expect(quote.oneboxUrl, isNull);

    var n = 0;
    final doc = blockNodesToDoc(nodes, () => 'e_${n++}');
    final md = docToMarkdown(doc);
    expect(md, startsWith('[quote='));
    expect(md, contains('引用内容'));
  });
}

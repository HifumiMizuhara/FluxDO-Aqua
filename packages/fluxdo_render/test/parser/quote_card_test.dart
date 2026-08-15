import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser quote_card 识别', () {
    test('aside.quote 产生 QuoteCardNode', () {
      final result = parser.parse(
        '<aside class="quote" data-username="alice" data-post="3" data-topic="999">'
        '<div class="title"><img class="avatar" src="https://a/alice.png"> alice:</div>'
        '<blockquote><p>引用内容</p></blockquote>'
        '</aside>',
      );
      expect(result, hasLength(1));
      final qc = result[0] as QuoteCardNode;
      expect(qc.username, 'alice');
      expect(qc.avatarUrl, 'https://a/alice.png');
      expect(qc.topicId, 999);
      expect(qc.postNumber, 3);
      expect(qc.children, hasLength(1));
      final p = qc.children[0] as ParagraphNode;
      expect(p.inlines, [const TextRun('引用内容')]);
    });

    test('aside.quote 内有 .title > a 提取 titleText/titleHref', () {
      final result = parser.parse(
        '<aside class="quote" data-username="bob">'
        '<div class="title">'
        '<img class="avatar" src="x.png">'
        '<a href="/t/topic-slug/999/3">原帖标题</a>'
        '</div>'
        '<blockquote><p>x</p></blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.titleText, '原帖标题');
      expect(qc.titleHref, '/t/topic-slug/999/3');
    });

    test('.quote-title__text-content > a 优先(新版)', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<div class="title">'
        '<div class="quote-title__text-content">'
        '<a href="/new-href">new title</a>'
        '</div>'
        '<a href="/old-href">old title</a>'
        '</div>'
        '<blockquote></blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.titleText, 'new title');
      expect(qc.titleHref, '/new-href');
    });

    test('无 .title 块 — 所有头部字段为 null', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<blockquote><p>x</p></blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.avatarUrl, isNull);
      expect(qc.titleText, isNull);
      expect(qc.titleHref, isNull);
    });

    test('data-topic / data-post 非数字 → null', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x" data-topic="abc" data-post="xx">'
        '<blockquote></blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.topicId, isNull);
      expect(qc.postNumber, isNull);
    });

    test('嵌套 quote_card', () {
      final result = parser.parse(
        '<aside class="quote" data-username="outer">'
        '<blockquote>'
        '<p>外</p>'
        '<aside class="quote" data-username="inner">'
        '<blockquote><p>内</p></blockquote>'
        '</aside>'
        '</blockquote>'
        '</aside>',
      );
      final outer = result[0] as QuoteCardNode;
      expect(outer.username, 'outer');
      expect(outer.children, hasLength(2));
      expect(outer.children[0], isA<ParagraphNode>());
      final inner = outer.children[1] as QuoteCardNode;
      expect(inner.username, 'inner');
      expect(inner.children, hasLength(1));
    });

    test('引用内含 list / strong 等混合块', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<blockquote>'
        '<p>段 <strong>粗</strong></p>'
        '<ul><li>项</li></ul>'
        '</blockquote>'
        '</aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.children, hasLength(2));
      expect(qc.children[0], isA<ParagraphNode>());
      expect(qc.children[1], isA<ListNode>());
    });

    test('非 .quote 的 aside 不走 QuoteCardNode(走 fallback)', () {
      final result = parser.parse('<aside class="onebox"><p>x</p></aside>');
      expect(result.whereType<QuoteCardNode>(), isEmpty);
    });

    test('id 在嵌套场景下全局唯一', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<blockquote>'
        '<p>a</p>'
        '<aside class="quote" data-username="y">'
        '<blockquote><p>b</p></blockquote>'
        '</aside>'
        '</blockquote>'
        '</aside>',
      );
      final outer = result[0] as QuoteCardNode;
      final outerP = outer.children[0] as ParagraphNode;
      final inner = outer.children[1] as QuoteCardNode;
      final innerP = inner.children[0] as ParagraphNode;
      expect({outer.id, outerP.id, inner.id, innerP.id}, hasLength(4));
    });

    test('标题含 emoji + 分类徽章 → titleInlines 保留 emoji、category 结构化', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<div class="title"><div class="quote-title__text-content">'
        '<a href="/t/1">标题 '
        '<img class="emoji" title="tada" alt="tada" src="/e.png"></a> '
        '<a class="badge-category__wrapper" href="/c/dev/4">'
        '<span class="badge-category" '
        'style="--category-badge-color: #32c3c3; '
        '--category-badge-text-color: #000000;">'
        '<span class="badge-category__name">开发调优</span></span></a>'
        '</div></div>'
        '<blockquote><p>正文</p></blockquote></aside>',
      );
      final qc = result[0] as QuoteCardNode;
      // 标题走 titleInlines,是一个 LinkRun,内部保留 emoji(不再被纯文本吃掉)。
      final link = qc.titleInlines.whereType<LinkRun>().single;
      expect(link.href, '/t/1');
      expect(link.children.whereType<EmojiRun>(), hasLength(1));
      // 纯文本 titleText 仍在(fallback / 相等用)。
      expect(qc.titleText, isNotNull);
      // 分类徽章结构化提取(名称 / 底色 / 文字色 / 跳分类链接)。
      expect(qc.categoryName, '开发调优');
      expect(qc.categoryColor, '#32c3c3');
      expect(qc.categoryTextColor, '#000000');
      expect(qc.categoryHref, '/c/dev/4');
    });

    test('普通标题(无徽章)→ category 全 null', () {
      final result = parser.parse(
        '<aside class="quote" data-username="x">'
        '<div class="title"><a href="/t/2">纯标题</a></div>'
        '<blockquote><p>x</p></blockquote></aside>',
      );
      final qc = result[0] as QuoteCardNode;
      expect(qc.categoryName, isNull);
      expect(qc.categoryColor, isNull);
    });
  });
}

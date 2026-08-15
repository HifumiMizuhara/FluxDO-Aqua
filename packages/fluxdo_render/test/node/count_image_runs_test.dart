import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  group('countImageRuns', () {
    test('空 list 返回 0', () {
      expect(countImageRuns([]), 0);
    });

    test('无 image 的节点返回 0', () {
      const nodes = <BlockNode>[
        ParagraphNode(id: 'b_0', inlines: [TextRun('hello')]),
        HeadingNode(id: 'b_1', level: 1, inlines: [TextRun('h')]),
        HorizontalRuleNode(id: 'b_2'),
      ];
      expect(countImageRuns(nodes), 0);
    });

    test('emoji 不计数(只 ImageRun)', () {
      const nodes = <BlockNode>[
        ParagraphNode(
          id: 'b_0',
          inlines: [EmojiRun(name: 'heart', url: 'x.png')],
        ),
      ];
      expect(countImageRuns(nodes), 0);
    });

    test('paragraph 内 ImageRun 计数', () {
      const nodes = <BlockNode>[
        ParagraphNode(
          id: 'b_0',
          inlines: [
            ImageRun(src: 'a.png'),
            TextRun(' 中间 '),
            ImageRun(src: 'b.png'),
          ],
        ),
      ];
      expect(countImageRuns(nodes), 2);
    });

    test('blockquote / list 嵌套递归计数', () {
      // 用真 parser 产生(避免手写 ListItem 复杂)
      final parser = ParagraphParser();
      final nodes = parser.parse(
        '<p><img src="a.png"></p>'
        '<blockquote><p><img src="b.png"></p></blockquote>'
        '<ul><li><img src="c.png"></li><li>纯文本</li></ul>',
      );
      expect(countImageRuns(nodes), 3);
    });

    test('list item blocks 内的图片也计数', () {
      final parser = ParagraphParser();
      final nodes = parser.parse(
        '<ul>'
        '<li><p>FAQ</p><p><img src="a.png"></p></li>'
        '<li><h4>Q</h4><p><img src="b.png"></p></li>'
        '</ul>',
      );
      expect(countImageRuns(nodes), 2);
    });

    test('link 内嵌 image 也计数', () {
      const nodes = <BlockNode>[
        ParagraphNode(
          id: 'b_0',
          inlines: [
            LinkRun(
              href: '/x',
              children: [ImageRun(src: 'thumb.png')],
            ),
          ],
        ),
      ];
      expect(countImageRuns(nodes), 1);
    });
  });

  group('collectLightboxImageRuns', () {
    test('只收 a.lightbox 图片,裸 img 不进入画廊', () {
      final parser = ParagraphParser();
      final nodes = parser.parse(
        '<p><img src="bare-before.jpg"></p>'
        '<div class="lightbox-wrapper"><a class="lightbox" href="full-a.jpg"><img src="thumb-a.jpg"></a></div>'
        '<p><img src="bare-after.jpg"></p>'
        '<div class="lightbox-wrapper"><a class="lightbox" href="full-b.jpg"><img src="thumb-b.jpg"></a></div>',
      );

      final gallery = collectLightboxImageRuns(nodes);
      expect(countImageRuns(nodes), 4);
      expect(gallery.map((image) => image.lightboxUrl).toList(), [
        'full-a.jpg',
        'full-b.jpg',
      ]);
      expect(gallery.map((image) => image.indexInPost).toList(), [1, 3]);
    });
  });
}

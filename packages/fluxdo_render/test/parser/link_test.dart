import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser link 识别', () {
    test('a 标签产生 LinkRun', () {
      final result = parser.parse(
        '<p><a href="https://example.com">link text</a></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(1));
      final link = p.inlines[0] as LinkRun;
      expect(link.href, 'https://example.com');
      expect(link.children, [const TextRun('link text')]);
    });

    test('link 内含 em / strong', () {
      final result = parser.parse(
        '<p><a href="https://example.com"><em>斜</em><strong>粗</strong></a></p>',
      );
      final p = result[0] as ParagraphNode;
      final link = p.inlines[0] as LinkRun;
      expect(link.children, hasLength(2));
      expect(link.children[0], const EmRun(children: [TextRun('斜')]));
      expect(link.children[1], const StrongRun(children: [TextRun('粗')]));
    });

    test('link 跟前后文本混排', () {
      final result = parser.parse('<p>前 <a href="/post/1">go</a> 后</p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(3));
      expect(p.inlines[0], const TextRun('前 '));
      final link = p.inlines[1] as LinkRun;
      expect(link.href, '/post/1');
      expect(p.inlines[2], const TextRun(' 后'));
    });

    test('空 href 的 a 标签退化为纯样式(展平子节点)', () {
      final result = parser.parse('<p><a href="">no link</a></p>');
      final p = result[0] as ParagraphNode;
      // 空 href 直接展平为 TextRun,不是 LinkRun
      expect(p.inlines, hasLength(1));
      expect(p.inlines[0], const TextRun('no link'));
    });

    test('无 href 属性的 a 标签也退化', () {
      final result = parser.parse('<p><a>no href attr</a></p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(1));
      expect(p.inlines[0], const TextRun('no href attr'));
    });

    test('href trim 空白', () {
      final result = parser.parse(
        '<p><a href="  https://example.com  ">x</a></p>',
      );
      final p = result[0] as ParagraphNode;
      final link = p.inlines[0] as LinkRun;
      expect(link.href, 'https://example.com');
    });

    test('==/hashCode 按 href + children 比较', () {
      const a = LinkRun(href: 'https://example.com', children: [TextRun('x')]);
      const b = LinkRun(href: 'https://example.com', children: [TextRun('x')]);
      const c = LinkRun(href: 'https://other.com', children: [TextRun('x')]);
      const d = LinkRun(href: 'https://example.com', children: [TextRun('y')]);
      expect(a, b);
      expect(a == c, isFalse);
      expect(a == d, isFalse);
    });

    test('顶层裸 a 也能合并到 paragraph', () {
      final result = parser.parse('裸文本 <a href="/x">link</a>');
      expect(result, hasLength(1));
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(2));
      expect(p.inlines[0], const TextRun('裸文本 '));
      expect(
        p.inlines[1],
        const LinkRun(href: '/x', children: [TextRun('link')]),
      );
    });
  });
}

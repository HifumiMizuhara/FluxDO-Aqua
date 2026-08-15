import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser inline code 识别', () {
    test('code 标签产生 InlineCodeRun', () {
      final result = parser.parse(
        '<p>使用 <code>flutter pub get</code> 拉取依赖。</p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(3));
      expect(p.inlines[0], const TextRun('使用 '));
      expect(p.inlines[1], const InlineCodeRun('flutter pub get'));
      expect(p.inlines[2], const TextRun(' 拉取依赖。'));
    });

    test('多个 code 紧邻', () {
      final result = parser.parse(
        '<p><code>git status</code>、<code>git diff</code></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(3));
      expect(p.inlines[0], const InlineCodeRun('git status'));
      expect(p.inlines[1], const TextRun('、'));
      expect(p.inlines[2], const InlineCodeRun('git diff'));
    });

    test('code 内 HTML 实体反转义', () {
      final result = parser.parse(
        '<p><code>&lt;div&gt; &amp; &quot;x&quot;</code></p>',
      );
      final p = result[0] as ParagraphNode;
      final code = p.inlines[0] as InlineCodeRun;
      expect(code.text, '<div> & "x"');
    });

    test('code 内嵌 strong 拍平为纯文本', () {
      // <code> 的语义是字面值,内部 markup 被忽略,只拼 textContent
      final result = parser.parse(
        '<p><code>foo <strong>bar</strong> baz</code></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(1));
      final code = p.inlines[0] as InlineCodeRun;
      expect(code.text, 'foo bar baz');
    });

    test('code 嵌套在 link 内', () {
      final result = parser.parse(
        '<p><a href="/x"><code>RichText</code> 文档</a></p>',
      );
      final p = result[0] as ParagraphNode;
      final link = p.inlines[0] as LinkRun;
      expect(link.href, '/x');
      expect(link.children, hasLength(2));
      expect(link.children[0], const InlineCodeRun('RichText'));
      expect(link.children[1], const TextRun(' 文档'));
    });

    test('空 code 也产出 InlineCodeRun(空串)', () {
      final result = parser.parse('<p>x <code></code> y</p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(3));
      expect(p.inlines[1], const InlineCodeRun(''));
    });

    test('==/hashCode 按 text 比较', () {
      const a = InlineCodeRun('foo');
      const b = InlineCodeRun('foo');
      const c = InlineCodeRun('bar');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });

    test('顶层裸 code 也合并到 paragraph', () {
      final result = parser.parse('裸文本 <code>x</code>');
      expect(result, hasLength(1));
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(2));
      expect(p.inlines[0], const TextRun('裸文本 '));
      expect(p.inlines[1], const InlineCodeRun('x'));
    });
  });
}

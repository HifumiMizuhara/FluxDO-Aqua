import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser code_block 识别', () {
    test('pre/code 产生 CodeBlockNode + language', () {
      final result = parser.parse(
        '<pre><code class="lang-dart">void main() {}</code></pre>',
      );
      expect(result, hasLength(1));
      final cb = result[0] as CodeBlockNode;
      expect(cb.code, 'void main() {}');
      expect(cb.language, 'dart');
    });

    test('lang-xxx 大写 → 小写化', () {
      final result = parser.parse(
        '<pre><code class="lang-DART">x</code></pre>',
      );
      final cb = result[0] as CodeBlockNode;
      expect(cb.language, 'dart');
    });

    test('无 lang-xxx class → language = null', () {
      final result = parser.parse('<pre><code>plain</code></pre>');
      final cb = result[0] as CodeBlockNode;
      expect(cb.language, isNull);
    });

    test('末尾换行被去掉(避免渲染时多空行)', () {
      final result = parser.parse(
        '<pre><code class="lang-bash">echo hi\n</code></pre>',
      );
      final cb = result[0] as CodeBlockNode;
      expect(cb.code, 'echo hi');
      expect(cb.code.endsWith('\n'), isFalse);
    });

    test('HTML 实体自动解码', () {
      final result = parser.parse(
        '<pre><code class="lang-json">{"x": "&gt;"}</code></pre>',
      );
      final cb = result[0] as CodeBlockNode;
      expect(cb.code, contains('>'));
      expect(cb.code, isNot(contains('&gt;')));
    });

    test('pre 内无 code 子标签时直接取 pre.text', () {
      final result = parser.parse('<pre>plain pre text</pre>');
      final cb = result[0] as CodeBlockNode;
      expect(cb.code, 'plain pre text');
      expect(cb.language, isNull);
    });

    test('多行代码保留换行', () {
      final result = parser.parse(
        '<pre><code class="lang-py">line1\nline2\nline3</code></pre>',
      );
      final cb = result[0] as CodeBlockNode;
      expect(cb.code, 'line1\nline2\nline3');
    });

    test('code_block 跟其他 BlockNode 混排', () {
      final result = parser.parse(
        '<p>前</p><pre><code>code</code></pre><p>后</p>',
      );
      expect(result, hasLength(3));
      expect(result[0], isA<ParagraphNode>());
      expect(result[1], isA<CodeBlockNode>());
      expect(result[2], isA<ParagraphNode>());
    });
  });
}

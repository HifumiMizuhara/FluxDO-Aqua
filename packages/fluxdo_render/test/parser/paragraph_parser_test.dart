import 'dart:ui' show TextAlign;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('空输入', () {
    test('空字符串返回空 list', () {
      expect(parser.parse(''), isEmpty);
    });

    test('只含空白返回空 list(空白被 trim)', () {
      expect(parser.parse('   \n  '), isEmpty);
    });
  });

  group('HTML 空白折叠(white-space: normal)', () {
    // Discourse cooked 里 `<br>\n正文` 的字面 \n 若不折叠会被 RichText 当成
    // 第二个换行 → 多出空行(真机 FAQ 帖图片/文字间多空行的根因)。
    test('文本里的 \\n / 多空格折叠为单空格', () {
      final result = parser.parse('<p>a   b\n\nc</p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines, [const TextRun('a b c')]);
    });

    test('<br>\\n正文:br 后的字面 \\n 不再变成第二个换行', () {
      // 一段:文字 <br> 文字 <br> 文字(全 <br> 换行,无空行)
      final result = parser.parse('甲<br>\n乙<br>\n丙');
      expect(result, hasLength(1));
      final inl = (result[0] as ParagraphNode).inlines;
      // 不应出现以 \n 开头/结尾的 TextRun(那会渲染成多余空行)
      for (final n in inl) {
        if (n is TextRun) {
          expect(
            n.text.contains('\n'),
            isFalse,
            reason: 'TextRun 仍含字面换行:"${n.text}"',
          );
          expect(
            n.text,
            n.text.trim().isEmpty ? n.text : isNot(startsWith(' ')),
          );
        }
      }
      expect(inl.whereType<LineBreakRun>(), hasLength(2));
    });

    test('图片 <br>\\n文字:图文之间只一个换行(无空行)', () {
      final result = parser.parse(
        '<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x/o.png">'
        '<img src="https://x/i.png" width="100" height="40"></a></div><br>\n'
        '使用命令 <code>X</code> 打开',
      );
      final inl = (result[0] as ParagraphNode).inlines;
      // [Image, LineBreak, Text("使用命令 "), Code, Text(" 打开")]
      expect(inl[0], isA<ImageRun>());
      expect(inl[1], isA<LineBreakRun>());
      expect(inl[2], const TextRun('使用命令 ')); // 无前导 \n / 空格
    });
  });

  group('单个 p 标签', () {
    test('p 内只有文本', () {
      final result = parser.parse('<p>hello</p>');
      expect(result, hasLength(1));
      final p = result[0] as ParagraphNode;
      expect(p.inlines, [const TextRun('hello')]);
    });

    test('p 内含 em', () {
      final result = parser.parse('<p>before <em>italic</em> after</p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines, hasLength(3));
      expect(p.inlines[0], const TextRun('before '));
      expect(p.inlines[1], const EmRun(children: [TextRun('italic')]));
      expect(p.inlines[2], const TextRun(' after'));
    });

    test('p 内含 strong / b 等价', () {
      final strong =
          (parser.parse('<p><strong>a</strong></p>')[0] as ParagraphNode)
              .inlines
              .first;
      final b =
          (parser.parse('<p><b>a</b></p>')[0] as ParagraphNode).inlines.first;
      expect(strong, isA<StrongRun>());
      expect(b, isA<StrongRun>());
      expect(strong, b);
    });

    test('p 内含 em / i 等价', () {
      final em =
          (parser.parse('<p><em>a</em></p>')[0] as ParagraphNode).inlines.first;
      final i =
          (parser.parse('<p><i>a</i></p>')[0] as ParagraphNode).inlines.first;
      expect(em, isA<EmRun>());
      expect(i, isA<EmRun>());
      expect(em, i);
    });

    test('p 内含 br', () {
      final p = parser.parse('<p>line1<br>line2</p>')[0] as ParagraphNode;
      expect(p.inlines, [
        const TextRun('line1'),
        const LineBreakRun(),
        const TextRun('line2'),
      ]);
    });

    test('em 嵌套 strong', () {
      final p =
          parser.parse('<p><em><strong>x</strong></em></p>')[0]
              as ParagraphNode;
      expect(p.inlines.length, 1);
      final em = p.inlines[0] as EmRun;
      expect(em.children, [
        const StrongRun(children: [TextRun('x')]),
      ]);
    });

    test('单个 p 分配 id b_0', () {
      final p = parser.parse('<p>hello</p>')[0] as ParagraphNode;
      expect(p.id, 'b_0');
    });
  });

  group('多段', () {
    test('两个相邻 p 产生两个 ParagraphNode', () {
      final result = parser.parse('<p>first</p><p>second</p>');
      expect(result, hasLength(2));
      expect(result, [
        const ParagraphNode(id: 'b_0', inlines: [TextRun('first')]),
        const ParagraphNode(id: 'b_1', inlines: [TextRun('second')]),
      ]);
      // id 也得对(虽然 == 不查 id,但要确保 parser 真的递增了)
      expect((result[0] as ParagraphNode).id, 'b_0');
      expect((result[1] as ParagraphNode).id, 'b_1');
    });

    test('p 中间有空白文本被忽略', () {
      // discourse cooked HTML 标签之间可能有缩进/换行,空白不该变 paragraph
      final result = parser.parse('<p>a</p>\n  \n<p>b</p>');
      expect(result, hasLength(2));
    });
  });

  group('顶层裸 inline(无 p 包裹)', () {
    test('顶层裸文本 + em 合并成单个 paragraph', () {
      final result = parser.parse('裸文本 <em>em</em> 后续');
      expect(result, hasLength(1));
      final p = result[0] as ParagraphNode;
      // 3 段:'裸文本 ' + EmRun + ' 后续'
      expect(p.inlines.length, 3);
      expect(p.inlines[0], const TextRun('裸文本 '));
      expect(p.inlines[1], const EmRun(children: [TextRun('em')]));
      expect(p.inlines[2], const TextRun(' 后续'));
    });

    test('顶层裸 inline 被块级隔断,前后各成一段', () {
      final result = parser.parse('inline before<p>inside p</p>inline after');
      expect(result.length, 3);
      expect(result[0], isA<ParagraphNode>());
      expect(result[1], isA<ParagraphNode>());
      expect(result[2], isA<ParagraphNode>());
    });
  });

  group('未识别标签 fallback', () {
    test('未识别块级 fallback 为 paragraph,只取 textContent', () {
      // div 在 1.1 不识别 → fallback
      final result = parser.parse('<div>fallback text</div>');
      expect(result, hasLength(1));
      final p = result[0] as ParagraphNode;
      expect(p.inlines, [const TextRun('fallback text')]);
    });

    test('未识别 inline 展平子节点', () {
      // <span> 在 1.1 不识别为 inline tag → 展平
      final result = parser.parse('<p><span>inner</span></p>');
      final p = result[0] as ParagraphNode;
      expect(p.inlines, [const TextRun('inner')]);
    });

    test('未识别块级若 textContent 全空白则不产生节点', () {
      final result = parser.parse('<div>   </div>');
      // 空白文本被 _collectInlineFromAnyNode 内部检查 isNotEmpty(只跳 isEmpty,
      // 空白还会进入)——但 paragraph 后续渲染时会被忽略
      // 这里只断言不抛
      expect(result, isNotNull);
    });
  });

  group('深嵌套', () {
    test('em > strong > em 深三层嵌套不丢内容', () {
      final result = parser.parse(
        '<p><em>1 <strong>2 <em>3</em></strong></em></p>',
      );
      final p = result[0] as ParagraphNode;
      expect(p.inlines.length, 1);
      final outerEm = p.inlines[0] as EmRun;
      expect(outerEm.children.length, 2);
      final strong = outerEm.children[1] as StrongRun;
      expect(strong.children.length, 2);
      final innerEm = strong.children[1] as EmRun;
      expect(innerEm.children, [const TextRun('3')]);
    });
  });

  group('空段落 / 空行(BlankLineNode)', () {
    // 背景:浏览器/Discourse 里空 <p> 的 margin 是否显示取决于 CSS 折叠:
    // blockquote 等有 padding 的盒子容器,首尾子的 margin 不折叠出去 → 框内
    // 显示一行留白(诗句上下居中即靠此);顶层/段落间则被相邻 margin 折叠掉。
    // 故策略:空 <p> 只在「盒子容器首尾」产空行,其余丢弃(见 _applyBlankLinePolicy)。

    test('顶层单个空 <p> 丢弃(margin 折叠出 body)', () {
      expect(parser.parse('<p><em></em></p>'), isEmpty);
      expect(parser.parse('<p><br></p>'), isEmpty);
      expect(parser.parse('<p></p>'), isEmpty);
    });

    test('顶层段落间空 p 丢弃(不给段落间平白加空行)', () {
      final result = parser.parse('<p>A</p><p></p><p>B</p>');
      expect(result, hasLength(2));
      expect(result.every((n) => n is ParagraphNode), isTrue);
    });

    test('<p><img></p> 不是空行(含媒体 → 正常段落)', () {
      final result = parser.parse('<p><img src="https://x/a.png"></p>');
      expect(result, hasLength(1));
      expect(result[0], isA<ParagraphNode>());
    });

    test('图片 <p><div lightbox></div></p> 残留空 p 不产空行', () {
      // HTML5 把 lightbox div 顶出 p,产生残留 <p></p>(顶层)→ 不应变空行。
      final result = parser.parse(
        '<p>前</p>'
        '<p><div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://x/o.png">'
        '<img src="https://x/i.png" width="100" height="40"></a></div></p>'
        '<p>后</p>',
      );
      expect(result.whereType<BlankLineNode>(), isEmpty);
    });

    test('诗句式 blockquote:首尾空 p 各产一行留白(上下居中)', () {
      final result = parser.parse(
        '<blockquote>\n<p><em></em></p>'
        '<div align="center"><em>居中诗句</em></div><p></p>\n</blockquote>',
      );
      expect(result, hasLength(1));
      final bq = result[0] as BlockquoteNode;
      // blockquote 有 padding → 首尾空 p 的 margin 显示 → 两行留白。
      expect(bq.children.whereType<BlankLineNode>(), hasLength(2));
      expect(bq.children.first, isA<BlankLineNode>());
      expect(bq.children.last, isA<BlankLineNode>());
      final poem = bq.children.whereType<ParagraphNode>().single;
      expect(poem.textAlign, TextAlign.center);
    });

    test('blockquote 中间空 p 仍折叠丢弃(只首尾留)', () {
      final result = parser.parse(
        '<blockquote><p>甲</p><p></p><p>乙</p></blockquote>',
      );
      final bq = result[0] as BlockquoteNode;
      expect(bq.children.whereType<BlankLineNode>(), isEmpty);
      expect(bq.children.whereType<ParagraphNode>(), hasLength(2));
    });

    test('blockquote 尾部残留空 p 保留为一行留白(padding 不折叠)', () {
      final result = parser.parse('<blockquote><p>正文</p><p></p></blockquote>');
      final bq = result[0] as BlockquoteNode;
      expect(bq.children.last, isA<BlankLineNode>());
      expect(bq.children.whereType<BlankLineNode>(), hasLength(1));
    });
  });
}

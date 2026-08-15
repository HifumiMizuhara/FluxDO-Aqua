import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  group('parser callout 识别', () {
    test('最简形态 [!note] → CalloutNode + kind=note + 默认配置', () {
      final result = parser.parse(
        '<blockquote><p>[!note]<br>正文一行</p></blockquote>',
      );
      expect(result, hasLength(1));
      final c = result[0] as CalloutNode;
      expect(c.kind, CalloutKind.note);
      expect(c.typeRaw, 'note');
      expect(c.title, isNull);
      expect(c.foldable, isNull);
      expect(c.children, hasLength(1));
      expect(c.children[0], isA<ParagraphNode>());
      final p = c.children[0] as ParagraphNode;
      expect(p.inlines, isNotEmpty);
      expect((p.inlines.first as TextRun).text.trim(), '正文一行');
    });

    test('[!warning] 自定义标题 → title 提取', () {
      final result = parser.parse(
        '<blockquote><p>[!warning] 操作不可逆<br>请确认</p></blockquote>',
      );
      final c = result[0] as CalloutNode;
      expect(c.kind, CalloutKind.warning);
      expect(c.title, '操作不可逆');
      expect(c.foldable, isNull);
    });

    test('[!tip]+ → foldable=true (默认展开)', () {
      final result = parser.parse(
        '<blockquote><p>[!tip]+ 标题<br>正文</p></blockquote>',
      );
      final c = result[0] as CalloutNode;
      expect(c.kind, CalloutKind.tip);
      expect(c.foldable, isTrue);
      expect(c.title, '标题');
    });

    test('[!danger]- → foldable=false (默认折叠)', () {
      final result = parser.parse(
        '<blockquote><p>[!danger]- 不要点<br>正文</p></blockquote>',
      );
      final c = result[0] as CalloutNode;
      expect(c.kind, CalloutKind.danger);
      expect(c.foldable, isFalse);
    });

    test('未知类型 [!xyz] → CalloutKind.unknown + typeRaw 保留', () {
      final result = parser.parse(
        '<blockquote><p>[!xyz]<br>正文</p></blockquote>',
      );
      final c = result[0] as CalloutNode;
      expect(c.kind, CalloutKind.unknown);
      expect(c.typeRaw, 'xyz');
    });

    test('别名映射:abstract/summary/tldr → CalloutKind.summary', () {
      for (final type in const ['abstract', 'summary', 'tldr']) {
        final result = parser.parse(
          '<blockquote><p>[!$type]<br>x</p></blockquote>',
        );
        final c = result[0] as CalloutNode;
        expect(c.kind, CalloutKind.summary, reason: '别名 $type 应映射到 summary');
      }
    });

    test('别名映射:tip/hint/important → CalloutKind.tip', () {
      for (final type in const ['tip', 'hint', 'important']) {
        final result = parser.parse(
          '<blockquote><p>[!$type]<br>x</p></blockquote>',
        );
        final c = result[0] as CalloutNode;
        expect(c.kind, CalloutKind.tip);
      }
    });

    test('多段正文:首段 br 后 inline + 后续 p 都进 children', () {
      final result = parser.parse(
        '<blockquote>'
        '<p>[!info] 标题<br>第一段</p>'
        '<p>第二段</p>'
        '</blockquote>',
      );
      final c = result[0] as CalloutNode;
      expect(c.children, hasLength(2));
      expect(c.children[0], isA<ParagraphNode>());
      expect(c.children[1], isA<ParagraphNode>());
      final p1 = c.children[0] as ParagraphNode;
      final p2 = c.children[1] as ParagraphNode;
      expect((p1.inlines.first as TextRun).text.trim(), '第一段');
      expect((p2.inlines.first as TextRun).text.trim(), '第二段');
    });

    test('普通 blockquote(无 [!type])仍回落 BlockquoteNode', () {
      final result = parser.parse('<blockquote><p>这只是普通引用</p></blockquote>');
      expect(result[0], isA<BlockquoteNode>());
    });

    test('callout 内含 list / code 等混合块级', () {
      final result = parser.parse(
        '<blockquote>'
        '<p>[!example]+ 示例<br>下面是步骤</p>'
        '<ul><li>步骤一</li></ul>'
        '<pre><code class="lang-dart">print("hi");</code></pre>'
        '</blockquote>',
      );
      final c = result[0] as CalloutNode;
      expect(c.kind, CalloutKind.example);
      expect(c.foldable, isTrue);
      expect(c.children, hasLength(3));
      expect(c.children[0], isA<ParagraphNode>());
      expect(c.children[1], isA<ListNode>());
      expect(c.children[2], isA<CodeBlockNode>());
    });

    test('首段无 br + 仅标记行 → callout 但 children 为空', () {
      final result = parser.parse('<blockquote><p>[!quote]</p></blockquote>');
      final c = result[0] as CalloutNode;
      expect(c.kind, CalloutKind.quote);
      expect(c.children, isEmpty);
    });

    test('id 在嵌套场景下全局唯一', () {
      final result = parser.parse(
        '<blockquote>'
        '<p>[!note]<br>a</p>'
        '<p>b</p>'
        '</blockquote>',
      );
      final c = result[0] as CalloutNode;
      final p1 = c.children[0] as ParagraphNode;
      final p2 = c.children[1] as ParagraphNode;
      expect({c.id, p1.id, p2.id}, hasLength(3));
    });

    test('CalloutKind.fromType 大小写敏感:大写不识别(parser 已 lowercase)', () {
      // parser 内部已经做了 lowercase,这里直接测 enum 的契约
      expect(CalloutKind.fromType('NOTE'), CalloutKind.unknown);
      expect(CalloutKind.fromType('note'), CalloutKind.note);
    });
  });

  group('parser callout 装饰下放', () {
    test('文本识别 + data-fxd-pos=first → chunkPos=first(首片保留标记出标题)', () {
      final c =
          parser.parse(
                '<blockquote data-fxd-pos="first">'
                '<p>[!info] 标题<br>正文</p></blockquote>',
              )[0]
              as CalloutNode;
      expect(c.kind, CalloutKind.info);
      expect(c.title, '标题');
      expect(c.chunkPos, BlockquoteChunkPos.first);
    });

    test('属性识别 data-fxd-callout(中/尾片,无 [!type] 文本)→ CalloutNode', () {
      final c =
          parser.parse(
                '<blockquote data-fxd-callout="info" data-fxd-pos="mid">'
                '<p>纯正文,无标记</p></blockquote>',
              )[0]
              as CalloutNode;
      expect(c.kind, CalloutKind.info);
      expect(c.typeRaw, 'info');
      expect(c.title, isNull); // 中片无标题
      expect(c.foldable, isNull);
      expect(c.chunkPos, BlockquoteChunkPos.mid);
      expect(c.children, hasLength(1));
      expect(c.children[0], isA<ParagraphNode>());
    });

    test('属性识别 last 片 + 自定义标题属性', () {
      final c =
          parser.parse(
                '<blockquote data-fxd-callout="warning" '
                'data-fxd-callout-title="注意" data-fxd-pos="last">'
                '<p>尾片正文</p></blockquote>',
              )[0]
              as CalloutNode;
      expect(c.kind, CalloutKind.warning);
      expect(c.title, '注意');
      expect(c.chunkPos, BlockquoteChunkPos.last);
    });

    test('标题含链接 → titleInlines 保留 LinkRun(链接可点)', () {
      final c =
          parser.parse(
                '<blockquote><p>[!note] 见 '
                '<a href="https://x/doc">文档</a> 末<br>正文</p></blockquote>',
              )[0]
              as CalloutNode;
      // 纯文本 title 仍是去标签文本(含链接文字)。
      expect(c.title, '见 文档 末');
      // titleInlines 剥掉 [!note] 前缀,保留链接节点。
      final inls = c.titleInlines;
      expect(inls, isNotNull);
      expect(
        inls!.whereType<LinkRun>(),
        hasLength(1),
        reason: '标题里的 <a> 应保留为 LinkRun(可点)',
      );
      expect((inls.whereType<LinkRun>().first).href, 'https://x/doc');
      // 不含 "[!note]" 前缀残留。
      final firstText = inls.whereType<TextRun>().isEmpty
          ? ''
          : inls.whereType<TextRun>().first.text;
      expect(firstText.contains('[!note]'), isFalse);
      // 正文仍在。
      expect(c.children, isNotEmpty);
    });

    test('标题整体是链接 → titleInlines 单个 LinkRun', () {
      final c =
          parser.parse(
                '<blockquote><p>[!tip] <a href="/u">某标题</a></p></blockquote>',
              )[0]
              as CalloutNode;
      final inls = c.titleInlines!;
      expect(inls.whereType<LinkRun>(), hasLength(1));
      expect((inls.whereType<LinkRun>().first).href, '/u');
    });

    test('普通文本标题 → titleInlines 仅 TextRun(无链接)', () {
      final c =
          parser.parse('<blockquote><p>[!info] 纯标题<br>正文</p></blockquote>')[0]
              as CalloutNode;
      expect(c.title, '纯标题');
      expect(c.titleInlines, isNotNull);
      expect(c.titleInlines!.whereType<LinkRun>(), isEmpty);
    });
  });

  group('parser callout 真实服务端 cooked 结构(class=callout)', () {
    test('基础 note → CalloutNode + kind=note + titleInlines/正文正确提取', () {
      final result = parser.parse(
        '<blockquote dir="auto" data-callout-type="note" class="callout" '
        'style="background-color: rgba(8, 109, 221, 0.1);">'
        '<div class="callout-title">'
        '<span class="callout-icon"><svg></svg></span>'
        '<span class="callout-title-inner">Note</span>'
        '</div>'
        '<div class="callout-content"><p>Lorem ipsum dolor sit amet</p></div>'
        '</blockquote>',
      );
      expect(result, hasLength(1));
      final c = result[0] as CalloutNode;
      expect(c.kind, CalloutKind.note);
      expect(c.typeRaw, 'note');
      expect(c.title, 'Note');
      expect(c.foldable, isNull);
      expect(c.children, hasLength(1));
      final p = c.children[0] as ParagraphNode;
      expect(
        (p.inlines.first as TextRun).text.trim(),
        'Lorem ipsum dolor sit amet',
      );
    });

    test('is-collapsible 无 is-collapsed → foldable=true(默认展开)', () {
      final c =
          parser.parse(
                '<blockquote data-callout-type="warning" class="callout is-collapsible">'
                '<div class="callout-title"><span class="callout-title-inner">别看了</span></div>'
                '<div class="callout-content"><p>正文</p></div>'
                '</blockquote>',
              )[0]
              as CalloutNode;
      expect(c.kind, CalloutKind.warning);
      expect(c.title, '别看了');
      expect(c.foldable, isTrue);
    });

    test('is-collapsible + is-collapsed → foldable=false(默认折叠)', () {
      final c =
          parser.parse(
                '<blockquote data-callout-type="success" '
                'class="callout is-collapsible is-collapsed">'
                '<div class="callout-title"><span class="callout-title-inner">非常成功</span></div>'
                '<div class="callout-content"><p>正文</p></div>'
                '</blockquote>',
              )[0]
              as CalloutNode;
      expect(c.foldable, isFalse);
    });

    test('多段正文 + 混合块级都能进 children', () {
      final c =
          parser.parse(
                '<blockquote data-callout-type="tip" class="callout">'
                '<div class="callout-title"><span class="callout-title-inner">Tip</span></div>'
                '<div class="callout-content"><p>第一段</p><p>第二段</p><ul><li>项目</li></ul></div>'
                '</blockquote>',
              )[0]
              as CalloutNode;
      expect(c.children, hasLength(3));
      expect(c.children[2], isA<ListNode>());
    });

    test('没有 class=callout 的普通 blockquote 不受影响,仍回落普通逻辑', () {
      final result = parser.parse('<blockquote><p>普通引用</p></blockquote>');
      expect(result[0], isA<BlockquoteNode>());
    });
  });
}

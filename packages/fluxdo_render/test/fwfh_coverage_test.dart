/// fwfh 对齐守护(M1 spec + M3 测试)。
///
/// 新引擎是自研 parser,没有 fwfh 的 HTML 默认渲染兜底。本测试把「应该支持
/// 什么」(源自 fwfh_core 0.17.2 `core_widget_factory.dart` 默认 tag→样式表)
/// 固化成 spec,并守护:
/// - **spec 驱动**:每个 fwfh 默认行内/块级标签 → 断言新引擎产出对应专用节点
///   (不是裸 TextRun / 丢样式)。新缺口 / 新 fwfh 标签 → 红。
/// - **语料驱动**:对全部 test/fixtures/** 跑 parser 诊断探针,断言「落到纯
///   文本兜底的标签」⊆ intentionallyUnsupported。真实语料冒出的新标签 → 红。
///
/// 这套让"渲染缺口"从真机踩雷变成可枚举 + 长期防回归。
library;

import 'dart:io';
import 'dart:ui' show TextAlign, Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  // ── M1 spec:fwfh 默认行内样式标签 → 期望 StyledRun.kind ──────────────
  // 源:flutter_widget_from_html_core-0.17.2 core_widget_factory.dart
  //   u/ins=underline(:951)、s/del/strike=line-through(:783)、
  //   small=0.833x(:730)、big=1.2x(:728)、mark=#ff0/#000(:863)、
  //   kbd/samp/tt=monospace(:752)、sup/sub=super/sub 0.833x(:897/905)
  const inlineStyleExpect = <String, InlineStyleKind>{
    'u': InlineStyleKind.underline,
    'ins': InlineStyleKind.underline,
    's': InlineStyleKind.lineThrough,
    'del': InlineStyleKind.lineThrough,
    'strike': InlineStyleKind.lineThrough,
    'small': InlineStyleKind.small,
    'big': InlineStyleKind.big,
    'mark': InlineStyleKind.mark,
    'kbd': InlineStyleKind.monospace,
    'samp': InlineStyleKind.monospace,
    'tt': InlineStyleKind.monospace,
    'sup': InlineStyleKind.superscript,
    'sub': InlineStyleKind.subscript,
  };

  // 明确不做的标签(+ 理由)。fwfh 默认支持但本引擎刻意降级为纯文本/忽略。
  // 语料探针里出现这些不算缺口;出现这之外的 → 红(提示新缺口)。
  const intentionallyUnsupported = <String, String>{
    'abbr': '虚线下划线 + title 悬浮,移动端无悬浮、价值低 → 纯文本',
    'q': '引号包裹语义低频,Discourse 几乎不产出',
    'ruby': '注音,中文论坛极罕见',
    'var': '语义化斜体,fwfh 当 italic;降级纯文本可接受',
    'cite': '同 var',
    'dfn': '同 var',
    'wbr': 'fwfh 自身也不支持',
    'font': '废弃标签,Discourse cooked 不产出',
    'address': '罕见块级',
    'dl': '定义列表 dl/dt/dd,Discourse 几乎不用',
    'dt': '同 dl',
    'dd': '同 dl',
  };

  group('M3 spec 驱动:fwfh 行内标签 → 专用节点(对齐 fwfh)', () {
    inlineStyleExpect.forEach((tag, kind) {
      test('<$tag> → StyledRun.$kind(不丢样式)', () {
        final p = parser.parse('<p>x<$tag>y</$tag>z</p>')[0] as ParagraphNode;
        final styled = p.inlines.whereType<StyledRun>().toList();
        expect(
          styled,
          hasLength(1),
          reason: '<$tag> 应产出 StyledRun,而非裸 TextRun 兜底',
        );
        expect(styled.single.kind, kind);
      });
    });

    test('已有专用节点的行内标签仍对齐(em/strong/code/a/br)', () {
      final p =
          parser.parse(
                '<p><em>i</em><strong>b</strong><code>c</code>'
                '<a href="/x">l</a>a<br>b</p>',
              )[0]
              as ParagraphNode;
      expect(p.inlines.whereType<EmRun>(), hasLength(1));
      expect(p.inlines.whereType<StrongRun>(), hasLength(1));
      expect(p.inlines.whereType<InlineCodeRun>(), hasLength(1));
      expect(p.inlines.whereType<LinkRun>(), hasLength(1));
      expect(p.inlines.whereType<LineBreakRun>(), hasLength(1));
    });
  });

  group('M3 spec 驱动:行内 CSS 着色(span style color / background-color)', () {
    // fwfh 默认读 style 里的 color / background-color 渲染;Discourse 由
    // [color=…] / [bgcolor=…] BBCode 产出 → 新引擎产 ColoredRun(不裸展平丢色)。
    ColoredRun firstColored(String html) =>
        (parser.parse(html)[0] as ParagraphNode).inlines
            .whereType<ColoredRun>()
            .first;

    test('<span style="color:#e03e2d"> → ColoredRun.color=#e03e2d', () {
      final c = firstColored('<p><span style="color:#e03e2d">x</span></p>');
      expect(c.color, const Color(0xFFE03E2D));
      expect(c.background, isNull);
    });
    test('<span style="color:red">(命名色) → red', () {
      final c = firstColored('<p><span style="color:red">x</span></p>');
      expect(c.color, const Color(0xFFFF0000));
    });
    test('<span style="background-color:#25AAE2"> → background', () {
      final c = firstColored(
        '<p><span style="background-color: #25AAE2;">x</span></p>',
      );
      expect(c.background, const Color(0xFF25AAE2));
      expect(c.color, isNull);
    });
    test('color + background 同时存在', () {
      final c = firstColored(
        '<p><span style="color:#fff;background-color:#000">x</span></p>',
      );
      expect(c.color, const Color(0xFFFFFFFF));
      expect(c.background, const Color(0xFF000000));
    });
    test('rgb()/rgba() 解析', () {
      expect(
        firstColored('<p><span style="color:rgb(255,0,0)">x</span></p>').color,
        const Color(0xFFFF0000),
      );
      expect(
        firstColored(
          '<p><span style="color:rgba(0,0,0,0.5)">x</span></p>',
        ).color,
        const Color(0x80000000),
      );
    });
    test('color:inherit / 无可解析色 → 不产 ColoredRun(展平,不误吞)', () {
      final p =
          parser.parse('<p><span style="color:inherit">x</span></p>')[0]
              as ParagraphNode;
      expect(p.inlines.whereType<ColoredRun>(), isEmpty);
      expect(p.inlines.whereType<TextRun>(), isNotEmpty);
    });
  });

  group('M3 spec 驱动:块级对齐(div align / center / p align)', () {
    test('<div align="center"> → ParagraphNode.center', () {
      final n =
          parser.parse('<div align="center">hi</div>')[0] as ParagraphNode;
      expect(n.textAlign, TextAlign.center);
    });
    test('<center> → center', () {
      final n = parser.parse('<center>hi</center>')[0] as ParagraphNode;
      expect(n.textAlign, TextAlign.center);
    });
    test('<p style="text-align:right"> → right', () {
      final n =
          parser.parse('<p style="text-align:right">hi</p>')[0]
              as ParagraphNode;
      expect(n.textAlign, TextAlign.right);
    });
    test('普通 <p> 无对齐 → null', () {
      final n = parser.parse('<p>hi</p>')[0] as ParagraphNode;
      expect(n.textAlign, isNull);
    });
  });

  test('M3 语料驱动:全 fixtures 无意外未覆盖标签(冰山守护)', () {
    final dir = _findFixturesDir();
    final htmls = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.html'));
    final offenders = <String, String>{}; // tag → 出处文件
    for (final f in htmls) {
      final html = f.readAsStringSync();
      final diag = parser.parseWithDiagnostics(html);
      for (final tag in diag.unhandledTags) {
        if (intentionallyUnsupported.containsKey(tag)) continue;
        offenders.putIfAbsent(tag, () => f.path.split('/').last);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'fixtures 里出现未覆盖且非「刻意不做」的标签(新缺口,需实现或'
          '登记 intentionallyUnsupported):$offenders',
    );
  });
}

Directory _findFixturesDir() {
  for (final candidate in [
    'test/fixtures',
    'packages/fluxdo_render/test/fixtures',
  ]) {
    final d = Directory(candidate);
    if (d.existsSync()) return d;
  }
  fail('找不到 test/fixtures 目录');
}

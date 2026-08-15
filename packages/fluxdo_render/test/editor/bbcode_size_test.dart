/// `[size=N]` 字号:解析 → 编辑原子 → 序列化 往返。
///
/// 基准取服务端真实 cooked 样本:
/// - `[size=0]`   → `<span style="font-size:0%">收到请回复123</span>`(视觉隐藏)
/// - `[size=150]` → `<span style="font-size:150%">hifumi！</span>`
///
/// 阅读端对齐网页端原样生效(0 倍即隐藏,不夹上下限);编辑端把它当行内
/// 原子(固定块),免得 0 倍隐形/超大撑破编辑器。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

ParagraphNode para(String html) =>
    ParagraphParser().parse(html).first as ParagraphNode;

void main() {
  group('解析 span[style] 的 font-size', () {
    test('真实样本:size=0 → 0 倍(视觉隐藏)', () {
      final p = para('<p><span style="font-size:0%">收到请回复123</span></p>');
      final run = p.inlines.single as SizedRun;
      expect(run.scale, 0.0);
      expect((run.children.single as TextRun).text, '收到请回复123');
    });

    test('真实样本:size=150 → 1.5 倍', () {
      final p = para('<p><span style="font-size:150%">hifumi！</span></p>');
      expect((p.inlines.single as SizedRun).scale, 1.5);
    });

    test('字号与颜色同 span:嵌套不互相吞', () {
      final p = para(
        '<p><span style="font-size:150%;color:#ff0000">又大又红</span></p>',
      );
      final colored = p.inlines.single as ColoredRun;
      expect(colored.color, isNotNull);
      expect((colored.children.single as SizedRun).scale, 1.5);
    });

    test('绝对单位不认(语义不是相对父级倍数)', () {
      final p = para('<p><span style="font-size:12px">绝对单位</span></p>');
      expect(p.inlines.single, isA<TextRun>());
    });

    test('只有颜色时行为不变(回归)', () {
      final p = para('<p><span style="color:#ff0000">只有色</span></p>');
      expect(p.inlines.single, isA<ColoredRun>());
    });
  });

  group('编辑端:mark 化(与 color 同款,不再岛化)', () {
    test('进白名单 —— mark 化,内容照常可编辑', () {
      expect(isEditableInline(const SizedRun(scale: 0, children: [])), isTrue);
    });

    test('含 size 的段落 → TextBlock(可编辑,不是块)', () {
      var n = 0;
      final doc = blockNodesToDoc([
        para('<p>前<span style="font-size:150%">大</span>后</p>'),
      ], () => 'e_${n++}');
      expect(
        doc.single,
        isA<TextBlock>(),
        reason: 'mark 化后一行可以混多个 size 区间,正常逐字编辑',
      );
      final block = doc.single as TextBlock;
      expect(block.content.text, '前大后');
      final sizeMark = block.content.marks.singleWhere(
        (m) => m.kind == MarkKind.size,
      );
      expect(sizeMark.attr, '150');
    });

    test('序列化写回 BBCode,内容不丢', () {
      var n = 0;
      final doc = blockNodesToDoc([
        para('<p>前<span style="font-size:0%">隐</span>后</p>'),
      ], () => 'e_${n++}');
      final md = docToMarkdown(doc);
      expect(md, contains('[size=0]隐[/size]'));
      expect(md, contains('前'));
      expect(md, contains('后'));
    });
  });

  group('隐藏内容阈值(编辑态夹下限)', () {
    List<InlineNode> editInlines(String html) {
      var n = 0;
      final doc = blockNodesToDoc([para(html)], () => 'e_${n++}');
      return (doc.single as TextBlock).content.toInlines(forEditing: true);
    }

    test('[size=15] 恰在阈值上,是合法 15% 字号,不当隐藏内容', () {
      final run = editInlines(
        '<p><span style="font-size:15%">小字</span></p>',
      ).whereType<SizedRun>().single;
      expect(run.scale, 0.15, reason: '判定是严格小于阈值,0.15 原样渲染');
    });

    test('[size=0] 低于阈值,编辑态夹到可读小尺寸', () {
      final run = editInlines(
        '<p><span style="font-size:0%">隐</span></p>',
      ).whereType<SizedRun>().single;
      expect(run.scale, EditableTextContent.hiddenSizeEditingScale);
    });

    test('阅读态不夹(forEditing=false 原样)', () {
      var n = 0;
      final doc = blockNodesToDoc([
        para('<p><span style="font-size:0%">隐</span></p>'),
      ], () => 'e_${n++}');
      final run = (doc.single as TextBlock).content
          .toInlines()
          .whereType<SizedRun>()
          .single;
      expect(run.scale, 0.0);
    });
  });

  group('序列化写回 BBCode', () {
    test('size=0 往返', () {
      final p = para('<p><span style="font-size:0%">收到请回复123</span></p>');
      var n = 0;
      final doc = blockNodesToDoc([p], () => 'e_${n++}');
      expect(docToMarkdown(doc), contains('[size=0]收到请回复123[/size]'));
    });

    test('size=150 往返', () {
      final p = para('<p><span style="font-size:150%">hifumi！</span></p>');
      var n = 0;
      final doc = blockNodesToDoc([p], () => 'e_${n++}');
      expect(docToMarkdown(doc), contains('[size=150]hifumi！[/size]'));
    });

    test('写整数不写 150.0', () {
      final p = para('<p><span style="font-size:150%">x</span></p>');
      var n = 0;
      final doc = blockNodesToDoc([p], () => 'e_${n++}');
      expect(docToMarkdown(doc), isNot(contains('150.0')));
    });

    test('0-400 全枚举往返:[size=N] 序列化回 [size=N](无浮点脏值)', () {
      // scale = N/100 → 序列化乘回 100,浮点误差会产出
      // `[size=7.000000000000001]` 这类脏值(修复前 0-400 中 35 个 N 中招)。
      for (var i = 0; i <= 400; i++) {
        final p = para('<p><span style="font-size:$i%">x</span></p>');
        var n = 0;
        final doc = blockNodesToDoc([p], () => 'e_${n++}');
        final md = docToMarkdown(doc);
        expect(
          md,
          contains('[size=$i]x[/size]'),
          reason: 'N=$i 的往返应逐字保真,实际:$md',
        );
      }
    });
  });
}

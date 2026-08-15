/// input rules(markdown 快捷语法)测试:块级/行内规则矩阵、触发排除、
/// undo 语义(一步回字面文本)。
library;

import 'dart:ui' show TextRange;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/input_rules.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

/// 模拟打字:插入文本后触发规则(typedChar = 末字符)。
InputRuleOutcome type(EditorState s, String text) {
  s.insertText(text);
  final blockId = s.selection!.extent.blockId;
  return tryApplyInputRules(s, blockId, typedChar: text[text.length - 1]);
}

EditorState empty() {
  final s = EditorState.fromTexts(['']);
  addTearDown(s.dispose);
  s.updateSelection(
    EditorSelection.collapsed(
      EditorPosition(blockId: s.blocks.first.id, offset: 0),
    ),
  );
  return s;
}

TextBlock first(EditorState s) => s.blocks.first as TextBlock;

void main() {
  group('块级规则', () {
    test('# 空格 → H1;###### → H6;7 个 # 不触发', () {
      var s = empty();
      expect(type(s, '# '), InputRuleOutcome.applied);
      expect(first(s).isHeading, isTrue);
      expect(first(s).headingLevel, 1);
      expect(first(s).content.text, '', reason: '标记已删');
      expect(s.selection!.extent.offset, 0);

      s = empty();
      expect(type(s, '###### '), InputRuleOutcome.applied);
      expect(first(s).headingLevel, 6);

      s = empty();
      expect(type(s, '####### '), InputRuleOutcome.none);
      expect(first(s).isHeading, isFalse);
    });

    test('- / * / 1. / 7) → 列表;> → 引用层', () {
      var s = empty();
      expect(type(s, '- '), InputRuleOutcome.applied);
      expect(first(s).isListItem, isTrue);
      expect(first(s).ordered, isFalse);

      s = empty();
      expect(type(s, '* '), InputRuleOutcome.applied);
      expect(first(s).isListItem, isTrue);

      s = empty();
      expect(type(s, '1. '), InputRuleOutcome.applied);
      expect(first(s).ordered, isTrue);
      expect(first(s).listStart, 1);

      s = empty();
      expect(type(s, '7) '), InputRuleOutcome.applied);
      expect(first(s).listStart, 7);

      s = empty();
      expect(type(s, '> '), InputRuleOutcome.applied);
      expect(first(s).containers.single, isA<QuoteFrame>());
      // 再叠一层
      expect(type(s, '> '), InputRuleOutcome.applied);
      expect(first(s).containers.length, 2);
    });

    test('--- 空格 → hrRequest 且标记清空', () {
      final s = empty();
      expect(type(s, '--- '), InputRuleOutcome.hrRequest);
      expect(first(s).content.text, '');
    });

    test('[!note] 空格 → calloutRequest,标记清空,类型存 pendingCalloutType', () {
      var s = empty();
      expect(type(s, '[!note] '), InputRuleOutcome.calloutRequest);
      expect(first(s).content.text, '', reason: '标记已删');
      expect(s.pendingCalloutType, 'note');

      // 类型大小写不敏感,统一存小写
      s = empty();
      expect(type(s, '[!WARNING] '), InputRuleOutcome.calloutRequest);
      expect(s.pendingCalloutType, 'warning');

      // 已在引用层里(先 "> " 再敲)一样命中
      s = empty();
      type(s, '> ');
      expect(type(s, '[!tip] '), InputRuleOutcome.calloutRequest);
      expect(s.pendingCalloutType, 'tip');

      // 非行首不触发
      s = empty();
      s.insertText('文字');
      expect(type(s, '[!note] '), InputRuleOutcome.none, reason: '非行首');
    });

    test('排除:行中打标记不触发;heading 内不再转换;标记区含原子不触发', () {
      var s = empty();
      s.insertText('文字');
      expect(type(s, '# '), InputRuleOutcome.none, reason: '非行首');

      s = empty();
      type(s, '# ');
      s.insertText('标题');
      expect(type(s, '- '), InputRuleOutcome.none, reason: 'heading 内');

      s = empty();
      s.insertAtom(const EmojiRun(name: 'smile', url: 'u'));
      expect(type(s, '# '), InputRuleOutcome.none, reason: '原子在标记区');
    });

    test('undo 语义:一步回字面文本', () {
      final s = empty();
      type(s, '# ');
      expect(first(s).isHeading, isTrue);
      s.undo();
      expect(first(s).isHeading, isFalse);
      expect(first(s).content.text, '# ', reason: 'undo 回到字面标记');
    });

    group('软换行段内的软行行首触发(块分裂)', () {
      test('软换行后第二行打 "- " → 前文留原块,新块是列表项', () {
        final s = empty();
        s.insertText('第一行');
        s.insertText('\n');
        expect(type(s, '- '), InputRuleOutcome.applied);
        expect(s.blocks, hasLength(2), reason: '软换行处分裂成两块');
        final head = s.blocks[0] as TextBlock;
        final tail = s.blocks[1] as TextBlock;
        expect(head.content.text, '第一行', reason: '分隔的 \\n 不留');
        expect(head.isParagraph, isTrue);
        expect(tail.isListItem, isTrue);
        expect(tail.content.text, '', reason: '标记已删');
        expect(s.selection!.extent.blockId, tail.id);
        expect(s.selection!.extent.offset, 0);
      });

      test('软行行首打 "# " → 标题;"> " → 引用', () {
        var s = empty();
        s.insertText('a\n');
        expect(type(s, '## '), InputRuleOutcome.applied);
        expect((s.blocks[1] as TextBlock).headingLevel, 2);

        s = empty();
        s.insertText('a\n');
        expect(type(s, '> '), InputRuleOutcome.applied);
        expect((s.blocks[1] as TextBlock).containers.single, isA<QuoteFrame>());
      });

      test('软行行中打标记不触发', () {
        final s = empty();
        s.insertText('a\nb');
        expect(type(s, '- '), InputRuleOutcome.none, reason: '光标前的软行内已有内容');
      });

      test('hr/callout 是整块换岛语义,只认真正的块首,软行不触发', () {
        var s = empty();
        s.insertText('a\n');
        expect(
          type(s, '--- '),
          InputRuleOutcome.none,
          reason: 'hrRequest 会清整块,软行触发会吞掉前文',
        );
        expect(first(s).content.text, 'a\n--- ');

        s = empty();
        s.insertText('a\n');
        expect(type(s, '[!note] '), InputRuleOutcome.none);
      });

      test('软行触发的 undo 一步回到分裂前的字面文本', () {
        final s = empty();
        s.insertText('第一行');
        s.insertText('\n');
        type(s, '- ');
        expect(s.blocks, hasLength(2));
        s.undo();
        expect(s.blocks, hasLength(1));
        expect(first(s).content.text, '第一行\n- ');
      });
    });
  });

  group('行内规则', () {
    test('**x** → strong;*x* → em;`x` → code;~~x~~ → del', () {
      var s = empty();
      expect(type(s, '前**粗体**'), InputRuleOutcome.applied);
      var b = first(s);
      expect(b.content.text, '前粗体');
      expect(
        b.content.marks.single,
        const MarkSpan(start: 1, end: 3, kind: MarkKind.strong),
      );
      expect(s.selection!.extent.offset, 3, reason: '光标落内容尾');

      s = empty();
      expect(type(s, '*斜*'), InputRuleOutcome.applied);
      expect(first(s).content.marks.single.kind, MarkKind.em);

      s = empty();
      expect(type(s, '`code`'), InputRuleOutcome.applied);
      b = first(s);
      expect(b.content.text, 'code');
      expect(b.content.marks.single.kind, MarkKind.inlineCode);

      s = empty();
      expect(type(s, '~~删~~'), InputRuleOutcome.applied);
      expect(first(s).content.marks.single.kind, MarkKind.lineThrough);
    });

    test('排除:** 空内容/带空格边缘不触发;code mark 内不触发', () {
      var s = empty();
      expect(type(s, '****'), InputRuleOutcome.none);

      s = empty();
      expect(type(s, '** x**'), InputRuleOutcome.none, reason: '首空格');

      // 光标在 inlineCode mark 内部:字面量区,不触发。
      // (code 边界之后打 *x* 该触发 —— 新字符不在 code 里。)
      final s2 = EditorState(
        blocks: [
          TextBlock(
            id: 'e_0',
            content: EditableTextContent(
              text: 'a*x*',
              marks: const [
                MarkSpan(start: 0, end: 4, kind: MarkKind.inlineCode),
              ],
            ),
          ),
        ],
      );
      addTearDown(s2.dispose);
      s2.updateSelection(
        const EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: 4),
        ),
      );
      expect(
        tryApplyInputRules(s2, 'e_0', typedChar: '*'),
        InputRuleOutcome.none,
      );
    });

    test('undo 语义:一步回字面定界符', () {
      final s = empty();
      type(s, '**粗**');
      expect(first(s).content.text, '粗');
      s.undo();
      expect(first(s).content.text, '**粗**');
      expect(first(s).content.marks, isEmpty);
    });

    test('composing 中不触发', () {
      final s = empty();
      s.insertText('**x**');
      s.updateComposing(const TextRange(start: 0, end: 5));
      expect(
        tryApplyInputRules(s, s.blocks.first.id, typedChar: '*'),
        InputRuleOutcome.none,
      );
    });
  });

  group('BBCode 属性标记(即打即渲染,同 ** 一级)', () {
    test('[size=150]x[/size] → size mark,attr=150', () {
      final s = empty();
      expect(type(s, '前[size=150]大[/size]'), InputRuleOutcome.applied);
      final b = first(s);
      expect(b.content.text, '前大');
      expect(
        b.content.marks.single,
        const MarkSpan(start: 1, end: 2, kind: MarkKind.size, attr: '150'),
      );
      expect(s.selection!.extent.offset, 2, reason: '光标落内容尾');
    });

    test('一行内混排多个不同 size 区间', () {
      final s = empty();
      type(s, '[size=150]大[/size]');
      type(s, '中');
      expect(type(s, '[size=50]小[/size]'), InputRuleOutcome.applied);
      final b = first(s);
      expect(b.content.text, '大中小');
      expect(b.content.marks, hasLength(2));
      expect(
        b.content.marks,
        containsAll([
          const MarkSpan(start: 0, end: 1, kind: MarkKind.size, attr: '150'),
          const MarkSpan(start: 2, end: 3, kind: MarkKind.size, attr: '50'),
        ]),
      );
    });

    test('[color=#f00]x[/color] / [bgcolor=#00f]x[/bgcolor] 即打即渲染', () {
      var s = empty();
      expect(type(s, '[color=#f00]红字[/color]'), InputRuleOutcome.applied);
      var mark = first(s).content.marks.single;
      expect(mark.kind, MarkKind.textColor);
      expect(mark.attr, '#f00');

      s = empty();
      expect(type(s, '[bgcolor=#00f]底色[/bgcolor]'), InputRuleOutcome.applied);
      mark = first(s).content.marks.single;
      expect(mark.kind, MarkKind.bgColor);
      expect(mark.attr, '#00f');
    });

    test('排除:内容含 [ 不触发(不支持嵌套)', () {
      final s = empty();
      expect(type(s, '[size=150][a][/size]'), InputRuleOutcome.none);
    });

    test('先打闭标记、光标挪回来补开标记(任意顺序)', () {
      // 先打好 "大[/size]",光标停在 "大" 之前,再补 "[size=150]"
      final s = empty();
      s.insertText('大[/size]');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: first(s).id, offset: 0),
        ),
      );
      expect(type(s, '[size=150]'), InputRuleOutcome.applied);
      final b = first(s);
      expect(b.content.text, '大');
      expect(
        b.content.marks.single,
        const MarkSpan(start: 0, end: 1, kind: MarkKind.size, attr: '150'),
      );
      expect(s.selection!.extent.offset, 0, reason: '光标停内容首(补开标记后原地)');
    });

    test('先打闭标记再补开标记:color/bgcolor 同理', () {
      final s = empty();
      s.insertText('红字[/color]');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: first(s).id, offset: 0),
        ),
      );
      expect(type(s, '[color=#f00]'), InputRuleOutcome.applied);
      final mark = first(s).content.marks.single;
      expect(mark.kind, MarkKind.textColor);
      expect(mark.attr, '#f00');
    });

    test('[u]x[/u] → underline;[spoiler]x[/spoiler] → spoilerInline', () {
      var s = empty();
      expect(type(s, '[u]下划线[/u]'), InputRuleOutcome.applied);
      var b = first(s);
      expect(b.content.text, '下划线');
      expect(
        b.content.marks.single,
        const MarkSpan(start: 0, end: 3, kind: MarkKind.underline),
      );

      s = empty();
      expect(type(s, '[spoiler]剧透[/spoiler]'), InputRuleOutcome.applied);
      b = first(s);
      expect(b.content.text, '剧透');
      expect(b.content.marks.single.kind, MarkKind.spoilerInline);
    });

    test('[u]/[spoiler] 先打闭标记再补开标记(任意顺序)', () {
      final s = empty();
      s.insertText('剧透[/spoiler]');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: first(s).id, offset: 0),
        ),
      );
      expect(type(s, '[spoiler]'), InputRuleOutcome.applied);
      final b = first(s);
      expect(b.content.text, '剧透');
      expect(b.content.marks.single.kind, MarkKind.spoilerInline);
    });

    test('真机常见操作:先打空标记对 [size=150][/size],光标移回中间逐字敲内容', () {
      // 真实 bug 复现(见 IME 日志):用户先把 [size=150][/size] 打完
      // (中间空着),再把光标挪回两个标记中间,逐字敲 "大字"。此时
      // 触发字符是内容本身,不是 `]`,前面几条按字符派发的规则都够
      // 不着,得靠 _tryBbcodeInsidePairRules 兜底。
      final s = empty();
      s.insertText('[size=150][/size]');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: first(s).id, offset: 10),
        ),
      );
      expect(type(s, '大'), InputRuleOutcome.applied);
      final b = first(s);
      expect(b.content.text, '大');
      expect(
        b.content.marks.single,
        const MarkSpan(start: 0, end: 1, kind: MarkKind.size, attr: '150'),
      );
    });

    test('先打空标记对再填内容:color/bgcolor/u/spoiler 同理', () {
      var s = empty();
      s.insertText('[color=#f00][/color]');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: first(s).id, offset: 12),
        ),
      );
      type(s, '红');
      expect(first(s).content.marks.single.kind, MarkKind.textColor);

      s = empty();
      s.insertText('[u][/u]');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: first(s).id, offset: 3),
        ),
      );
      type(s, '线');
      expect(first(s).content.marks.single.kind, MarkKind.underline);
    });
  });

  group('HTML 样式标签(sup/sub/mark/small/big/kbd)即打即渲染', () {
    test('<sup>x</sup> → superscript;<mark>x</mark> → markStyle', () {
      var s = empty();
      expect(type(s, '前<sup>上标</sup>'), InputRuleOutcome.applied);
      var b = first(s);
      expect(b.content.text, '前上标');
      expect(
        b.content.marks.single,
        const MarkSpan(start: 1, end: 3, kind: MarkKind.superscript),
      );

      s = empty();
      expect(type(s, '<mark>高亮</mark>'), InputRuleOutcome.applied);
      expect(first(s).content.marks.single.kind, MarkKind.markStyle);
    });

    test('先打闭标签再补开标签(任意顺序)', () {
      final s = empty();
      s.insertText('下标[/sub]'.replaceAll('[/sub]', '</sub>'));
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: first(s).id, offset: 0),
        ),
      );
      expect(type(s, '<sub>'), InputRuleOutcome.applied);
      expect(first(s).content.marks.single.kind, MarkKind.subscript);
    });

    test('先打空标签对再填内容', () {
      final s = empty();
      s.insertText('<kbd></kbd>');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: first(s).id, offset: 5),
        ),
      );
      expect(type(s, 'Ctrl'), InputRuleOutcome.applied);
      final b = first(s);
      expect(b.content.text, 'Ctrl');
      expect(b.content.marks.single.kind, MarkKind.monospaceStyle);
    });
  });

  group('填内容匹配(先打定界符再回中间填字)', () {
    test('**|** 中间打 q → 直接应用格式', () {
      final s = empty();
      s.insertText('****');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 2),
        ),
      );
      expect(type(s, 'q'), InputRuleOutcome.applied);
      expect(first(s).content.text, 'q');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 1, reason: '光标在 q 之后');
    });

    test('`|` 中间打 x;~~|~~ → 命中并直接应用', () {
      var s = empty();
      s.insertText('``');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 1),
        ),
      );
      expect(type(s, 'x'), InputRuleOutcome.applied);
      expect(first(s).content.text, 'x');
      expect(first(s).content.marks.single.kind, MarkKind.inlineCode);

      s = empty();
      s.insertText('~~~~');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 2),
        ),
      );
      expect(type(s, 'x'), InputRuleOutcome.applied);
      expect(first(s).content.text, 'x');
      expect(first(s).content.marks.single.kind, MarkKind.lineThrough);
    });

    test('排除:光标后不是定界符不触发;***q*** 归属不明不触发', () {
      var s = empty();
      s.insertText('**qw**');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 3),
        ),
      );
      // 光标在 w 前(后面是 w 不是定界符)
      expect(
        tryApplyInputRules(s, s.blocks.first.id, typedChar: 'q'),
        InputRuleOutcome.none,
      );

      s = empty();
      s.insertText('***q***');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: s.blocks.first.id, offset: 4),
        ),
      );
      expect(
        tryApplyInputRules(s, s.blocks.first.id, typedChar: 'q'),
        InputRuleOutcome.none,
      );
    });
  });
}

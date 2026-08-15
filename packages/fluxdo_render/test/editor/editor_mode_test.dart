/// EditorMode(wysiwyg/ir 双模)门控测试。
///
/// 契约(ir 大一统):两模式共享文档模型/序列化/输入规则,分叉点只有
/// 一个 —— ir 的「进入物化/离开折叠」:
/// - wysiwyg(默认):无物化无折叠无显形,退格恒删字符 / mark 自然
///   收缩,末端打字延伸(inclusive marks);
/// - ir:collapsed 光标落进可物化 mark 簇([start,end] 闭区间)→ 整簇
///   物化为可编辑字面(光标坐标全真实);字面区内是纯文本编辑(格式符
///   也是字符,Vditor 语义);光标离开 → spin 折叠回 mark。物化/折叠
///   都是语义保持变换,不进 undo。
///
/// 细粒度语义见 materialize_mark_test / live_markdown_preview_test,
/// 本文件只钉门控差异与两模式一致项。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';

EditorState makeState(EditableTextContent content, {required EditorMode mode}) {
  final s = EditorState(
    blocks: [TextBlock(id: 'e_0', content: content)],
  )..mode = mode;
  addTearDown(s.dispose);
  return s;
}

void caretAt(EditorState s, int offset) {
  s.updateSelection(
    EditorSelection.collapsed(EditorPosition(blockId: 'e_0', offset: offset)),
  );
}

TextBlock first(EditorState s) => s.blocks.first as TextBlock;

void main() {
  test('mode 默认 wysiwyg;setter 同值早退/切换通知;离开 ir 收口物化字面', () {
    final s = EditorState.fromTexts(['bold']);
    addTearDown(s.dispose);
    expect(s.mode, EditorMode.wysiwyg);

    var notified = 0;
    s.addListener(() => notified++);
    s.mode = EditorMode.wysiwyg; // 同值早退,不通知
    expect(notified, 0);
    s.mode = EditorMode.ir;
    expect(notified, 1);

    // ir 下光标进 mark = 物化态字面;切回 wysiwyg 必须全量收口折叠 ——
    // wysiwyg 不再跑收口路径,滞留字面会被当普通文本序列化(转义毁格式)。
    final s2 = makeState(
      EditableTextContent(
        text: 'bold',
        marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
      ),
      mode: EditorMode.ir,
    );
    caretAt(s2, 2);
    expect(first(s2).content.text, '**bold**', reason: '进入物化');
    expect(first(s2).content.marks, isEmpty);
    s2.mode = EditorMode.wysiwyg;
    expect(first(s2).content.text, 'bold', reason: '切模式收口折叠');
    expect(first(s2).content.marks.single.kind, MarkKind.strong);
  });

  for (final mode in EditorMode.values) {
    group('两模式一致($mode):不可物化 mark(inlineCode)', () {
      test('末端打字延伸(inclusive)、内部退格删字收缩,ir 不物化', () {
        final s = makeState(
          EditableTextContent(
            text: 'a code b',
            marks: const [
              MarkSpan(start: 2, end: 6, kind: MarkKind.inlineCode),
            ],
          ),
          mode: mode,
        );
        caretAt(s, 4);
        expect(
          first(s).content.text,
          'a code b',
          reason: 'inlineCode 不物化(投影显形兜底),两模式一致',
        );
        expect(first(s).content.marks.single.kind, MarkKind.inlineCode);
        caretAt(s, 6);
        s.insertText('X');
        var c = first(s).content;
        expect(c.text, 'a codeX b');
        expect(c.marks.single.end, 7, reason: '代码尾打字 = 继续代码');
        // 内部退格 = 删字收缩
        caretAt(s, 6);
        s.backspace();
        c = first(s).content;
        expect(c.text, 'a codX b');
        expect(c.marks.single.end, 6);
      });
    });
  }

  group('wysiwyg:末端语义(ir 下这些位置会先物化,单独钉 wysiwyg)', () {
    test('inclusive mark 末端打字延伸格式', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.insertText('X');
      final c = first(s).content;
      expect(c.text, 'boldX tail');
      expect(c.marks.single.end, 5, reason: '末端打字延伸');
    });

    test('非 inclusive mark(link)末端打字不延伸', () {
      final s = makeState(
        EditableTextContent(
          text: 'link',
          marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
          ],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.insertText('Y');
      final c = first(s).content;
      expect(c.text, 'linkY');
      expect(c.marks.single.end, 4, reason: '链接尾打字不长出链接');
    });

    test('mark 中部退格 = 删字符、mark 收缩', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 3);
      s.backspace();
      expect(first(s).content.text, 'bod');
      expect(first(s).content.marks.single.end, 3);
    });
  });

  group('wysiwyg 门控:移动无停位、光标进 mark 不物化', () {
    test('右移直接过 mark.end,文档形态不变', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 3);
      expect(first(s).content.text, 'bold tail', reason: '进 mark 不物化');
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 4);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 5, reason: '无停位,直接过界');
      expect(first(s).content.text, 'bold tail');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
    });

    test('左移进 mark 同样普通移动', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 5);
      s.moveCaretHorizontal(-1);
      expect(s.selection!.extent.offset, 4);
      s.moveCaretHorizontal(-1);
      expect(s.selection!.extent.offset, 3, reason: '逐字符,无二态');
      expect(first(s).content.text, 'bold tail');
    });
  });

  group('wysiwyg 门控:退格不物化', () {
    test('inclusive mark(strong)end 退格 = 删字、mark 收缩', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.backspace();
      expect(first(s).content.text, 'bol');
      expect(first(s).content.marks.single.end, 3);
      expect(first(s).content.text.contains('*'), isFalse, reason: '不出现字面定界符');
    });

    test('回归:link end 退格不物化(ir 下会物化的缺口在 wysiwyg 必须关死)', () {
      final s = makeState(
        EditableTextContent(
          text: 'text',
          marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
          ],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.backspace();
      final c = first(s).content;
      expect(c.text, 'tex', reason: '恒删字,不还原 [text](href) 字面');
      expect(c.marks.single.kind, MarkKind.link);
      expect(c.marks.single.end, 3);
    });

    test('回归:inlineCode end 退格不物化', () {
      final s = makeState(
        EditableTextContent(
          text: 'code',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.inlineCode)],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.backspace();
      final c = first(s).content;
      expect(c.text, 'cod');
      expect(c.marks.single.end, 3);
      expect(c.text.contains('`'), isFalse);
    });

    test('回归:带 attr(size)end 退格不物化', () {
      final s = makeState(
        EditableTextContent(
          text: 'big',
          marks: const [
            MarkSpan(start: 0, end: 3, kind: MarkKind.size, attr: '150'),
          ],
        ),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 3);
      s.backspace();
      final c = first(s).content;
      expect(c.text, 'bi');
      expect(c.marks.single.end, 2);
      expect(c.text.contains('['), isFalse);
    });
  });

  group('wysiwyg 门控:spin 不触发', () {
    test('退格删出完整字面对不折叠(ir 才折)', () {
      // '**bold***' 删尾 `*` → '**bold**'
      final s = makeState(
        EditableTextContent(text: '**bold***'),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 9);
      s.backspace();
      expect(first(s).content.text, '**bold**', reason: 'wysiwyg 无 spin');
      expect(first(s).content.marks, isEmpty);

      // ir:caretAt(9) 在字面对区间外(== matchEnd),选区收口先折
      // '**bold**' → strong,残尾 `*` 归普通字符;退格删掉它。
      final ir = makeState(
        EditableTextContent(text: '**bold***'),
        mode: EditorMode.ir,
      );
      caretAt(ir, 9);
      expect(first(ir).content.text, 'bold*', reason: '光标落点收口即折叠');
      expect(first(ir).content.marks.single.kind, MarkKind.strong);
      ir.backspace();
      expect(first(ir).content.text, 'bold');
      expect(first(ir).content.marks.single.kind, MarkKind.strong);
    });

    test('deleteForward / deleteSelection 删出完整对同样不折叠', () {
      final s = makeState(
        EditableTextContent(text: '**bo*ld**'),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 4);
      s.deleteForward();
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);

      final s2 = makeState(
        EditableTextContent(text: '**bo xx ld**'),
        mode: EditorMode.wysiwyg,
      );
      s2.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 4),
          extent: EditorPosition(blockId: 'e_0', offset: 8),
        ),
      );
      s2.deleteSelection();
      expect(first(s2).content.text, '**bold**');
      expect(first(s2).content.marks, isEmpty);
    });

    test('imeReplace 删出完整对不折叠', () {
      final s = makeState(
        EditableTextContent(text: '**bold**x'),
        mode: EditorMode.wysiwyg,
      );
      caretAt(s, 9);
      s.imeReplace('e_0', 8, 9, '', caretOffset: 8);
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);
    });
  });

  group('ir 门控:进入物化/离开折叠(抽查,细粒度见 live/materialize)', () {
    test('光标进 mark = 整簇物化;右移真实坐标穿出即折叠', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 3);
      var c = first(s).content;
      expect(c.text, '**bold** tail', reason: '进入物化为字面');
      expect(c.marks, isEmpty);
      expect(s.selection!.extent.offset, 5, reason: '光标映射到字面坐标');
      // 字面区内逐字符移动(6 → 7 → 8);8 = 区间边界,闭区间守卫下
      // 仍驻留(贴边补字符是正当编辑);9 才彻底离开 → 折叠
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 6);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 7);
      s.moveCaretHorizontal(1);
      expect(s.selection!.extent.offset, 8);
      expect(first(s).content.text, '**bold** tail', reason: '贴边仍驻留');
      s.moveCaretHorizontal(1);
      c = first(s).content;
      expect(c.text, 'bold tail', reason: '彻底离开字面对区间即折叠');
      expect(c.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 5, reason: '折叠后光标回内容坐标');
    });

    test('link 进入物化(href 可编辑),退格 = 删字面字符', () {
      final s = makeState(
        EditableTextContent(
          text: 'text',
          marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
          ],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 2); // label 内部
      var c = first(s).content;
      expect(c.text, '[text](https://x)', reason: 'link 进入物化');
      expect(c.marks, isEmpty);
      expect(s.selection!.extent.offset, 3, reason: 'label 内原位平移 +1');
      s.backspace();
      c = first(s).content;
      expect(c.text, '[txt](https://x)', reason: '退格删 label 字符');
      // 字面占满整块(块内任意位置均驻留)→ 失焦收口折叠回 link,
      // label 收缩、href 原样
      s.updateSelection(null);
      c = first(s).content;
      expect(c.text, 'txt');
      expect(c.marks.single.kind, MarkKind.link);
      expect(c.marks.single.attr, 'https://x');
    });

    test('物化/折叠是语义保持变换,不进 undo', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold tail',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 2); // 物化
      expect(first(s).content.text, '**bold** tail');
      expect(s.canUndo, isFalse, reason: '物化不产生历史步骤');
      caretAt(s, 12); // 移出折叠
      expect(first(s).content.text, 'bold tail');
      expect(s.canUndo, isFalse, reason: '折叠同样不产生历史步骤');
    });
  });
}

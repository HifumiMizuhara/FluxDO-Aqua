/// 物化事务测试:materializeMarkAt 显式命令 + ir「进入物化 → 改字面 →
/// 离开重新折叠」闭环。
///
/// ir 大一统后退格物化/边界二态已删除:光标落进可物化 mark 即整簇物化
/// 为真实字面(不进 undo),字面区内退格 = 删光标前字符(格式符也是
/// 字符),光标离开由 spin 按最新语法折叠。materializeMarkAt 仍是独立
/// 公共命令(sealHistory + 记历史,undo 一步整体回滚)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/input_rules.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';
import 'package:fluxdo_render/src/editor/model/markdown_serializer.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

EditorState makeState(
  EditableTextContent content, {
  EditorMode mode = EditorMode.wysiwyg,
}) {
  // materializeMarkAt 组默认 wysiwyg —— 直调命令不受 ir 光标收口干扰
  // (ir 下 caretAt 本身就会触发进入物化);ir 交互闭环组显式开 ir。
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
  group('materializeMarkAt(显式命令,记历史)', () {
    test('strong 物化:mark 摘除、字面定界符进文本、光标落闭定界符末尾', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
      );
      caretAt(s, 4);
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);
      expect(s.selection!.extent.offset, 8, reason: '闭定界符末尾');
    });

    test('undo 一步整体回滚(文本/marks/光标全还原);redo 重做', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
      );
      caretAt(s, 4);
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      s.undo();
      expect(first(s).content.text, 'bold');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      expect(s.selection!.extent.offset, 4, reason: '光标还原到物化前');
      s.redo();
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);
    });

    test('嵌套:只物化目标 mark,其他 mark 区间随插入平移', () {
      // 'abc':em 覆盖全段 [0,3),strong 覆盖 'bc' [1,3)
      final s = makeState(
        EditableTextContent(
          text: 'abc',
          marks: const [
            MarkSpan(start: 0, end: 3, kind: MarkKind.em),
            MarkSpan(start: 1, end: 3, kind: MarkKind.strong),
          ],
        ),
      );
      final strong = first(
        s,
      ).content.marks.firstWhere((m) => m.kind == MarkKind.strong);
      s.materializeMarkAt('e_0', strong);
      final c = first(s).content;
      expect(c.text, 'a**bc**');
      expect(c.marks.single.kind, MarkKind.em);
      // 开定界符插在 em 内部(start<1<end)→ em 拉伸;闭定界符插在
      // em.end 边界 → 不延续(insert 的边界语义)
      expect(c.marks.single.start, 0);
      expect(c.marks.single.end, 5);
    });

    test('mark 后方的原子随插入平移,身份保留', () {
      const emoji = EmojiRun(name: 'heart', url: 'u');
      final s = makeState(
        EditableTextContent(
          text: 'hi$kAtomChar',
          marks: const [MarkSpan(start: 0, end: 2, kind: MarkKind.em)],
          atoms: const {2: emoji},
        ),
      );
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      final c = first(s).content;
      expect(c.text, '*hi*$kAtomChar');
      expect(c.atoms[4], emoji);
      expect(c.marks, isEmpty);
    });

    test('link 物化:字面 [text](href),href 原样', () {
      final s = makeState(
        EditableTextContent(
          text: 'text',
          marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
          ],
        ),
      );
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      expect(first(s).content.text, '[text](https://x)');
      expect(first(s).content.marks, isEmpty);
    });

    test('陈旧 span(不在 content.marks 里)无操作', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
      );
      final rev = s.docRevision;
      s.materializeMarkAt(
        'e_0',
        const MarkSpan(start: 1, end: 3, kind: MarkKind.strong),
      );
      expect(s.docRevision, rev);
      expect(first(s).content.text, 'bold');
    });

    test('物化后序列化 = 字面文本(定界符按普通文本转义,不再是样式)', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
      );
      s.materializeMarkAt('e_0', first(s).content.marks.single);
      expect(docToMarkdown(s.blocks), r'\*\*bold\*\*');
    });
  });

  group('ir 进入物化:字面区退格语义(替代旧「闭端退格物化」)', () {
    test('光标进 mark.end = 物化停外侧,退格删内容末字符,失焦后 mark 收缩', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 4); // 进入物化 '**bold**',caret 8(闭定界符后 = 外侧)
      expect(first(s).content.text, '**bold**');
      expect(s.selection!.extent.offset, 8);
      caretAt(s, 6); // 移到内容尾(闭区间守卫,字面保持)
      s.backspace();
      expect(first(s).content.text, '**bol**', reason: '删内容末字符');
      expect(s.selection!.extent.offset, 5);
      // 字面占满整块:块内任何位置都在闭区间守卫内(贴边也算驻留,
      // Vditor 同款)。失焦/移到别的块才折叠。
      caretAt(s, 7);
      expect(first(s).content.text, '**bol**', reason: '贴边仍驻留');
      s.updateSelection(null); // 失焦收口
      expect(first(s).content.text, 'bol');
      expect(first(s).content.marks.single.end, 3);
    });

    test('闭定界符处退格 = 删格式符字符(Vditor 语义)', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 4); // '**bold**' caret 8(闭定界符后)
      expect(s.selection!.extent.offset, 8);
      s.backspace(); // 删一个闭 `*`
      expect(first(s).content.text, '**bold*');
      expect(first(s).content.marks, isEmpty, reason: '光标驻留,字面保持');
      expect(s.selection!.extent.offset, 7);
      // 继续退格 = 删剩下那个闭 `*`,再退格删内容末字符 d
      s.backspace();
      expect(first(s).content.text, '**bold');
      s.backspace();
      expect(first(s).content.text, '**bol');
      expect(s.selection!.extent.offset, 5);
    });

    test('开定界符内退格 = 删开格式符,残余语法移出后按新语法折叠', () {
      final s = makeState(
        EditableTextContent(
          text: 'ab bold cd',
          marks: const [MarkSpan(start: 3, end: 7, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 4); // 物化 'ab **bold** cd'
      caretAt(s, 5); // 'ab **|bold** cd'
      s.backspace(); // 删掉一个开 `*`
      expect(first(s).content.text, 'ab *bold** cd');
      expect(first(s).content.marks, isEmpty);
      // 移出 → *bold* 折成 em,残尾 `*` 留字面
      caretAt(s, first(s).content.length);
      final c = first(s).content;
      expect(c.text, 'ab bold* cd');
      expect(c.marks.single.kind, MarkKind.em, reason: '降级为斜体');
    });

    test('link 进入物化:退格删 label 字符;href 字面全量可删', () {
      final s = makeState(
        EditableTextContent(
          text: 'text',
          marks: const [
            MarkSpan(start: 0, end: 4, kind: MarkKind.link, attr: 'https://x'),
          ],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 4); // 物化 '[text](https://x)',caret 17(`)` 后 = 外侧)
      expect(first(s).content.text, '[text](https://x)');
      expect(s.selection!.extent.offset, 17);
      caretAt(s, 5); // label 尾(`]` 前)
      s.backspace();
      expect(
        first(s).content.text,
        '[tex](https://x)',
        reason: '退格 = 删 label 末字符',
      );
      // 失焦收口 → 折叠成 link(tex)
      s.updateSelection(null);
      final c0 = first(s).content;
      expect(c0.text, 'tex');
      expect(c0.marks.single.kind, MarkKind.link);
      // 再进入物化,尾 `)` 同样是真实字符,可直接删
      caretAt(s, 1);
      expect(first(s).content.text, '[tex](https://x)');
      s.updateSelection(
        EditorSelection.collapsed(
          EditorPosition(blockId: 'e_0', offset: first(s).content.length - 1),
        ),
      );
      s.deleteForward(); // 删 `)`
      expect(first(s).content.text, '[tex](https://x');
      expect(first(s).content.marks, isEmpty);
    });

    test('非折叠选区退格不物化(走 deleteSelection)', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 2),
          extent: EditorPosition(blockId: 'e_0', offset: 4),
        ),
      );
      s.backspace();
      expect(first(s).content.text, 'bo');
    });
  });

  group('进入物化 → 改字面 → spin 重新折叠', () {
    test('删掉闭定界符一个 * 再补回 → 折叠回 strong', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 4); // 物化 '**bold**' caret 6
      caretAt(s, 7);
      s.backspace(); // '**bold*'
      expect(first(s).content.text, '**bold*');
      s.insertText('*'); // 补回 → '**bold**',光标驻留字面保持
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);
      // input rules 兜底路径无事可做(spin 是超集)
      expect(
        tryApplyInputRules(s, 'e_0', typedChar: '*'),
        InputRuleOutcome.none,
      );
      // 字面占满整块,块内任何位置都在闭区间守卫内 → 失焦收口折叠
      s.updateSelection(null);
      expect(first(s).content.text, 'bold');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
    });

    test('**bold** 逐字面改成 *bold* → 移出折成 em', () {
      final s = makeState(
        EditableTextContent(
          text: 'bold',
          marks: const [MarkSpan(start: 0, end: 4, kind: MarkKind.strong)],
        ),
        mode: EditorMode.ir,
      );
      caretAt(s, 4); // 物化 '**bold**'
      caretAt(s, 7); // 闭定界符中间(区间内,守卫保持)
      s.backspace(); // '**bold*'
      caretAt(s, 2);
      s.backspace(); // '*bold*',光标驻留不折
      expect(first(s).content.text, '*bold*');
      expect(first(s).content.marks, isEmpty);
      // 字面占满整块 → 失焦收口折成 em
      s.updateSelection(null);
      final c = first(s).content;
      expect(c.text, 'bold');
      expect(c.marks.single.kind, MarkKind.em);
    });

    test('deleteForward 删出完整对:光标在配对区间内驻留,移出折叠', () {
      // '**bofld**' 前删掉杂质 `f` → '**bold**';光标(4)在字面对
      // 区间内部 = 守卫保持展开,移出后折叠 strong。
      final s = makeState(
        EditableTextContent(text: '**bofld**'),
        mode: EditorMode.ir,
      );
      caretAt(s, 4);
      s.deleteForward();
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty, reason: '光标驻留不折');
      s.updateSelection(null); // 字面占满整块,失焦收口
      final c = first(s).content;
      expect(c.text, 'bold');
      expect(c.marks.single.kind, MarkKind.strong);
    });

    test('deleteSelection(单块)删出完整对同样驻留→移出折叠', () {
      // '**bo xx ld**' 选中 ' xx ' 删除 → '**bold**'
      final s = makeState(
        EditableTextContent(text: '**bo xx ld**'),
        mode: EditorMode.ir,
      );
      s.updateSelection(
        const EditorSelection(
          base: EditorPosition(blockId: 'e_0', offset: 4),
          extent: EditorPosition(blockId: 'e_0', offset: 8),
        ),
      );
      s.deleteSelection();
      expect(first(s).content.text, '**bold**');
      expect(first(s).content.marks, isEmpty);
      s.updateSelection(null); // 字面占满整块,失焦收口
      final c = first(s).content;
      expect(c.text, 'bold');
      expect(c.marks.single.kind, MarkKind.strong);
    });

    test('区间外删出完整对:同一事务立即折叠(spin)', () {
      // '**bold***x':光标在尾部 x 后,退格删 x → 光标不在 '**bold**'
      // 区间内 → spin 同一事务折叠 strong,残 `*` 留字面。
      final s = makeState(
        EditableTextContent(text: '**bold***x'),
        mode: EditorMode.ir,
      );
      caretAt(s, 10);
      s.backspace(); // 删 x
      final c = first(s).content;
      expect(c.text, 'bold*', reason: '完整对折叠 + 残尾字面');
      expect(c.marks.single.kind, MarkKind.strong);
    });

    test('undo:字面区编辑一步回滚到编辑时刻的物化态;折叠不进历史', () {
      final s = makeState(
        EditableTextContent(text: '**bold***'),
        mode: EditorMode.ir,
      );
      // caretAt(9) 在 '**bold**' 区间外 → 收口先折叠(不进 undo)
      caretAt(s, 9);
      expect(first(s).content.text, 'bold*');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      expect(s.canUndo, isFalse, reason: '收口折叠不进历史');
      s.sealHistory();
      s.backspace(); // 删残尾 `*`(真实编辑,记历史)
      expect(first(s).content.text, 'bold');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
      s.undo();
      expect(first(s).content.text, 'bold*', reason: '回到删除前(折叠态)');
      expect(first(s).content.marks.single.kind, MarkKind.strong);
    });
  });
}

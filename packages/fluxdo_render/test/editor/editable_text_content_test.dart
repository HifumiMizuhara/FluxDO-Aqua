import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/node/inline_node.dart';

void main() {
  group('EditableTextContent.fromInlines / toInlines 往返', () {
    test('纯文本', () {
      final c = EditableTextContent.fromInlines(const [TextRun('hello 世界')]);
      expect(c.text, 'hello 世界');
      expect(c.marks, isEmpty);
      expect(c.toInlines(), const [TextRun('hello 世界')]);
    });

    test('粗体+斜体嵌套展开为区间', () {
      final c = EditableTextContent.fromInlines(const [
        TextRun('a'),
        StrongRun(
          children: [
            TextRun('b'),
            EmRun(children: [TextRun('c')]),
          ],
        ),
        TextRun('d'),
      ]);
      expect(c.text, 'abcd');
      expect(c.marks, const [
        MarkSpan(start: 1, end: 3, kind: MarkKind.strong),
        MarkSpan(start: 2, end: 3, kind: MarkKind.em),
      ]);
      // 往返:树形状可以不同(碎段),但语义等价 —— 再来一轮扁平化必须相等
      final round = EditableTextContent.fromInlines(c.toInlines());
      expect(round, c);
    });

    test('行内代码 + <br>', () {
      final c = EditableTextContent.fromInlines(const [
        TextRun('说 '),
        InlineCodeRun('var x'),
        LineBreakRun(),
        TextRun('第二行'),
      ]);
      expect(c.text, '说 var x\n第二行');
      expect(c.marks, const [
        MarkSpan(start: 2, end: 7, kind: MarkKind.inlineCode),
      ]);
      final inlines = c.toInlines();
      expect(inlines, const [
        TextRun('说 '),
        InlineCodeRun('var x'),
        LineBreakRun(),
        TextRun('第二行'),
      ]);
    });

    test('M2 一等公民:emoji/mention 建原子(哨兵+身份)', () {
      const emoji = EmojiRun(name: 'heart', url: 'u');
      const mention = MentionRun(username: 'sam', href: '/u/sam');
      final c = EditableTextContent.fromInlines(const [
        TextRun('hi '),
        emoji,
        TextRun(' '),
        mention,
      ]);
      expect(c.text, 'hi $kAtomChar $kAtomChar');
      expect(c.atoms[3], same(emoji));
      expect(c.atoms[5], same(mention));
      // 树往返:原子原样吐回
      expect(c.toInlines(), const [
        TextRun('hi '),
        emoji,
        TextRun(' '),
        mention,
      ]);
    });

    test('sanitizeText 剥裸 FFFC;文本路径不产孤儿哨兵', () {
      expect(EditableTextContent.sanitizeText('a${kAtomChar}b'), 'ab');
      final c = EditableTextContent.fromInlines([TextRun('x${kAtomChar}y')]);
      expect(c.text, 'xy');
      expect(c.atoms, isEmpty);
    });
  });

  group('原子编辑原语', () {
    const emoji = EmojiRun(name: 'heart', url: 'u');
    // "ab￼cd",原子在 2
    final base = EditableTextContent(
      text: 'ab',
      marks: const [],
    ).insert(2, 'cd').insertAtom(2, emoji);

    test('insertAtom 建哨兵与身份', () {
      expect(base.text, 'ab${kAtomChar}cd');
      expect(base.atoms[2], same(emoji));
      expect(base.isAtomAt(2), true);
    });

    test('原子前插入:offset 平移', () {
      final r = base.insert(0, 'XX');
      expect(r.text, 'XXab${kAtomChar}cd');
      expect(r.atoms[4], same(emoji));
      expect(r.atoms.length, 1);
    });

    test('原子后插入:offset 不动', () {
      final r = base.insert(4, 'Y');
      expect(r.atoms[2], same(emoji));
    });

    test('删除区间含原子:身份消失', () {
      final r = base.delete(1, 4);
      expect(r.text, 'ad');
      expect(r.atoms, isEmpty);
    });

    test('删除原子前区间:offset 左移', () {
      final r = base.delete(0, 1);
      expect(r.text, 'b${kAtomChar}cd');
      expect(r.atoms[1], same(emoji));
    });

    test('split 跨原子:原子归属正确侧', () {
      final (before, after) = base.split(2);
      expect(before.text, 'ab');
      expect(before.atoms, isEmpty);
      expect(after.text, '${kAtomChar}cd');
      expect(after.atoms[0], same(emoji));
    });

    test('concat:右侧原子 offset 平移', () {
      final r = base.concat(base);
      expect(r.atoms.length, 2);
      expect(r.atoms[2], same(emoji));
      expect(r.atoms[7], same(emoji));
    });
  });

  group('mark 区间代数', () {
    final plain = EditableTextContent(text: 'abcdef');

    test('applyMark 幂等 + 相邻合并', () {
      final once = plain.applyMark(1, 3, MarkKind.strong);
      final twice = once.applyMark(1, 3, MarkKind.strong);
      expect(twice.marks, once.marks);
      // 相邻区间合并为一条
      final merged = once.applyMark(3, 5, MarkKind.strong);
      expect(merged.marks, const [
        MarkSpan(start: 1, end: 5, kind: MarkKind.strong),
      ]);
    });

    test('removeMark 部分覆盖:切两侧残段', () {
      final c = plain
          .applyMark(0, 6, MarkKind.em)
          .removeMark(2, 4, MarkKind.em);
      expect(c.marks, const [
        MarkSpan(start: 0, end: 2, kind: MarkKind.em),
        MarkSpan(start: 4, end: 6, kind: MarkKind.em),
      ]);
    });

    test('isRangeFullyMarked:无缝拼接算覆盖,缝隙不算', () {
      final seamless = plain
          .applyMark(0, 3, MarkKind.strong)
          .applyMark(3, 6, MarkKind.strong);
      expect(seamless.isRangeFullyMarked(1, 5, MarkKind.strong), true);
      final gapped = plain
          .applyMark(0, 2, MarkKind.strong)
          .applyMark(4, 6, MarkKind.strong);
      expect(gapped.isRangeFullyMarked(1, 5, MarkKind.strong), false);
    });

    test('toggle:全覆盖移除、部分覆盖补齐、再 toggle 还原', () {
      final partial = plain.applyMark(2, 4, MarkKind.em);
      final filled = partial.toggleMarkInRange(0, 6, MarkKind.em);
      expect(filled.isRangeFullyMarked(0, 6, MarkKind.em), true);
      final cleared = filled.toggleMarkInRange(0, 6, MarkKind.em);
      expect(cleared.marks.where((m) => m.kind == MarkKind.em), isEmpty);
    });

    test('applyExactMarks:清旧施新', () {
      final c = plain.applyMark(0, 6, MarkKind.em).applyExactMarks(2, 4, {
        MarkKind.strong,
      });
      expect(c.isRangeFullyMarked(2, 4, MarkKind.strong), true);
      expect(c.isRangeFullyMarked(2, 4, MarkKind.em), false);
      expect(c.isRangeFullyMarked(0, 2, MarkKind.em), true);
    });

    test('marksAt:取光标前字符样式;原子处为空', () {
      const emoji = EmojiRun(name: 'x', url: 'u');
      final c = plain.applyMark(0, 3, MarkKind.strong).insertAtom(3, emoji);
      expect(c.marksAt(2), {MarkKind.strong});
      expect(c.marksAt(3), {MarkKind.strong}); // 前字符 'c'(2) 在粗体内
      expect(c.marksAt(4), isEmpty); // 前字符是原子
    });
  });

  group('编辑原语', () {
    final base = EditableTextContent(
      text: 'abcdef',
      marks: const [MarkSpan(start: 2, end: 4, kind: MarkKind.strong)], // cd
    );

    test('insert 在区间前:区间右移', () {
      final r = base.insert(0, 'xx');
      expect(r.text, 'xxabcdef');
      expect(r.marks, const [
        MarkSpan(start: 4, end: 6, kind: MarkKind.strong),
      ]);
    });

    test('insert 在区间内部:区间拉长(样式延续)', () {
      final r = base.insert(3, 'X');
      expect(r.text, 'abcXdef');
      expect(r.marks, const [
        MarkSpan(start: 2, end: 5, kind: MarkKind.strong),
      ]);
    });

    test('insert 恰在区间末端边界:不延续', () {
      final r = base.insert(4, 'X');
      expect(r.text, 'abcdXef');
      expect(r.marks, const [
        MarkSpan(start: 2, end: 4, kind: MarkKind.strong),
      ]);
    });

    test('delete 覆盖区间左半:区间收缩', () {
      final r = base.delete(1, 3); // 删 bc
      expect(r.text, 'adef');
      expect(r.marks, const [
        MarkSpan(start: 1, end: 2, kind: MarkKind.strong),
      ]);
    });

    test('delete 完全覆盖区间:区间消失', () {
      final r = base.delete(1, 5);
      expect(r.text, 'af');
      expect(r.marks, isEmpty);
    });

    test('replace = delete+insert', () {
      final r = base.replace(2, 4, '你好啊');
      expect(r.text, 'ab你好啊ef');
    });

    test('split 区间跨切点:两侧各留一半', () {
      final (before, after) = base.split(3);
      expect(before.text, 'abc');
      expect(before.marks, const [
        MarkSpan(start: 2, end: 3, kind: MarkKind.strong),
      ]);
      expect(after.text, 'def');
      expect(after.marks, const [
        MarkSpan(start: 0, end: 1, kind: MarkKind.strong),
      ]);
    });

    test('concat 区间平移', () {
      final other = EditableTextContent(
        text: 'gh',
        marks: const [MarkSpan(start: 0, end: 2, kind: MarkKind.em)],
      );
      final r = base.concat(other);
      expect(r.text, 'abcdefgh');
      expect(r.marks, const [
        MarkSpan(start: 2, end: 4, kind: MarkKind.strong),
        MarkSpan(start: 6, end: 8, kind: MarkKind.em),
      ]);
    });
  });
}

/// 大表情(only-emoji)判定测试。
///
/// 规则对齐 cook 引擎实测:一**行**(软换行分段)只有 emoji(空白不算
/// 内容)且 ≤3 个 → 该行全部大号;≥4 个或掺了别的内容 → 该行全部普通。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

EditableTextContent _content(List<InlineNode> atoms, {String between = ''}) {
  var c = EditableTextContent(text: '');
  for (var i = 0; i < atoms.length; i++) {
    if (i > 0 && between.isNotEmpty) {
      c = c.insert(c.length, between);
    }
    c = c.insertAtom(c.length, atoms[i]);
  }
  return c;
}

EmojiRun _e([String name = 'rofl']) => EmojiRun(name: name, url: '$name.png');

List<bool> _flags(EditableTextContent c) => [
  for (final n in c.toInlines())
    if (n is EmojiRun) n.isOnlyEmoji,
];

void main() {
  group('整段只有 emoji', () {
    test('1 个 → 大', () {
      expect(_flags(_content([_e()])), [true]);
    });

    test('3 个 → 全大(上限)', () {
      expect(_flags(_content([_e(), _e(), _e()], between: ' ')), [
        true,
        true,
        true,
      ]);
    });

    test('4 个 → 全部不大', () {
      expect(_flags(_content([_e(), _e(), _e(), _e()], between: ' ')), [
        false,
        false,
        false,
        false,
      ]);
    });

    test('紧挨着不加空格也算', () {
      expect(_flags(_content([_e(), _e()])), [true, true]);
    });

    test('前后有空白仍算(空白不是内容)', () {
      var c = EditableTextContent(text: '');
      c = c.insert(0, '  ');
      c = c.insertAtom(c.length, _e());
      c = c.insert(c.length, '   ');
      expect(_flags(c), [true]);
    });
  });

  group('掺了别的内容', () {
    test('emoji 前有文字 → 不大', () {
      var c = EditableTextContent(text: '');
      c = c.insert(0, '文字 ');
      c = c.insertAtom(c.length, _e());
      expect(_flags(c), [false]);
    });

    test('emoji 后补文字 → 从大变回不大', () {
      var c = _content([_e()]);
      expect(_flags(c), [true], reason: '先确认是大的');
      c = c.insert(c.length, 'a');
      expect(_flags(c), [false], reason: '补了正文就该缩回去');
    });
  });

  group('判定按行走(软换行分段),与服务端渲染一致', () {
    test('回车后不缩回去', () {
      var c = _content([_e()]);
      expect(_flags(c), [true], reason: '先确认是大的');
      c = c.insert(c.length, '\n');
      expect(_flags(c), [true]);
      expect(c.hasOnlyEmojiLine, isTrue, reason: '两边判据要一致');
    });

    test('下一行打字,上一行的表情仍然大', () {
      var c = _content([_e()]);
      c = c.insert(c.length, '\naaaa');
      expect(_flags(c), [true], reason: '发出去就是第一行大表情+第二行文字');
      expect(c.hasOnlyEmojiLine, isTrue);
    });

    test('同一行里表情后面跟文字 → 那一行不大', () {
      var c = _content([_e()]);
      c = c.insert(c.length, 'aaaa');
      expect(_flags(c), [false]);
    });

    test('多行各自判定:纯表情行大,混排行不大', () {
      var c = _content([_e()]);
      c = c.insert(c.length, '\n');
      c = c.insertAtom(c.length, _e('smile'));
      c = c.insert(c.length, ' 文字');
      expect(_flags(c), [true, false]);
    });

    test('显形定界符出现在纯表情行,不改变按行判定', () {
      // 首行:spoiler mark 罩住单个 emoji;次行:普通文字。
      // 光标进 mark → 显形出 [spoiler]/[/spoiler] 虚拟定界符,
      // 零逻辑宽纯投影,不算行内容 —— 大表情不能因此缩小。
      final c = EditableTextContent(
        text: '￼\n文字',
        marks: const [MarkSpan(start: 0, end: 1, kind: MarkKind.spoilerInline)],
        atoms: {0: _e()},
      );
      final inlines = c.toInlines(forEditing: true, revealMarkdownAt: 0);
      final e = inlines.whereType<EmojiRun>().single;
      expect(e.isOnlyEmoji, isTrue);
    });
  });

  group('hasOnlyEmojiLine(渲染侧放开行高钳制的判据)', () {
    test('与 isOnlyEmoji 同口径:≤3 个纯 emoji 段为真', () {
      expect(_content([_e()]).hasOnlyEmojiLine, isTrue);
      expect(
        _content([_e(), _e(), _e()], between: ' ').hasOnlyEmojiLine,
        isTrue,
      );
    });

    test('4 个 / 掺正文 / 空段 → 假(不该放开钳制)', () {
      expect(_content([_e(), _e(), _e(), _e()]).hasOnlyEmojiLine, isFalse);
      expect(_content([_e()]).insert(0, '文字').hasOnlyEmojiLine, isFalse);
      expect(EditableTextContent(text: '').hasOnlyEmojiLine, isFalse);
    });
  });

  test('没有 emoji 的段落不受影响', () {
    final c = EditableTextContent(text: '').insert(0, '普通文字');
    expect(_flags(c), isEmpty);
    expect(c.toInlines(), isNotEmpty);
  });
}

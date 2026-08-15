/// 「文本即链接」的裸链接:改文字时 href 要跟着改,否则切源码就成了
/// `[改过的文字](原地址)` —— 显示一个地址、跳另一个。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';

const _url = 'https://linux.do/t/topic/2659942/18?u=is_hp';

EditableTextContent _bareLink() => EditableTextContent(
  text: _url,
  marks: [
    MarkSpan(start: 0, end: _url.length, kind: MarkKind.link, attr: _url),
  ],
);

void main() {
  replaceCarriedTests();

  test('删掉查询参数:href 跟着变', () {
    final c = _bareLink();
    final cut = c.delete(_url.indexOf('?'), _url.length);

    expect(cut.text, 'https://linux.do/t/topic/2659942/18');
    expect(cut.marks.single.attr, cut.text, reason: '两边必须还相等');
  });

  test('末尾续打字符:href 跟着变', () {
    final c = _bareLink();
    final added = c.insert(_url.length - 1, 'X');

    expect(added.marks.single.attr, added.text);
  });

  test('自定义文案的链接不受影响', () {
    const label = '点我';
    final c = EditableTextContent(
      text: label,
      marks: [
        MarkSpan(start: 0, end: label.length, kind: MarkKind.link, attr: _url),
      ],
    );

    final edited = c.insert(label.length, '看看');

    expect(edited.text, '点我看看');
    expect(edited.marks.single.attr, _url, reason: '自定义文案不联动');
  });
}

/// replace(选中替换)路径:carried 重建不得把裸链接撕碎。
///
/// delete+insert 各自按「自己当时覆盖的切片」联动 attr,拼不回整体;
/// carried 段若再按旧 attr 罩回去,一个视觉链接会碎成两三段不同 href
/// 的 mark(改法见 replace 的裸链接整段重建分支)。
void replaceCarriedTests() {
  const url = 'https://linux.do/t/topic/2659942/18?u=is_hp';

  EditableTextContent bare() => EditableTextContent(
    text: url,
    marks: [
      MarkSpan(start: 0, end: url.length, kind: MarkKind.link, attr: url),
    ],
  );

  test('选中尾部查询参数直接打字:单段 mark,href 跟新文本', () {
    final out = bare().replace(url.indexOf('?'), url.length, 'x');
    expect(out.text, 'https://linux.do/t/topic/2659942/18x');
    expect(out.marks.single.attr, out.text, reason: '不碎段、不留旧 href');
    expect(out.marks.single.start, 0);
    expect(out.marks.single.end, out.text.length);
  });

  test('选中中段替换:单段 mark,href 跟新文本', () {
    final s = url.indexOf('topic');
    final out = bare().replace(s, s + 5, 'x');
    expect(out.text, 'https://linux.do/t/x/2659942/18?u=is_hp');
    expect(out.marks.single.attr, out.text);
  });

  test('自定义文案链接的选中替换:attr 保持,不联动', () {
    const label = '点我看看';
    final c = EditableTextContent(
      text: label,
      marks: [
        MarkSpan(start: 0, end: label.length, kind: MarkKind.link, attr: url),
      ],
    );
    final out = c.replace(2, 4, '瞧瞧');
    expect(out.text, '点我瞧瞧');
    expect(out.marks.single.attr, url, reason: '自定义文案不联动');
  });
}

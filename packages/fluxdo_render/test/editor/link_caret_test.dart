/// onLinkCaret:collapsed 光标进出链接的上抛(工具条锚定数据)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show LinkRun, TextRun;

void main() {
  late List<LinkCaretInfo?> events;

  Future<EditorState> pump(WidgetTester tester) async {
    events = [];
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'e_0',
          content: EditableTextContent.fromInlines(const [
            TextRun('前缀 '),
            LinkRun(href: 'https://x.test/a', children: [TextRun('链接文字')]),
            TextRun(' 后缀'),
          ]),
        ),
      ],
    );
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FluxdoEditor(
            state: state,
            autofocus: true,
            onLinkCaret: events.add,
          ),
        ),
      ),
    );
    await tester.pump();
    return state;
  }

  testWidgets('光标进链接 → 上抛 info;移出 → null;变化才通知', (tester) async {
    final state = await pump(tester);
    // 落进链接中间("前缀 "=3 字符,链接文字 4 字符 → offset 5)
    state.updateSelection(
      EditorSelection.collapsed(
        const EditorPosition(blockId: 'e_0', offset: 5),
      ),
    );
    await tester.pump();
    await tester.pump();
    final info = events.whereType<LinkCaretInfo>().last;
    expect(info.href, 'https://x.test/a');
    expect(info.text, '链接文字');
    expect(info.start, 3);
    expect(info.end, 7);
    expect(info.rangeGlobal.width, greaterThan(0));

    // 移出到后缀
    final before = events.length;
    state.updateSelection(
      EditorSelection.collapsed(
        const EditorPosition(blockId: 'e_0', offset: 9),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(events.length, greaterThan(before));
    expect(events.last, isNull, reason: '离开链接上抛 null');

    // 原地再动一次(仍在链接外):不重复通知
    final settled = events.length;
    state.updateSelection(
      EditorSelection.collapsed(
        const EditorPosition(blockId: 'e_0', offset: 8),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(events.length, settled, reason: '同为 null 不重复上抛');
  });

  testWidgets('range 选区 → null(工具条只服务 collapsed)', (tester) async {
    final state = await pump(tester);
    state.updateSelection(
      EditorSelection.collapsed(
        const EditorPosition(blockId: 'e_0', offset: 5),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(events.last, isNotNull);

    state.updateSelection(
      const EditorSelection(
        base: EditorPosition(blockId: 'e_0', offset: 4),
        extent: EditorPosition(blockId: 'e_0', offset: 6),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(events.last, isNull);
  });

  testWidgets('行内链接(前后有文字)同样上抛(工具条不区分行内/独占)', (tester) async {
    final state = await pump(tester);
    // pump 的 fixture 本就是行内:前缀 + 链接 + 后缀
    final tb = state.blocks.first as TextBlock;
    expect(tb.content.text, '前缀 链接文字 后缀', reason: '行内形态确认');
    state.updateSelection(
      EditorSelection.collapsed(
        const EditorPosition(blockId: 'e_0', offset: 4),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(events.whereType<LinkCaretInfo>().last.href, 'https://x.test/a');
  });
}

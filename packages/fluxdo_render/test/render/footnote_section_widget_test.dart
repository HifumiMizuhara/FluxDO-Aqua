import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/node/node.dart';
import 'package:fluxdo_render/src/render/node_factory.dart';

import '../test_text_finders.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('buildFootnotesSection 渲染编号 + 正文 + 分隔线', (tester) async {
    final node = FootnotesSectionNode(
      id: 'b_0',
      entries: const [
        FootnoteEntry(id: 'fn:1', number: '1', inlines: [TextRun('脚注甲')]),
        FootnoteEntry(id: 'fn:2', number: '2', inlines: [TextRun('脚注乙')]),
      ],
    );
    final factory = NodeFactory();
    await tester.pumpWidget(
      _wrap(Builder(builder: (ctx) => factory.build(ctx, node))),
    );
    expect(findRenderedText('1.'), findsOneWidget);
    expect(findRenderedText('2.'), findsOneWidget);
    expect(findRenderedTextContaining('脚注甲'), findsOneWidget);
    expect(findRenderedTextContaining('脚注乙'), findsOneWidget);
  });

  testWidgets('entries 为空 → 渲染 SizedBox.shrink(不占高)', (tester) async {
    const node = FootnotesSectionNode(id: 'b_0');
    final factory = NodeFactory();
    await tester.pumpWidget(
      _wrap(Builder(builder: (ctx) => factory.build(ctx, node))),
    );
    expect(findRenderedText('1.'), findsNothing);
    // 无文本、无分隔线内容
    expect(find.byType(InkWell), findsNothing);
  });
}

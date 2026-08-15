/// 纯上屏路径规则命中后的 reconcile(_lastSent 一致性)。
///
/// 真机复现:文档已有 `~~~~`(四个波浪号,规则不触发),光标插到中间,
/// 打中文并上屏 —— 收尾通知走「纯上屏」路(diff==null),补判规则命中
/// 后文档删掉四个波浪号,而这条路**原本直接 return**,跳过常规路径的
/// reconcile:平台窗口留着转换前的旧文本,`_lastSent` 与文档从此失同步,
/// 之后每一击的 diff 全部错位(拼音以字面形式一段段堆进正文)。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/editor_ime_client.dart';
import 'package:fluxdo_render/src/editor/model/editable_text_content.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

final pad = EditorImeClient.padCharForTesting;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  (EditorState, EditorImeClient) attach(String text, int caret) {
    final state = EditorState(
      blocks: [
        TextBlock(
          id: 'b0',
          content: EditableTextContent(text: text),
        ),
      ],
    );
    state.updateSelection(
      EditorSelection.collapsed(EditorPosition(blockId: 'b0', offset: caret)),
    );
    final ime = EditorImeClient(state: state);
    ime.debugAttachToBlock(
      'b0',
      EditorImeClient.debugFormat(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: caret),
        ),
      ),
    );
    return (state, ime);
  }

  TextBlock blk(EditorState s) => s.blocks.first as TextBlock;

  test('纯上屏规则命中 → _lastSent 回喂纠正,与文档一致', () {
    final (state, ime) = attach('~~~~', 2);
    // 拼音 zi 预编辑(插在波浪号中间)
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad~~zi~~',
        selection: const TextSelection.collapsed(offset: 5),
        composing: const TextRange(start: 3, end: 5),
      ),
    );
    // 上屏第一步:文本变「~~字~~」,composing 滞后(Windows 两步上屏)
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad~~字~~',
        selection: const TextSelection.collapsed(offset: 4),
        composing: const TextRange(start: 3, end: 4),
      ),
    );
    // 收尾通知:无文本变化(diff==null 纯上屏路径),规则在此补判
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad~~字~~',
        selection: const TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    );
    final c = blk(state).content;
    expect(c.text, '字', reason: '规则命中,波浪号被转换吃掉');
    expect(c.marks.single.kind, MarkKind.lineThrough);
    // 核心断言:平台窗口必须被回喂纠正,否则下一击 diff 全错位
    expect(
      ime.debugLastSent.text,
      '$pad字',
      reason: '纯上屏路径规则命中后须 reconcile,_lastSent 与文档一致',
    );
  });

  test('纠正后的下一击键不错位', () {
    final (state, ime) = attach('~~~~', 2);
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad~~zi~~',
        selection: const TextSelection.collapsed(offset: 5),
        composing: const TextRange(start: 3, end: 5),
      ),
    );
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad~~字~~',
        selection: const TextSelection.collapsed(offset: 4),
        composing: const TextRange(start: 3, end: 4),
      ),
    );
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad~~字~~',
        selection: const TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    );
    // 第二轮:基于**纠正后**的窗口(␠字)在字后打 x
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad字x',
        selection: const TextSelection.collapsed(offset: 3),
        composing: TextRange.empty,
      ),
    );
    expect(blk(state).content.text, '字x', reason: '基线已纠正,diff 不错位');
    expect(state.selection!.extent.offset, 2);
  });

  test('规则未命中的纯上屏不触发回喂(零开销路径)', () {
    final (state, ime) = attach('', 0);
    ime.updateEditingValue(
      TextEditingValue(
        text: '${pad}ni',
        selection: const TextSelection.collapsed(offset: 3),
        composing: const TextRange(start: 1, end: 3),
      ),
    );
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad你',
        selection: const TextSelection.collapsed(offset: 2),
        composing: const TextRange(start: 1, end: 2),
      ),
    );
    ime.updateEditingValue(
      TextEditingValue(
        text: '$pad你',
        selection: const TextSelection.collapsed(offset: 2),
        composing: TextRange.empty,
      ),
    );
    expect(blk(state).content.text, '你');
    expect(ime.debugLastSent.text, '$pad你', reason: '本就一致,无需纠正');
  });
}

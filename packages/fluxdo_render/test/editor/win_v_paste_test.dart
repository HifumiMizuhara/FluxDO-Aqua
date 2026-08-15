/// Win+V(Windows 剪贴板历史)粘贴:注入的 `V` 不带 Ctrl 修饰位,
/// 需靠「character==null + 主修饰键刚按下」补偿。真机日志固化。
///
/// 补偿窗口只在 Windows 生效(SendInput 注入是 Windows 平台行为),
/// 用例需显式覆写 defaultTargetPlatform。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/editor/input/editor_key_handler.dart';
import 'package:fluxdo_render/src/editor/model/editor_state.dart';

KeyEvent down(LogicalKeyboardKey key, {String? character}) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyV,
  logicalKey: key,
  character: character,
  timeStamp: Duration.zero,
);

KeyEvent up(LogicalKeyboardKey key) => KeyUpEvent(
  physicalKey: PhysicalKeyboardKey.keyV,
  logicalKey: key,
  timeStamp: Duration.zero,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EditorState state;
  late int pasteCount;

  KeyEventResult send(KeyEvent e) => handleEditorKeyEvent(
    state,
    e,
    onEdited: () {},
    onClipboardPaste: () => pasteCount++,
  );

  setUp(() {
    // 修饰键补偿是 Windows 门控的,测试环境默认 android,须显式覆写
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    // 修饰键跟踪是模块级全局,跨用例/跨文件会互相污染,必须重置
    debugResetModifierState();
    state = EditorState.fromTexts(['abc']);
    state.updateSelection(
      EditorSelection.collapsed(
        EditorPosition(blockId: state.blocks.first.id, offset: 0),
      ),
    );
    pasteCount = 0;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    state.dispose();
  });

  test('Win+V 注入序列:Ctrl 按下后紧跟无修饰位的 V → 认粘贴', () {
    // 真机日志:Meta Left ↓、Control Left ↓、V(ctrl=false, char=null)
    send(down(LogicalKeyboardKey.metaLeft));
    send(down(LogicalKeyboardKey.controlLeft));
    expect(send(down(LogicalKeyboardKey.keyV)), KeyEventResult.handled);
    expect(pasteCount, 1);
  });

  test('完整注入序列:抖动式 Ctrl 抬起(<80ms)不清空补偿窗口,仍认粘贴', () async {
    // 真机抓包的完整序列:Ctrl↓ → Ctrl↑(间隔仅 10~40ms)→ V↓ —— 抬起
    // 发生在 V 之前,且是**普通真实事件**(synthesized==false,曾试图用
    // 该标记区分真假抬起,被抓包证伪)。作废规则若不豁免抖动式抬起,
    // 窗口在轮到 V 之前就被清空,补偿形同虚设 —— 测试绿(上面那个用例
    // 的序列漏了这一步)真机红。本用例固化完整序列,防判据回退。
    send(down(LogicalKeyboardKey.controlLeft));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    send(up(LogicalKeyboardKey.controlLeft));
    expect(send(down(LogicalKeyboardKey.keyV)), KeyEventResult.handled);
    expect(pasteCount, 1);
    // 宿主可逆路径(图片粘贴)用的宽松版判定,同一事件也应为真。
    expect(
      primaryModifierHeldForReversibleAction(down(LogicalKeyboardKey.keyV)),
      isTrue,
    );
  });

  test('正常松开 Ctrl(>80ms)立即作废窗口(粘贴后纯回车不误判)', () async {
    send(down(LogicalKeyboardKey.controlLeft));
    // 真人按住 Ctrl 的时长远超抖动阈值(80ms),隔开再抬起
    await Future<void>.delayed(const Duration(milliseconds: 120));
    send(up(LogicalKeyboardKey.controlLeft));
    expect(
      send(down(LogicalKeyboardKey.keyV)),
      KeyEventResult.ignored,
      reason: '正常节奏的松开是真实释放,窗口应立刻清空',
    );
    expect(pasteCount, 0);
    expect(
      primaryModifierHeldForReversibleAction(down(LogicalKeyboardKey.keyV)),
      isFalse,
    );
  });

  test('裸敲 v(带 character)不误判成粘贴', () {
    send(down(LogicalKeyboardKey.controlLeft));
    send(down(LogicalKeyboardKey.keyV, character: 'v'));
    expect(pasteCount, 0, reason: 'character 非 null = 真的在打字');
  });

  test('没按过修饰键的孤立 V 不触发粘贴', () async {
    // 隔开与上一个用例的修饰键时间窗(补偿判据用真实时钟;testWidgets
    // 的 FakeAsync 推不动它,所以这三个用例用裸 test)
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(send(down(LogicalKeyboardKey.keyV)), KeyEventResult.ignored);
    expect(pasteCount, 0);
  });

  test('非 Windows 平台不吃补偿:同一注入序列不认粘贴', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    send(down(LogicalKeyboardKey.metaLeft));
    send(down(LogicalKeyboardKey.controlLeft));
    send(down(LogicalKeyboardKey.keyV));
    expect(pasteCount, 0, reason: 'SendInput 注入是 Windows 平台行为,别的平台吃补偿只会扩大误判面');
  });
}

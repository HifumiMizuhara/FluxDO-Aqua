import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/selection/selection_coordinator.dart';
import 'package:fluxdo_render/src/selection/selection_geometry.dart';
import 'package:fluxdo_render/src/selection/selection_registry.dart';

void main() {
  DocumentSelection sel(int seq) => DocumentSelection(
    base: DocumentPosition(blockId: SelectableBlockId(seq), renderOffset: 0),
    extent: DocumentPosition(blockId: SelectableBlockId(seq), renderOffset: 2),
  );

  test('B 起选清掉 A 的选区(全局唯一活动选区)', () {
    final a = SelectionController(SelectionRegistry());
    final b = SelectionController(SelectionRegistry());

    a.selection = sel(1);
    expect(a.selection, isNotNull);

    // B 起选 → A 被协调器清掉
    b.selection = sel(2);
    expect(b.selection, isNotNull);
    expect(a.selection, isNull, reason: 'B 起选应清掉 A');

    a.dispose();
    b.dispose();
  });

  test('同一 controller 连续改选区不自我清除', () {
    final a = SelectionController(SelectionRegistry());
    a.selection = sel(1);
    a.selection = sel(1).copyWith(
      extent: const DocumentPosition(
        blockId: SelectableBlockId(1),
        renderOffset: 5,
      ),
    );
    expect(a.selection, isNotNull, reason: '同 controller 改选区不应被清');
    a.dispose();
  });

  test('clear 注销活动者,后续他帖起选不误清', () {
    final a = SelectionController(SelectionRegistry());
    final b = SelectionController(SelectionRegistry());
    a.selection = sel(1);
    a.clear();
    expect(a.selection, isNull);
    // a 已注销,b 起选不该触碰已为 null 的 a(也不报错)
    b.selection = sel(2);
    expect(b.selection, isNotNull);
    expect(a.selection, isNull);
    a.dispose();
    b.dispose();
  });

  test('dispose 的 controller 不再是活动者', () {
    final a = SelectionController(SelectionRegistry());
    a.selection = sel(1);
    a.dispose();
    // 协调器 active 已被 deactivate;新 controller 起选正常
    final b = SelectionController(SelectionRegistry());
    b.selection = sel(2);
    expect(b.selection, isNotNull);
    b.dispose();
  });

  test('coordinator 单例', () {
    expect(SelectionCoordinator.instance, same(SelectionCoordinator.instance));
  });
}

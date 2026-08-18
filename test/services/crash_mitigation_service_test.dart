import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/crash_mitigation_service.dart';
import 'package:fluxdo/services/memory_pressure_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(MemoryPressureRegistry.clearHandlers);

  test('画像デコード上限は長辺と総ピクセル数を同時に守る', () {
    final clamped = CrashMitigationService.clampTargetSize(
      8000,
      6000,
      const ui.TargetImageSize(),
    );

    expect(clamped.width, isNotNull);
    expect(clamped.height, isNotNull);
    expect(
      clamped.width! * clamped.height!,
      lessThanOrEqualTo(CrashMitigationService.maxDecodedPixels),
    );
    final longEdge = clamped.width! > clamped.height!
        ? clamped.width!
        : clamped.height!;
    expect(
      longEdge,
      lessThanOrEqualTo(CrashMitigationService.maxDecodedDimension),
    );
    expect(clamped.width! / clamped.height!, closeTo(4 / 3, 0.01));
  });

  test('上限内の画像は要求サイズを変更しない', () {
    const requested = ui.TargetImageSize(width: 1200, height: 800);

    expect(
      CrashMitigationService.clampTargetSize(1200, 800, requested),
      same(requested),
    );
  });

  test('init は全プラットフォームで同じ画像キャッシュ上限を適用する', () {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = 256 * 1024 * 1024;
    cache.maximumSize = 30000;

    CrashMitigationService.init();

    expect(cache.maximumSizeBytes, CrashMitigationService.imageCacheMaxBytes);
    expect(cache.maximumSize, CrashMitigationService.imageCacheMaxEntries);
  });

  test('soft トリムは上限を元に戻す（恒久的に縮めない）', () {
    CrashMitigationService.init();
    final cache = PaintingBinding.instance.imageCache;

    CrashMitigationService.trimMemory(MemoryPressureLevel.soft);

    expect(cache.maximumSizeBytes, CrashMitigationService.imageCacheMaxBytes);
    expect(cache.maximumSize, CrashMitigationService.imageCacheMaxEntries);
  });

  test('トリムは登録済みハンドラへ段階を伝える', () {
    final seen = <MemoryPressureLevel>[];
    MemoryPressureRegistry.register('test', seen.add);

    CrashMitigationService.trimMemory(MemoryPressureLevel.soft);
    CrashMitigationService.handleSystemMemoryPressure();

    expect(seen, [MemoryPressureLevel.soft, MemoryPressureLevel.hard]);
  });

  test('ハンドラが投げても残りのハンドラは走る', () {
    var reached = false;
    MemoryPressureRegistry.register('throws', (_) => throw StateError('boom'));
    MemoryPressureRegistry.register('after', (_) => reached = true);

    MemoryPressureRegistry.dispatch(MemoryPressureLevel.hard);

    expect(reached, isTrue);
  });

  // 臨界区間はフレーム境界（endOfFrame）を待つので、フレームを回せる
  // testWidgets でないと完了しない。
  testWidgets('CF 臨界区間は action を 1 回だけ実行しフラグを戻す', (tester) async {
    var runs = 0;

    final future = CrashMitigationService.runCfWebViewCriticalSection(
      reason: 'test',
      action: () async {
        runs++;
        return 'done';
      },
    );

    // 前後に 1 回ずつ、計 3 回の endOfFrame を跨ぐ
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    expect(await future, 'done');
    expect(runs, 1);
    expect(CrashMitigationService.cfWebViewCriticalSectionActive, isFalse);
  });

  testWidgets('CF 臨界区間は live 画像を落とさない（soft トリム）', (tester) async {
    final levels = <MemoryPressureLevel>[];
    MemoryPressureRegistry.register('test', levels.add);

    final future = CrashMitigationService.runCfWebViewCriticalSection(
      reason: 'test',
      action: () async => null,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await future;

    expect(levels, [MemoryPressureLevel.soft]);
  });
}

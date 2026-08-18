import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/media/video_native_slot_pool.dart';
import 'package:fluxdo/utils/platform_utils.dart';

void main() {
  setUp(() {
    // デスクトップ扱い（枠 4）に固定してから、テストごとに枠を空にする。
    PlatformUtils.debugDesktopOverride = true;
    while (VideoNativeSlotPool.inUse > 0) {
      VideoNativeSlotPool.release();
    }
  });

  tearDown(() {
    PlatformUtils.debugDesktopOverride = null;
  });

  test('上限までは即座に枠が取れる', () {
    for (var i = 0; i < VideoNativeSlotPool.maxSlots; i++) {
      expect(VideoNativeSlotPool.acquireOrEnqueue(), isNull);
    }
    expect(VideoNativeSlotPool.inUse, VideoNativeSlotPool.maxSlots);
  });

  test('上限を超えた要求は順番待ちになり、返却で通る', () async {
    for (var i = 0; i < VideoNativeSlotPool.maxSlots; i++) {
      VideoNativeSlotPool.acquireOrEnqueue();
    }

    final waiter = VideoNativeSlotPool.acquireOrEnqueue();
    expect(waiter, isNotNull);
    expect(VideoNativeSlotPool.queueLength, 1);

    var granted = false;
    unawaited(waiter!.future.then((_) => granted = true));
    expect(granted, isFalse);

    VideoNativeSlotPool.release();
    await Future<void>.delayed(Duration.zero);

    expect(granted, isTrue);
    // 譲渡なので在庫数は動かない（超過発行しない）
    expect(VideoNativeSlotPool.inUse, VideoNativeSlotPool.maxSlots);
    expect(VideoNativeSlotPool.queueLength, 0);
  });

  test('順番待ちは LIFO（直近に mount された動画を優先する）', () async {
    for (var i = 0; i < VideoNativeSlotPool.maxSlots; i++) {
      VideoNativeSlotPool.acquireOrEnqueue();
    }
    final first = VideoNativeSlotPool.acquireOrEnqueue()!;
    final second = VideoNativeSlotPool.acquireOrEnqueue()!;

    final order = <String>[];
    unawaited(first.future.then((_) => order.add('first')));
    unawaited(second.future.then((_) => order.add('second')));

    VideoNativeSlotPool.release();
    await Future<void>.delayed(Duration.zero);

    expect(order, ['second']);
  });

  test('待機中の取り下げは枠を発行しない', () async {
    for (var i = 0; i < VideoNativeSlotPool.maxSlots; i++) {
      VideoNativeSlotPool.acquireOrEnqueue();
    }
    final waiter = VideoNativeSlotPool.acquireOrEnqueue()!;

    VideoNativeSlotPool.cancelWaiter(waiter);

    expect(waiter.future, throwsA(isA<VideoSlotCancelledException>()));
    expect(VideoNativeSlotPool.queueLength, 0);
    expect(VideoNativeSlotPool.inUse, VideoNativeSlotPool.maxSlots);
  });

  test('取り下げ済みの札は譲渡先から飛ばされる', () async {
    for (var i = 0; i < VideoNativeSlotPool.maxSlots; i++) {
      VideoNativeSlotPool.acquireOrEnqueue();
    }
    final cancelled = VideoNativeSlotPool.acquireOrEnqueue()!;
    final alive = VideoNativeSlotPool.acquireOrEnqueue()!;

    // LIFO なので後入れの alive が先に呼ばれる想定。cancelled を先に
    // 取り下げてから release し、alive が正しく通ることを見る。
    VideoNativeSlotPool.cancelWaiter(cancelled);
    expect(cancelled.future, throwsA(isA<VideoSlotCancelledException>()));

    var granted = false;
    unawaited(alive.future.then((_) => granted = true));
    VideoNativeSlotPool.release();
    await Future<void>.delayed(Duration.zero);

    expect(granted, isTrue);
    expect(VideoNativeSlotPool.queueLength, 0);
  });

  test('待ちがない状態での返却は在庫を減らす', () {
    VideoNativeSlotPool.acquireOrEnqueue();
    expect(VideoNativeSlotPool.inUse, 1);

    VideoNativeSlotPool.release();

    expect(VideoNativeSlotPool.inUse, 0);
  });

  test('モバイルの枠はデスクトップより少ない', () {
    PlatformUtils.debugDesktopOverride = false;
    final mobile = VideoNativeSlotPool.maxSlots;
    PlatformUtils.debugDesktopOverride = true;
    final desktop = VideoNativeSlotPool.maxSlots;

    expect(mobile, lessThan(desktop));
  });
}

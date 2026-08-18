import 'dart:async';
import 'dart:collection';

import '../../utils/platform_utils.dart';

/// 同時に生かせるネイティブ動画デコーダの本数を絞る門。
///
/// ## 病巣
///
/// `DiscourseVideoPlayer` は sliver の cacheExtent に入った瞬間 —— つまり
/// **画面に出る前** —— に `VideoPlayerController.initialize()` を呼ぶ。
/// 1 本ごとに Android なら ExoPlayer インスタンス + MediaCodec + 入力
/// バッファ（数十 MB 規模、しかも一部はドライバ側の確保で Dart からは
/// 完全に不可視）。動画が並んだ話題を速くスクロールすると、上限なしに
/// 積み上がる。ImageCache の上限をいくら下げてもここには効かない。
///
/// iframe 側には既に [EmbeddedBrowserControllerPool]（上限 3）があるのに、
/// より重いネイティブ動画は素通しだった —— その穴を塞ぐのがこの門。
///
/// ## 方針：入場制限のみ、追い出しはしない
///
/// 初期化済みコントローラを強制破棄すると、その Texture を表示中の
/// ホストが空になる。ホスト側の状態機械を増やす価値はないので、
/// 「空きが出るまで初期化を待たせる」だけにする。待機中のホストは
/// ポスター／プレースホルダを出したまま —— これは既存の読み込み中
/// 表示そのもので、新しい視覚状態は増えない。
///
/// 順番待ちは **LIFO**。ユーザーがスクロールして今まさに近づいている
/// 動画（＝最後に mount されたもの）を先に通したい。実測でキュー長は
/// 個位数なので飢餓は問題にならない。
class VideoNativeSlotPool {
  VideoNativeSlotPool._();

  /// 同時初期化数の上限。
  ///
  /// モバイルは 2（表示中の 1 本 + スクロール先の先読み 1 本）。
  /// ハードウェアデコーダの本数自体が端末によっては 2〜3 本しかなく、
  /// 溢れるとソフトウェアデコードへ落ちて CPU とメモリを二重に食う。
  /// デスクトップは物理メモリに余裕があるので 4。
  static int get maxSlots => PlatformUtils.isDesktop ? 4 : 2;

  static int _inUse = 0;
  static final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// 診断用。
  static int get inUse => _inUse;
  static int get queueLength => _waiters.length;

  /// 枠を要求する。空いていれば即座に確保して null を返し、満杯なら
  /// 順番待ちの札を返す（呼び出し側はその future を await する）。
  static Completer<void>? acquireOrEnqueue() {
    if (_inUse < maxSlots) {
      _inUse++;
      return null;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter;
  }

  /// 順番待ち中に破棄されたホストの札を取り下げる。
  ///
  /// 取り下げに成功した場合は枠を一度も持っていないので **返却しない**
  /// （返すと発行数が超過し、上限が効かなくなる）。既に枠を譲られた後
  /// （札がキューから出た直後の競合）は取り下げに失敗するので、
  /// 呼び出し側の破棄済みチェック → 通常の返却経路が拾う。
  static void cancelWaiter(Completer<void> waiter) {
    if (_waiters.remove(waiter) && !waiter.isCompleted) {
      waiter.completeError(const VideoSlotCancelledException());
    }
  }

  /// 枠を返す。待ちがいれば `_inUse` を動かさずそのまま譲渡する。
  static void release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeLast(); // LIFO
      if (next.isCompleted) continue;
      next.complete();
      return;
    }
    if (_inUse > 0) _inUse--;
  }
}

/// 順番待ち中にホストが破棄されたことを示す内部例外。
class VideoSlotCancelledException implements Exception {
  const VideoSlotCancelledException();

  @override
  String toString() => 'VideoSlotCancelledException';
}

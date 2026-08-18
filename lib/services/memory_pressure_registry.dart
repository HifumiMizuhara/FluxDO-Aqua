import 'package:flutter/foundation.dart';

/// メモリ圧の段階。
///
/// アプリ側の自作キャッシュはこの 2 段階で解放量を切り替える。段階を
/// 分けるのは「圧が来た瞬間に全部捨てる」のが最悪手だから —— 端末が
/// すでに苦しい時に全キャッシュを捨てると、直後に再デコード・再レイアウトが
/// 一斉に走り、GPU キューと UI スレッドを同時に殴る。
enum MemoryPressureLevel {
  /// 予防的な回収。画面に出ていない派生データだけを落とし、
  /// 表示中のものは触らない（体感上の変化ゼロが条件）。
  soft,

  /// システムから実際に圧が来た / バックグラウンドへ落ちた。
  /// 再構築コストを払ってでも常駐量を下げる。
  hard,
}

/// メモリ圧を受けたときに 1 回の呼び出しで解放を行うコールバック。
typedef MemoryTrimCallback = void Function(MemoryPressureLevel level);

/// 自作キャッシュの解放口を 1 箇所に集約するレジストリ。
///
/// ## なぜ必要か
///
/// このアプリのメモリ常駐は `PaintingBinding.imageCache` だけではない。
/// 自絵カードの `ui.Image` 群、レイアウト済み `ui.Paragraph`、SVG 初期フレーム
/// スナップショット、パース済みノード木 —— どれもネイティブ／GPU メモリを
/// 持つのに、以前は `didHaveMemoryPressure` が知っている 2 つ
/// （RenderParseCache / FlattenCache）しか解放されていなかった。
/// キャッシュが増えるたびに解放漏れが起きる構造だったので、
/// 「登録しないと解放されない」ではなく「登録すれば必ず解放される」
/// 側に寄せる。
///
/// ## 使い方
///
/// キャッシュ側は自分で登録しない（static フィールドの遅延初期化に
/// 依存すると、一度も触られていないキャッシュが登録されないまま
/// 巨大化しうる）。起動時に `installMemoryPressureHandlers()`
/// （memory_pressure_bindings.dart）から一括登録する。
class MemoryPressureRegistry {
  MemoryPressureRegistry._();

  static final Map<String, MemoryTrimCallback> _handlers =
      <String, MemoryTrimCallback>{};

  /// [name] で登録（同名は上書き。ホットリスタート時の二重登録対策）。
  static void register(String name, MemoryTrimCallback onTrim) {
    _handlers[name] = onTrim;
  }

  static void unregister(String name) {
    _handlers.remove(name);
  }

  @visibleForTesting
  static void clearHandlers() => _handlers.clear();

  /// 登録済みハンドラ名（診断用）。
  static Iterable<String> get registered => _handlers.keys;

  /// 全ハンドラへ通知する。
  ///
  /// 1 つのハンドラが投げても残りは必ず走らせる —— 解放処理の途中で
  /// 止まると「一部だけ解放された」中途半端な状態になり、次の圧まで
  /// 誰も回収しない。
  static void dispatch(MemoryPressureLevel level) {
    for (final entry in _handlers.entries.toList(growable: false)) {
      try {
        entry.value(level);
      } catch (e, stack) {
        debugPrint('[MemoryPressure] ${entry.key} の解放に失敗: $e\n$stack');
      }
    }
  }
}

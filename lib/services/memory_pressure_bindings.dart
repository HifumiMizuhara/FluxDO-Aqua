import 'package:fluxdo_render/fluxdo_render.dart' show FlattenCache;

import '../widgets/content/animated_svg_view.dart';
import '../widgets/post/post_item/render_parse_cache.dart';
import '../widgets/topic/painted_topic_card.dart' show TopicCardImages;
import '../widgets/topic/topic_card_layout.dart';
import 'memory_pressure_registry.dart';

/// 自作キャッシュ群を [MemoryPressureRegistry] へ一括登録する。
/// `main()` から 1 回だけ呼ぶ。
///
/// ## なぜ各キャッシュ側で自己登録しないのか
///
/// Dart の static フィールド初期化子は遅延評価なので、「そのキャッシュの
/// コードが一度も触られていない」間は自己登録も走らない。触られていない
/// キャッシュは空なので実害はない……が、逆に「登録されているか」が
/// 実行経路に依存して読めなくなる。ここに全部並べておけば、
/// 解放対象の一覧がこのファイルだけで確定する。
///
/// ## ここに載っていないもの（意図的な除外）
///
/// - `ParagraphLayoutCache`：画面に出ている RenderObject が `ui.Paragraph` を
///   保持したまま paint するため、layout を経ずに dispose すると
///   使用済みハンドルを描くことになる。量も数 MB 規模で割に合わない。
/// - `ImageDecodeSpecMemo` / `MediaGeometryMemo` / `LazyImage` の
///   アスペクト比記憶：数十バイト × 件数と極小な一方、捨てると
///   スクロール位置の補正跳ねが再発する。回収する理由がない。
/// - `BlobImageCache`：ディスク層。メモリ圧とは無関係。
void installMemoryPressureHandlers() {
  // 帖子 cooked のパース産物（ノード木）。純データなので全捨て安全。
  MemoryPressureRegistry.register('RenderParseCache', (level) {
    if (level == MemoryPressureLevel.soft) return;
    RenderParseCache.clear();
  });

  // インライン span の flatten 産物。参照カウント設計なので、使用中の
  // エントリは dead マークのみで、最後の release まで生き残る。
  MemoryPressureRegistry.register('FlattenCache', (level) {
    if (level == MemoryPressureLevel.soft) return;
    FlattenCache.evictAll();
  });

  // 話題カードのレイアウトスナップショット（`ui.Paragraph` 群を含む）。
  // 実インスタンスはウィジェット側の参照で生き続けるため、マップを
  // 空にしても表示中のカードは壊れない（設定変更時に既に同じことをしている）。
  MemoryPressureRegistry.register('TopicCardLayout', (level) {
    if (level == MemoryPressureLevel.soft) return;
    TopicCardLayout.evictAll();
  });

  // 自絵カードのアバター / emoji テクスチャ（ImageCache の外）。
  MemoryPressureRegistry.register('TopicCardImages', TopicCardImages.trim);

  // アニメーション SVG の初期フレームスナップショット（フル解像度）。
  MemoryPressureRegistry.register(
    'AnimatedSvgSnapshots',
    AnimatedSvgView.trimSnapshotCache,
  );
}

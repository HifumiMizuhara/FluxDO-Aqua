import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import '../../../constants.dart';

/// Aqua ラボ「より良い CF 突破」の実行時ポリシー。
///
/// ## なぜトグルなのか
///
/// ここで変えるのは「どのネットワークスタックで主ドメインを叩くか」と
/// 「CF 通過をどう判定するか」という、失敗したときに**アプリが一切通信
/// できなくなる**種類の挙動。既定経路を残したまま切り替えられる形にして、
/// 問題が出たユーザーがオフに戻せるようにする。
///
/// ## 何を変えるか
///
/// 1. **指紋の一致**（[shouldAvoidRhttpFor]）
///    `cf_clearance` は Cloudflare 側でクライアントの身元 —— 出口 IP・
///    User-Agent・TLS/HTTP2 指紋 —— に紐づく。この app は WebView で
///    通行証を鋳造して Dio で使う構造なので、身元が揃っていないと
///    「検証は成功したのに Dio は 403」になる。UA は既に統一済み
///    (constants.dart)、出口 IP も Windows は findProxy で WebView2 と
///    揃えてある。残る不一致は TLS 指紋だけで、既定の優先度は
///    rhttp(rustls) が最上位 —— Chromium とは似ても似つかない指紋。
///    実測の裏付けはリポジトリ内にある: discourse/_login.dart の
///    「dio GET /session/csrf 实测被 CF 当 bot 403 (TLS 指纹)」。
///    有効時は保護オリジン宛だけ rhttp を外し、Chromium/URLSession 系の
///    native アダプタへ寄せる。gateway/proxy モードの判定には触らない
///    （通信の成立そのものは指紋より優先する）。
///
/// 2. **通過判定の単純化**（[cancelPostChallengeNavigation]）
///    `/challenge` は CF を通過すると源站 404 を返す。既定経路はその 404 を
///    実際にロードさせ、二重マスク（document-start の JS マスク + Flutter
///    オーバーレイ）+ MutationObserver + reveal ウォッチャで隠している。
///    有効時は通過後のナビゲーション自体を CANCEL するので、404 は一度も
///    ロードされず、マスク機構がまるごと不要になる。
///
/// 3. **経路切替 > 全体停止**（[autoSwitchTransportOnIneffectiveClearance]）
///    「通行証は取れたが Dio が通らない」は身元の問題であって CF 検証の
///    問題ではない。既定経路はここで 60 秒の熔断に入りアプリ全体の CF 復旧を
///    止めるが、有効時は確認ダイアログなしで WebView 転送へ切り替える。
class CfBypassPolicy {
  CfBypassPolicy._();

  static const String prefKey = 'pref_aqua_better_cf_bypass';

  static final ValueNotifier<bool> notifier = ValueNotifier<bool>(false);

  static bool get enabled => notifier.value;

  /// [PreferencesNotifier] から同期される（起動時の読み込みと設定変更時）。
  static void configure(bool value) {
    if (notifier.value == value) return;
    notifier.value = value;
  }

  @visibleForTesting
  static void resetForTest() => notifier.value = false;

  /// Cloudflare が保護しているオリジンか。
  ///
  /// 判定は主ドメイン一致のみ。CDN サブドメインは CF の challenge 対象外で、
  /// 画像取得の指紋を気にする理由もない。message-bus のロングポーリングは
  /// 主ドメイン宛なので**含める** —— WebView 転送では除外される経路だが、
  /// ここで選ぶのは native アダプタなのでロングポーリングでも問題ない
  /// (configureStableNativeAdapter が既に同じ選択をしている)。
  static bool isProtectedOrigin(Uri uri) {
    return uri.host == _baseHost;
  }

  static final String _baseHost = Uri.parse(AppConstants.baseUrl).host;

  /// この要求で rhttp を避けるべきか（= 指紋を Chromium 系へ寄せる）。
  static bool shouldAvoidRhttpFor(Uri uri) {
    if (!enabled) return false;
    return isProtectedOrigin(uri);
  }

  /// 盾を解いた後の源站へのナビゲーションを CANCEL するか。
  static bool get cancelPostChallengeNavigation => enabled;

  /// 鋳造した clearance が native 経路で通らなかったとき、確認ダイアログを
  /// 出さずに WebView 転送へ切り替えるか。
  ///
  /// Windows では特に効く: native アダプタは Schannel で、Chromium の指紋には
  /// 原理的に一致しない。ここでの切り替えは「環境ではなく経路の問題」と
  /// 分かっている場合の最短復旧路。
  static bool get autoSwitchTransportOnIneffectiveClearance => enabled;

  /// native 経路の指紋が Chromium と一致しうるプラットフォームか（診断表示用）。
  ///
  /// - Android: native = cronet = Chromium 本体。一致する。
  /// - iOS/macOS: native = URLSession。WebKit と同じ Apple の TLS スタックで、
  ///   完全同一ではないが rustls よりはるかに近い。
  /// - Windows/Linux: native = dart:io の HttpClient (Schannel/OpenSSL)。
  ///   一致しない —— この 2 つでは 3 番目の経路切替が主な救済手段になる。
  static bool get nativeTransportMatchesBrowser =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
}

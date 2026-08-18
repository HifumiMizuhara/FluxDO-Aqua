import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cf/cf_bypass_policy.dart';

void main() {
  tearDown(CfBypassPolicy.resetForTest);

  group('既定（オフ）', () {
    test('どのオリジンでも rhttp を避けない', () {
      expect(
        CfBypassPolicy.shouldAvoidRhttpFor(Uri.parse('https://linux.do/t/1')),
        isFalse,
      );
    });

    test('通過後のナビゲーションを止めない', () {
      expect(CfBypassPolicy.cancelPostChallengeNavigation, isFalse);
    });

    test('経路の自動切替をしない', () {
      expect(
        CfBypassPolicy.autoSwitchTransportOnIneffectiveClearance,
        isFalse,
      );
    });
  });

  group('有効時（native 指紋が Chromium 系に寄るプラットフォーム）', () {
    setUp(() {
      CfBypassPolicy.configure(true);
      CfBypassPolicy.debugNativeTransportMatchesBrowser = true;
    });

    test('主ドメイン宛は rhttp を避ける', () {
      expect(
        CfBypassPolicy.shouldAvoidRhttpFor(
          Uri.parse('https://linux.do/latest.json'),
        ),
        isTrue,
      );
    });

    test('message-bus のロングポーリングも主ドメインなので対象に含む', () {
      // native アダプタはロングポーリングでも問題ない
      // (configureStableNativeAdapter が既に同じ選択をしている)。
      expect(
        CfBypassPolicy.shouldAvoidRhttpFor(
          Uri.parse('https://linux.do/message-bus/abc/poll'),
        ),
        isTrue,
      );
    });

    test('CDN サブドメインは対象外', () {
      expect(
        CfBypassPolicy.shouldAvoidRhttpFor(
          Uri.parse('https://cdn.linux.do/uploads/a.png'),
        ),
        isFalse,
      );
    });

    test('外部ホストは対象外', () {
      expect(
        CfBypassPolicy.shouldAvoidRhttpFor(
          Uri.parse('https://api.openai.com/v1/chat'),
        ),
        isFalse,
      );
    });

    test('通過後のナビゲーションを止める', () {
      expect(CfBypassPolicy.cancelPostChallengeNavigation, isTrue);
    });

    test('経路を自動で切り替える', () {
      expect(CfBypassPolicy.autoSwitchTransportOnIneffectiveClearance, isTrue);
    });
  });

  group('有効時（Windows/Linux＝native も Chromium 指紋に一致しない）', () {
    setUp(() {
      CfBypassPolicy.configure(true);
      CfBypassPolicy.debugNativeTransportMatchesBrowser = false;
    });

    test('rhttp は外さない（外しても指紋の利得が無く HTTP/2 と ECH を失うだけ）', () {
      expect(
        CfBypassPolicy.shouldAvoidRhttpFor(
          Uri.parse('https://linux.do/latest.json'),
        ),
        isFalse,
      );
    });

    test('通過判定の単純化と経路切替はそのまま効く', () {
      expect(CfBypassPolicy.cancelPostChallengeNavigation, isTrue);
      expect(CfBypassPolicy.autoSwitchTransportOnIneffectiveClearance, isTrue);
    });
  });

  test('configure は notifier を通じて伝播する', () {
    var notified = 0;
    void listener() => notified++;
    CfBypassPolicy.notifier.addListener(listener);
    addTearDown(() => CfBypassPolicy.notifier.removeListener(listener));

    CfBypassPolicy.configure(true);
    CfBypassPolicy.configure(true); // 同値は通知しない
    CfBypassPolicy.configure(false);

    expect(notified, 2);
  });
}

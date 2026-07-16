import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';

void main() {
  final service = CfChallengeService();

  setUp(service.resetRecoveryState);
  tearDown(service.resetRecoveryState);

  group('CfChallengeService 静默恢复协调', () {
    test('同一时刻只有一个静默恢复 owner', () {
      expect(service.tryBeginSilentRecovery(), isTrue);
      expect(service.isSilentRecoveryInProgress, isTrue);
      expect(service.tryBeginSilentRecovery(), isFalse);
    });

    test('等待者共享 owner 的恢复成功结果', () async {
      expect(service.tryBeginSilentRecovery(), isTrue);
      final firstWaiter = service.waitForSilentRecovery();
      final secondWaiter = service.waitForSilentRecovery();

      expect(service.finishSilentRecovery(nativeRecovered: true), isTrue);

      expect(await firstWaiter, isTrue);
      expect(await secondWaiter, isTrue);
      expect(service.isSilentRecoveryInProgress, isFalse);
      expect(service.isNativeNetworkDegraded, isFalse);
      expect(service.hasPendingForegroundCompatibility, isFalse);
    });

    test('恢复失败后停止新的静默恢复并挂起前台兼容提示', () async {
      expect(service.tryBeginSilentRecovery(), isTrue);
      final waiter = service.waitForSilentRecovery();

      expect(service.finishSilentRecovery(nativeRecovered: false), isTrue);

      expect(await waiter, isFalse);
      expect(service.isNativeNetworkDegraded, isTrue);
      expect(service.hasPendingForegroundCompatibility, isTrue);
      expect(service.tryBeginSilentRecovery(), isFalse);
      expect(await service.waitForSilentRecovery(), isFalse);
    });

    test('待前台兼容提示只能被消费一次', () {
      service.markNativeNetworkDegraded();

      expect(service.takePendingForegroundCompatibility(), isTrue);
      expect(service.takePendingForegroundCompatibility(), isFalse);
      expect(service.isNativeNetworkDegraded, isTrue);
    });

    test('原生链路恢复后清除 degraded 与待提示状态', () {
      service.markNativeNetworkDegraded();

      service.markNativeNetworkRecovered();

      expect(service.isNativeNetworkDegraded, isFalse);
      expect(service.hasPendingForegroundCompatibility, isFalse);
      expect(service.tryBeginSilentRecovery(), isTrue);
    });

    test('没有 owner 时结束恢复不会改变状态', () {
      expect(service.finishSilentRecovery(nativeRecovered: false), isFalse);
      expect(service.isNativeNetworkDegraded, isFalse);
      expect(service.hasPendingForegroundCompatibility, isFalse);
    });

    test('重置会释放等待者并清空会话恢复状态', () async {
      expect(service.tryBeginSilentRecovery(), isTrue);
      final waiter = service.waitForSilentRecovery();
      service.markNativeNetworkDegraded();

      service.resetRecoveryState();

      expect(await waiter, isFalse);
      expect(service.isSilentRecoveryInProgress, isFalse);
      expect(service.isNativeNetworkDegraded, isFalse);
      expect(service.hasPendingForegroundCompatibility, isFalse);
    });

    test('前台兼容首次请求只有一个 activation owner', () async {
      expect(service.tryBeginForegroundFallbackActivation(), isTrue);
      expect(service.isForegroundFallbackActivationInProgress, isTrue);
      expect(service.tryBeginForegroundFallbackActivation(), isFalse);

      final waiter = service.waitForForegroundFallbackActivation();
      service.finishForegroundFallbackActivation(success: true);

      expect(await waiter, isTrue);
      expect(service.isForegroundFallbackActivationInProgress, isFalse);
    });

    test('前台兼容首次请求失败会通知并释放等待者', () async {
      expect(service.tryBeginForegroundFallbackActivation(), isTrue);
      final waiter = service.waitForForegroundFallbackActivation();

      service.finishForegroundFallbackActivation(success: false);

      expect(await waiter, isFalse);
      expect(service.isForegroundFallbackActivationInProgress, isFalse);
    });
  });
}

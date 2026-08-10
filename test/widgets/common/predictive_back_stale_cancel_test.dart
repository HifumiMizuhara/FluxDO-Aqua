import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_cupertino_transitions.dart';

/// 差异点 9:原生 MainActivity.onStop 每次锁屏都广播 cancelBackGesture
/// (2026-06 修 UI 卡死加的)。binding 的认领者列表 commit/cancel 后
/// 不清空,这条广播会打到上一次手势的陈旧认领者上;若认领者不按
/// phase 门控,handleCancelBackGesture 无配对 start → userGesture
/// 计数下溢 → 预测返回全局静默失效。
/// 复现真机序列:正常快划返回(commit)→ 收尾动画播完 → 锁屏
/// (onStop 广播 cancel)→ 回前台 → 再划,必须仍被认领。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> send(String method, [Map<String, Object?>? args]) {
    return binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
  }

  testWidgets(
    'stale cancelBackGesture from native onStop does not corrupt gesture count',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android:
                    PredictiveBackCupertinoPageTransitionsBuilder(),
              },
            ),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('next page')),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      // 第一轮:手势取消结尾 —— 认领者(B 的 detector)与 route 都
      // 还活着,这才是陈旧 cancel 有害的前提(commit 结尾时认领者随
      // 页面 dispose,route.navigator 已断开,再打 cancel 是 no-op)
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await send('startBackGesture', {
        'touchOffset': <double>[0, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      await send('updateBackGestureProgress', {
        'touchOffset': <double>[80, 300],
        'progress': 0.3,
        'swipeEdge': 0,
      });
      await tester.pump();
      await send('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('next page'), findsOneWidget);
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);

      // 锁屏:原生 onStop 无条件广播 cancelBackGesture —— 打到上一轮
      // 手势的陈旧认领者(binding 列表未清)
      await send('cancelBackGesture');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();

      // 计数不得为负:回前台再划,必须仍能认领并正常渲染
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(navigatorKey.currentState!.userGestureInProgress, isFalse,
          reason: '陈旧 cancel 不得把计数打成负(负值恒 false 但会吞后续 start 的 +1)');

      // 页面 B 仍在(第一轮以 cancel 结尾),直接再划
      await send('startBackGesture', {
        'touchOffset': <double>[0, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      expect(navigatorKey.currentState!.userGestureInProgress, isTrue,
          reason: '锁屏后的新手势必须被认领且计数为正(渲染依赖此值)');
      await send('commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('next page'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'root route claims gesture while previous pop is still animating',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android:
                    PredictiveBackCupertinoPageTransitionsBuilder(),
              },
            ),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('page B')),
                  ),
                ),
                child: const Text('root page'),
              ),
            ),
          ),
        ),
      );

      // 栈:root/B。第一划正常 commit,B 退场动画进行中
      await tester.tap(find.text('root page'));
      await tester.pumpAndSettle();
      await send('startBackGesture', {
        'touchOffset': <double>[0, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      await send('commitBackGesture');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      // 第二划:current=根路由(用户截图场景)。必须被认领
      // (不认领 = 引擎/系统接管出黑边;认领后 commit 吞掉,不关 app)
      bool claimed = false;
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('startBackGesture', {
            'touchOffset': <double>[0, 300],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        ),
        (ByteData? reply) {
          if (reply != null) {
            claimed =
                const StandardMethodCodec().decodeEnvelope(reply) == true;
          }
        },
      );
      await tester.pump();
      expect(claimed, isTrue,
          reason: '根路由压着退场中的上一划时必须认领,否则黑边');

      await send('commitBackGesture');
      await tester.pumpAndSettle();
      // 根路由吞掉 commit:app 还活着,回到 root
      expect(find.text('root page'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}

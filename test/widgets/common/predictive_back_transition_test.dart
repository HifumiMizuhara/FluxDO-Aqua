import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_cupertino_transitions.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'predictive back keeps the previous route stationary',
    (tester) async {
      final previousPageKey = GlobalKey();

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
            body: SizedBox.expand(
              key: previousPageKey,
              child: Builder(
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
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final previousPage = find.byKey(previousPageKey, skipOffstage: false);
      expect(tester.getTopLeft(previousPage).dx, lessThan(0));

      final gestureMessage = const StandardMethodCodec().encodeMethodCall(
        MethodCall('startBackGesture', {
          'touchOffset': <double>[0, 300],
          'progress': 0.0,
          'swipeEdge': 0,
        }),
      );
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        gestureMessage,
        (_) {},
      );
      await tester.pump();

      expect(tester.getTopLeft(previousPage).dx, 0);

      final cancelMessage = const StandardMethodCodec().encodeMethodCall(
        MethodCall('cancelBackGesture'),
      );
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        cancelMessage,
        (_) {},
      );
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(previousPage).dx, lessThan(0));
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'commit still plays the exit animation on the popped route',
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
                    builder: (_) => const Scaffold(body: Text('next page')),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      Future<void> sendGesture(String method, [Map<String, Object?>? args]) {
        return binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) {},
        );
      }

      await sendGesture('startBackGesture', {
        'touchOffset': <double>[0, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await tester.pump();
      await sendGesture('updateBackGestureProgress', {
        'touchOffset': <double>[100, 300],
        'progress': 0.35,
        'swipeEdge': 0,
      });
      await tester.pump();
      await sendGesture('commitBackGesture');
      await tester.pump();

      // commit 的 navigator.pop() 已把被弹路由翻成非 current;收尾动画
      // 期间 shared-element 转场必须仍在树上驱动缩小页滑出,不能因
      // isCurrent 变化被吞成静态贴图(回归:直接返回 child 时,页面
      // 会瞬间以全尺寸贴住,动画消失)。
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.runtimeType.toString() ==
              '_PredictiveBackSharedElementPageTransition',
        ),
        findsWidgets,
      );

      await tester.pumpAndSettle();
      expect(find.text('next page'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'rejected button event does not poison a later app back gesture',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      late PageRoute<void> route;

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {TargetPlatform.android: ZoomPageTransitionsBuilder()},
            ),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  route = PageRouteBuilder<void>(
                    pageBuilder: (_, _, _) => const Text('page'),
                    transitionsBuilder:
                        (context, animation, secondaryAnimation, child) {
                          return buildPredictiveBackPageTransitions(
                            context,
                            animation,
                            secondaryAnimation,
                            child,
                            fallbackBuilder: (_, animation, _, child) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                          );
                        },
                  );
                  Navigator.of(context).push(route);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final buttonMessage = const StandardMethodCodec().encodeMethodCall(
        MethodCall('startBackGesture', {
          'touchOffset': null,
          'progress': 0.0,
          'swipeEdge': 0,
        }),
      );
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        buttonMessage,
        (_) {},
      );
      await tester.pump();

      route.handleStartBackGesture(progress: 0.8);
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.runtimeType.toString() ==
              '_PredictiveBackSharedElementPageTransition',
        ),
        findsNothing,
      );

      route.handleCancelBackGesture();
      await tester.pumpAndSettle();
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}

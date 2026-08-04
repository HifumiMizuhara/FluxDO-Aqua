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

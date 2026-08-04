import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/predictive_back_cupertino_transitions.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'disabled predictive back keeps the regular Hero pop transition',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      var heroFlights = 0;

      Widget buildHero(double size) {
        return Hero(
          tag: 'image',
          flightShuttleBuilder: (_, _, _, _, _) {
            heroFlights += 1;
            return ColoredBox(
              color: Colors.red,
              child: SizedBox.square(dimension: size),
            );
          },
          child: ColoredBox(
            color: Colors.red,
            child: SizedBox.square(dimension: size),
          ),
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  buildHero(48),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        PageRouteBuilder<void>(
                          opaque: false,
                          pageBuilder: (_, _, _) => Scaffold(
                            backgroundColor: Colors.black,
                            body: Center(child: buildHero(240)),
                          ),
                          transitionsBuilder:
                              (context, animation, secondaryAnimation, child) {
                                return buildPredictiveBackPageTransitions(
                                  context,
                                  animation,
                                  secondaryAnimation,
                                  child,
                                  enablePredictiveBack: false,
                                  fallbackBuilder: (_, animation, _, child) =>
                                      FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      ),
                                );
                              },
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      heroFlights = 0;

      final startMessage = const StandardMethodCodec().encodeMethodCall(
        MethodCall('startBackGesture', {
          'touchOffset': <double>[5, 300],
          'progress': 0.0,
          'swipeEdge': 0,
        }),
      );
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        startMessage,
        (_) {},
      );
      await tester.pump();

      expect(navigatorKey.currentState!.userGestureInProgress, isFalse);

      await binding.handlePopRoute();
      await tester.pump();
      await tester.pump();

      expect(heroFlights, 1);
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}

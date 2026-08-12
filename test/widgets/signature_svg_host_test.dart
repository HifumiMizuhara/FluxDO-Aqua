import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/svg_utils.dart';
import 'package:fluxdo/widgets/content/signature_svg_host.dart';
import 'package:fluxdo/widgets/content/svg_web_view.dart';
import 'package:visibility_detector/visibility_detector.dart';

void main() {
  const source = '<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="5"/></svg>';

  test('スロットの追加・更新・削除と同一Blobソース参照数を追跡する', () {
    final registry = SignatureSvgSlotRegistry();

    registry.upsert(
      id: 'a',
      source: source,
      rect: const Rect.fromLTWH(1, 2, 10, 11),
      visible: true,
    );
    registry.upsert(
      id: 'b',
      source: source,
      rect: const Rect.fromLTWH(3, 4, 12, 13),
      visible: true,
    );
    expect(registry.sourceReferenceCount(source), 2);

    const replacement = '<svg viewBox="0 0 20 20" />';
    registry.upsert(
      id: 'b',
      source: replacement,
      rect: const Rect.fromLTWH(3, 4, 12, 13),
      visible: true,
    );
    expect(registry.sourceReferenceCount(source), 1);
    expect(registry.sourceReferenceCount(replacement), 1);

    final initial = registry.buildPayload();
    expect(initial.upserts, hasLength(2));
    registry.commit(initial);

    registry.updateGeometry(
      id: 'a',
      rect: const Rect.fromLTWH(7, 8, 10, 11),
      visible: false,
    );
    final geometryOnly = registry.buildPayload();
    expect(geometryOnly.upserts, isEmpty);
    expect(geometryOnly.rects, hasLength(1));
    expect(geometryOnly.rects.single.containsKey('source'), isFalse);

    registry.remove('a');
    expect(registry.sourceReferenceCount(source), 0);
    registry.remove('b');
    expect(registry.sourceReferenceCount(replacement), 0);
    expect(registry.buildPayload().removed, containsAll(<String>['a', 'b']));
  });

  test('同期中の更新は古いpayloadをcommitせず最新矩形へ集約する', () {
    final registry = SignatureSvgSlotRegistry();
    registry.upsert(
      id: 'slot',
      source: source,
      rect: const Rect.fromLTWH(0, 0, 10, 10),
      visible: true,
    );
    final inFlight = registry.buildPayload();

    registry.updateGeometry(
      id: 'slot',
      rect: const Rect.fromLTWH(50, 60, 10, 10),
      visible: true,
    );
    registry.commit(inFlight);

    final latest = registry.buildPayload();
    expect(latest.upserts, hasLength(1));
    expect(latest.upserts.single['x'], 50);
    expect(latest.upserts.single['y'], 60);
  });

  test('同期中にスロットが外れても完了後のpayloadでDOM削除を送る', () {
    final registry = SignatureSvgSlotRegistry();
    registry.upsert(
      id: 'removed',
      source: source,
      rect: const Rect.fromLTWH(0, 0, 10, 10),
      visible: true,
    );
    final inFlight = registry.buildPayload();
    registry.remove('removed');
    registry.commit(inFlight);

    expect(registry.buildPayload().removed, contains('removed'));
  });

  test('ホスト文書はCSPとBlob画像経路を使い、SVGをHTMLへ挿入しない', () {
    expect(signatureSvgHostDocument, contains("default-src 'none'"));
    expect(signatureSvgHostDocument, contains('img-src blob: data:'));
    expect(signatureSvgHostDocument, contains('Blob'));
    expect(signatureSvgHostDocument, contains('createObjectURL'));
    expect(signatureSvgHostDocument, isNot(contains('innerHTML')));
    expect(signatureSvgHostDocument, isNot(contains(source)));
  });

  test('ホスト状態はloading/ready/failed/inactiveを遷移し3回失敗でfallbackする', () {
    final controller = SignatureSvgHostController();
    addTearDown(controller.dispose);

    expect(controller.status, SignatureSvgHostStatus.inactive);
    controller.beginSession();
    expect(controller.status, SignatureSvgHostStatus.loading);
    controller.markReady();
    expect(controller.status, SignatureSvgHostStatus.ready);
    expect(controller.recordSyncFailure(), isFalse);
    expect(controller.recordSyncFailure(), isFalse);
    expect(controller.recordSyncFailure(), isTrue);
    expect(controller.status, SignatureSvgHostStatus.failed);

    controller.deactivateSession();
    expect(controller.status, SignatureSvgHostStatus.inactive);
    controller.beginSession();
    expect(controller.status, SignatureSvgHostStatus.loading);
  });

  test('スクロール終了後も最終座標同期までFlutterスナップショットを維持する', () {
    final controller = SignatureSvgHostController();
    addTearDown(controller.dispose);

    expect(controller.isScrolling, isFalse);
    expect(controller.showFlutterSnapshot, isFalse);

    controller.beginScroll();
    expect(controller.isScrolling, isTrue);
    expect(controller.showFlutterSnapshot, isTrue);

    controller.endScroll();
    expect(controller.isScrolling, isFalse);
    expect(controller.showFlutterSnapshot, isTrue);

    controller.markViewportSynchronized();
    expect(controller.showFlutterSnapshot, isFalse);
  });

  test('新しいスクロール中は古い同期完了でWebViewへ戻さない', () {
    final controller = SignatureSvgHostController();
    addTearDown(controller.dispose);

    controller.beginScroll();
    controller.endScroll();
    controller.beginScroll();
    controller.markViewportSynchronized();

    expect(controller.isScrolling, isTrue);
    expect(controller.showFlutterSnapshot, isTrue);
  });

  testWidgets('SvgWebViewは従来どおりのアスペクト比のFlutter枠を確保する', (tester) async {
    final oldVisibilityInterval =
        VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    addTearDown(() {
      VisibilityDetectorController.instance.updateInterval =
          oldVisibilityInterval;
    });
    final controller = SignatureSvgHostController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SignatureSvgHostScope(
          controller: controller,
          child: const SizedBox(
            width: 240,
            child: SvgWebView(
              svgSource: '''<svg xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 100 50">
                <rect width="100" height="50" fill="red" />
              </svg>''',
              width: 200,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final frame = find.byWidgetPredicate(
      (widget) =>
          widget is SizedBox && widget.width == 200 && widget.height == 100,
    );
    expect(frame, findsOneWidget);
    const snapshotKey = ValueKey<String>('SvgWebView.scrollSnapshot');
    expect(find.byKey(snapshotKey), findsNothing);

    controller.beginScroll();
    await tester.pump();
    expect(find.byKey(snapshotKey), findsOneWidget);

    controller.endScroll();
    await tester.pump();
    expect(find.byKey(snapshotKey), findsOneWidget);

    controller.markViewportSynchronized();
    await tester.pump();
    expect(find.byKey(snapshotKey), findsNothing);
  });

  test('secure WebView用サニタイズはactive contentと外部参照を落としdata URLを残す', () {
    const svg = '''<svg>
      <script>alert(1)</script>
      <image href="https://example.invalid/x.png" />
      <image href="data:image/png;base64,AA==" />
      <use href="#local" />
      <style>.x { background: url(https://example.invalid/x.png); }</style>
    </svg>''';

    final safe = SvgUtils.sanitizeForSecureWebView(svg);
    expect(safe, isNot(contains('<script>')));
    expect(safe, isNot(contains('https://example.invalid')));
    expect(safe, contains('data:image/png'));
    expect(safe, contains('href="#local"'));
  });
}

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/crash_mitigation_service.dart';

void main() {
  test('画像デコード上限は長辺と総ピクセル数を同時に守る', () {
    final clamped = CrashMitigationService.clampTargetSize(
      8000,
      6000,
      const ui.TargetImageSize(),
    );

    expect(clamped.width, isNotNull);
    expect(clamped.height, isNotNull);
    expect(
      clamped.width! * clamped.height!,
      lessThanOrEqualTo(CrashMitigationService.maxDecodedPixels),
    );
    final longEdge = clamped.width! > clamped.height!
        ? clamped.width!
        : clamped.height!;
    expect(
      longEdge,
      lessThanOrEqualTo(CrashMitigationService.maxDecodedDimension),
    );
    expect(clamped.width! / clamped.height!, closeTo(4 / 3, 0.01));
  });

  test('上限内の画像は要求サイズを変更しない', () {
    const requested = ui.TargetImageSize(width: 1200, height: 800);

    expect(
      CrashMitigationService.clampTargetSize(1200, 800, requested),
      same(requested),
    );
  });
}

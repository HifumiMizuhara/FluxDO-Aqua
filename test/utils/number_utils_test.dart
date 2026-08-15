import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/number_utils.dart';

void main() {
  group('NumberUtils.formatCount', () {
    test('1000未満はそのまま表示する', () {
      expect(NumberUtils.formatCount(999), '999');
    });

    test('1000以上はk単位で表示する', () {
      expect(NumberUtils.formatCount(1000), '1.0k');
      expect(NumberUtils.formatCount(10000), '10.0k');
      expect(NumberUtils.formatCount(100000), '100.0k');
    });
  });

  group('NumberUtils.formatSignedInt', () {
    test('正数会补充加号', () {
      expect(NumberUtils.formatSignedInt(12), '+12');
    });

    test('负数只保留原始负号', () {
      expect(NumberUtils.formatSignedInt(-12), '-12');
    });

    test('零不补充符号', () {
      expect(NumberUtils.formatSignedInt(0), '0');
    });
  });
}

// Heading 节点的 golden 测试。
//
// 跑法:
//   fvm flutter test test/heading_golden_test.dart                  # 比对
//   fvm flutter test test/heading_golden_test.dart --update-goldens # 刷新基线

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/_meta/fixture_loader.dart' as loader;
import 'golden_framework/golden_helper.dart';

void main() {
  group('heading 节点 golden', () {
    setUpAll(setUpGoldenTest);
    for (final fixture in loader.loadByNodeType('heading')) {
      testGolden(fixture);
    }
  });
}

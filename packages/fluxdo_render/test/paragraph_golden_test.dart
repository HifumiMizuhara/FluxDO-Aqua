// Paragraph 节点的 golden 测试。
//
// 跑法:
//   fvm flutter test test/paragraph_golden_test.dart                  # 比对
//   fvm flutter test test/paragraph_golden_test.dart --update-goldens # 刷新基线
//
// 跨平台 guard:只在 macOS lock(详见 golden_framework/README.md)。

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/_meta/fixture_loader.dart' as loader;
import 'golden_framework/golden_helper.dart';

void main() {
  group('paragraph 节点 golden', () {
    setUpAll(setUpGoldenTest);
    for (final fixture in loader.loadByNodeType('paragraph')) {
      testGolden(fixture);
    }
  });
}

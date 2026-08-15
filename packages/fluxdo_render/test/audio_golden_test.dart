// Audio 节点 golden(占位态:无 builder,截子包 _AudioPlaceholderCard)。
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/_meta/fixture_loader.dart' as loader;
import 'golden_framework/golden_helper.dart';

void main() {
  group('audio 节点 golden', () {
    setUpAll(setUpGoldenTest);
    for (final fixture in loader.loadByNodeType('audio')) {
      testGolden(fixture);
    }
  });
}

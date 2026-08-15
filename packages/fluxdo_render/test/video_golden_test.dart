// Video 节点 golden(占位态:无 builder,截子包 _VideoPlaceholderCard)。
//   fvm flutter test test/video_golden_test.dart --update-goldens
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/_meta/fixture_loader.dart' as loader;
import 'golden_framework/golden_helper.dart';

void main() {
  group('video 节点 golden', () {
    setUpAll(setUpGoldenTest);
    for (final fixture in loader.loadByNodeType('video')) {
      testGolden(fixture);
    }
  });
}

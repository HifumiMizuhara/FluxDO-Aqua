// 框架自检 golden test:用现有 5 个示例 fixture 跑一遍 golden,
// 验证 setUp + render + matchesGoldenFile 链路通畅。
//
// 注意:阶段 0 时 FluxdoRender 只是 placeholder,渲染出的 golden 不含
// 真实节点视觉。每实现一个节点会替换/扩充对应 golden 文件。
//
// 首次运行需要生成 golden:
//   fvm flutter test test/golden_framework_smoke_test.dart --update-goldens

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/_meta/fixture_loader.dart' as loader;
import 'golden_framework/golden_helper.dart';

void main() {
  group('golden 框架自检', () {
    setUpAll(setUpGoldenTest);

    // 拿所有现有 fixture 跑一遍 golden(目前只有 5 个示例)
    for (final fixture in loader.loadAll()) {
      testGolden(fixture);
    }
  });
}

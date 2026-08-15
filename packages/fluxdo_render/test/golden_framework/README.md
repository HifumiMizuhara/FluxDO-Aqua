# Golden 测试框架

## 用途

每个节点 PR 必须有 golden 测试,保证未来代码改动不影响渲染像素输出。
框架自动跑 `flutter_test` 的 `matchesGoldenFile`,首次需要 lock 基线
(`--update-goldens`),后续 PR 跑时只对比不更新。

## 文件位置

```
test/
├── golden_framework/
│   └── golden_helper.dart        ← setUpGoldenTest() + testGolden() API
├── golden/                       ← 基线 png(进仓)
│   ├── paragraph/
│   ├── heading/
│   └── ...
├── failures/                     ← golden 失败时本地生成对比图(已 gitignore)
└── <node>_golden_test.dart      ← 各节点的 golden 测试
```

## 单节点 golden 测试模板

```dart
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
```

## 常用命令

**生成 / 刷新基线**(第一次或 fixture 内容变化时):

```sh
fvm flutter test test/<node>_golden_test.dart --update-goldens
```

**跑全部 golden(CI 默认行为)**:

```sh
fvm flutter test
```

**只跑某节点的 golden**:

```sh
fvm flutter test test/paragraph_golden_test.dart
```

## 跨平台 golden 策略

**只在 macOS 上 lock golden**(`golden_helper.dart` 用 `Platform.isMacOS`
guard,其他平台 skip)。理由:不同 OS 字体渲染差异(尤其 CJK)在
像素层面无法 100% 对齐,golden 是检测"代码改动",不是"平台差异"。

CI 也只在 macOS runner 上跑 golden 比对。Linux/Windows CI 跑 unit
test + analyze 即可。

## 图片占位

framework 自动用 `HttpOverrides` 拦截所有 `HttpClient` 请求,返回
固定的 1x1 透明 png。这样:
- 不联网,golden 跑测稳定
- 不依赖 cached_network_image 等额外 setup

如果节点对图片有真实尺寸/显示要求,需要 mock `ImageProvider`(不是
HTTP),具体方案在阶段 4(图片体系)做。

## 失败排查

golden 失败时,framework 会在 `test/failures/` 生成:

```
<fixture_name>_masterImage.png    ← 基线
<fixture_name>_testImage.png      ← 当前渲染
<fixture_name>_isolatedDiff.png   ← 像素差异区高亮
```

打开图片对比,确认是真的回归还是预期改动。预期改动 → 重新跑
`--update-goldens` 刷新基线。

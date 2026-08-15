// 验证 fixture 库结构正确,所有 .html/.yaml 配对存在,sha 一致。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures/_meta/fixture_loader.dart' as loader;
import 'fixtures/_meta/validator.dart';

void main() {
  group('fixture library', () {
    test('每个 .html 都有配对的 .yaml', () {
      final fixtures = loader.loadAll();
      expect(fixtures, isNotEmpty, reason: '至少要有 1 个 fixture');

      for (final f in fixtures) {
        final yamlPath = f.path.replaceFirst(RegExp(r'\.html$'), '.yaml');
        expect(
          File(yamlPath).existsSync(),
          isTrue,
          reason: '${f.relativePath} 缺少配对的 .yaml',
        );
      }
    });

    test('validator 通过', () {
      // existsSync 探测代替 cwd 字符串判断(Windows 的 cwd 是反斜杠,
      // endsWith('packages/fluxdo_render') 永远 false → 选错路径)
      final root =
          [
            Directory('test/fixtures'),
            Directory('packages/fluxdo_render/test/fixtures'),
          ].firstWhere(
            (d) => d.existsSync(),
            orElse: () =>
                throw const FileSystemException('找不到 test/fixtures 目录'),
          );
      final report = validateFixtures(root);
      expect(
        report.ok,
        isTrue,
        reason: '已检查 ${report.checked} 个,错误:\n  ${report.errors.join('\n  ')}',
      );
    });

    test('每种节点类型分布', () {
      final fixtures = loader.loadAll();
      expect(fixtures.length, greaterThanOrEqualTo(1));

      final byType = <String, int>{};
      for (final f in fixtures) {
        byType[f.nodeType] = (byType[f.nodeType] ?? 0) + 1;
      }
      printOnFailure('fixture 分布: $byType');
    });
  });
}

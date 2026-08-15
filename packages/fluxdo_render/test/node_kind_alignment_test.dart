// 防漂移 test:NodeKind enum、fixture 目录、golden 目录必须三方对齐。
//
// 阶段 0 时 fixture / golden 目录可能不全(还没堆 fixture),只要不出现
// "fixture 目录里有但 NodeKind 没的"即可。enum 里有但目录没的是 OK 的
// (代表还没开始堆这个节点的 fixture)。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  test('每个 fixture 目录都对应一个 NodeKind', () {
    final fixturesRoot = _findFixturesDir();
    final dirNames = <String>{};
    for (final entity in fixturesRoot.listSync()) {
      if (entity is! Directory) continue;
      // Windows 的 listSync 产反斜杠路径,按两种分隔符切
      final name = entity.path.split(RegExp(r'[/\\]')).last;
      // 跳过 _meta / scripts / _edge_cases 等特殊目录(下划线开头)
      if (name.startsWith('_')) continue;
      // 跳过非节点子目录(如 scripts)
      if (name == 'scripts') continue;
      dirNames.add(name);
    }

    final knownDirs = NodeKind.values.map((k) => k.dirName).toSet();
    final unknown = dirNames.difference(knownDirs);
    expect(
      unknown,
      isEmpty,
      reason: 'fixture 目录里有 NodeKind enum 缺失的项:$unknown',
    );
  });

  test('每个 NodeKind 都应该已经有 fixture 目录(确保结构完整)', () {
    final fixturesRoot = _findFixturesDir();
    final dirNames = fixturesRoot
        .listSync()
        .whereType<Directory>()
        .map((d) => d.path.split(RegExp(r'[/\\]')).last)
        .toSet();

    final missing = NodeKind.values
        .map((k) => k.dirName)
        .where((d) => !dirNames.contains(d))
        .toList();

    expect(missing, isEmpty, reason: '没有对应 fixture 目录的 NodeKind:$missing');
  });
}

Directory _findFixturesDir() {
  for (final candidate in [
    'test/fixtures',
    'packages/fluxdo_render/test/fixtures',
  ]) {
    final d = Directory(candidate);
    if (d.existsSync()) return d;
  }
  throw FileSystemException('找不到 test/fixtures 目录');
}

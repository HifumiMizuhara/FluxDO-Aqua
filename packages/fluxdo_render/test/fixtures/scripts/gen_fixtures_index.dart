// 把 test/fixtures/ 下所有 fixture 编译进一个 Dart 文件,
// 让 example app 等跨平台环境不依赖 dart:io 也能列举 / 加载所有 fixture。
//
// 跑法(在 packages/fluxdo_render 目录下):
//   dart run test/fixtures/scripts/gen_fixtures_index.dart
//
// 产物:lib/src/dev/fixtures_index.g.dart(进仓,让 example pub get
// 不需要先跑脚本)

import 'dart:io';

import 'package:yaml/yaml.dart';

void main() {
  final root = Directory('test/fixtures');
  if (!root.existsSync()) {
    stderr.writeln('Run this script from the packages/fluxdo_render directory');
    exit(1);
  }

  final entries = <Map<String, dynamic>>[];
  for (final entity in root.listSync(recursive: true)) {
    // 统一正斜杠(Windows 的 listSync 产反斜杠:过滤、relPath、排序都靠它,
    // 否则产物 relativePath 混入反斜杠,跨平台重新生成来回全量 diff)
    final path = entity.path.replaceAll(r'\', '/');
    if (entity is! File || !path.endsWith('.html')) continue;
    if (path.contains('/_meta/')) continue;
    if (path.contains('/scripts/')) continue;

    final relPath = path.substring(root.path.length + 1);
    final html = entity.readAsStringSync();
    final yamlPath = entity.path.replaceFirst(RegExp(r'\.html$'), '.yaml');
    final yamlContent = File(yamlPath).existsSync()
        ? File(yamlPath).readAsStringSync()
        : '';

    String notes = '';
    String source = '';
    bool edgeCase = false;
    try {
      final doc = loadYaml(yamlContent) as YamlMap?;
      if (doc != null) {
        notes = (doc['notes'] as String? ?? '').trim();
        source = doc['source'] as String? ?? '';
        edgeCase = doc['edge_case'] as bool? ?? false;
      }
    } catch (_) {}

    entries.add({
      'relativePath': relPath,
      'html': html,
      'notes': notes,
      'source': source,
      'edgeCase': edgeCase,
    });
  }

  // 按 relativePath 字典序排,让 diff 稳定
  entries.sort(
    (a, b) =>
        (a['relativePath'] as String).compareTo(b['relativePath'] as String),
  );

  const outPath = 'lib/src/dev/fixtures_index.g.dart';
  Directory(outPath).parent.createSync(recursive: true);
  final buf = StringBuffer();
  buf.writeln('// GENERATED — do not edit by hand.');
  buf.writeln(
    '// 重新生成: dart run test/fixtures/scripts/gen_fixtures_index.dart',
  );
  buf.writeln();
  buf.writeln("import 'fixtures_index.dart';");
  buf.writeln();
  buf.writeln('const List<FixtureEntry> allFixtures = [');
  for (final e in entries) {
    buf.writeln('  FixtureEntry(');
    buf.writeln(
      '    relativePath: ${_dartString(e['relativePath'] as String)},',
    );
    buf.writeln('    html: ${_dartString(e['html'] as String)},');
    buf.writeln('    notes: ${_dartString(e['notes'] as String)},');
    buf.writeln('    source: ${_dartString(e['source'] as String)},');
    buf.writeln('    edgeCase: ${e['edgeCase']},');
    buf.writeln('  ),');
  }
  buf.writeln('];');

  File(outPath).writeAsStringSync(buf.toString());
  stdout.writeln('[gen] ${entries.length} fixtures → $outPath');
}

/// 输出 Dart 字符串字面量。
///
/// 优先 raw triple-quote (r''' ... ''')可包含任意字符(含 \$、\\、
/// 换行),只要不含 '''。否则 fallback 为转义后的常规字符串。
String _dartString(String s) {
  if (!s.contains("'''")) {
    return "r'''$s'''";
  }
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll(r'$', r'\$')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r');
  return "'$escaped'";
}

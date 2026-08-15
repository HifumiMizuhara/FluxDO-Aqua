/// 开发工具:fixture 索引数据类型。
///
/// 实际数据由 `dart run test/fixtures/scripts/gen_fixtures_index.dart`
/// 产出到 `fixtures_index.g.dart`(进仓,跨平台环境如 example app /
/// devtools_extension 都能 import 不依赖文件系统)。
library;

class FixtureEntry {
  const FixtureEntry({
    required this.relativePath,
    required this.html,
    required this.notes,
    required this.source,
    required this.edgeCase,
  });

  /// 相对 test/fixtures/ 的路径(如 "paragraph/simple_with_em.html")。
  final String relativePath;

  /// cooked HTML 内容(完整文件内容)。
  final String html;

  /// fixture 元数据中的 notes 字段(描述这个 fixture 测什么)。
  final String notes;

  /// 来源 URL。
  final String source;

  /// 是否为边界 case。
  final bool edgeCase;

  /// fixture 名称(去掉 .html 后缀的相对路径)。
  String get name => relativePath.replaceFirst(RegExp(r'\.html$'), '');

  /// 节点类型目录名(_edge_cases 折算为 "edge_case")。
  String get nodeType {
    final dir = relativePath.split('/').first;
    return dir == '_edge_cases' ? 'edge_case' : dir;
  }
}

/// 按节点类型分组所有 fixture。
Map<String, List<FixtureEntry>> groupByNodeType(List<FixtureEntry> entries) {
  final out = <String, List<FixtureEntry>>{};
  for (final e in entries) {
    out.putIfAbsent(e.nodeType, () => []).add(e);
  }
  return out;
}

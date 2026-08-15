// validate.dart 核心逻辑,作为可被 flutter test 直接调用的函数。
//
// 同时:`dart run test/fixtures/scripts/validate.dart` 也走这里。

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:yaml/yaml.dart';

const validNodeTypes = {
  'paragraph',
  'heading',
  'list',
  'code_block',
  'quote_card',
  'spoiler',
  'details',
  'onebox',
  'table',
  'poll',
  'math',
  'iframe',
  'image_grid',
  'lazy_video',
  'footnote',
  'mention',
  'emoji',
  'lightbox',
  'inline_code',
  'blockquote',
  'callout',
  'chat_transcript',
  'local_date',
  'policy',
  'horizontal_rule',
  'image',
  'click_count',
  'definition_list',
  'svg',
  'attachment',
  'video',
  'audio',
  'edge_case',
};

const _requiredFields = {'source', 'fetched_at', 'primary_node', 'sha256'};

/// 校验结果,空 list 表示全部通过。
class ValidateReport {
  ValidateReport({required this.checked, required this.errors});
  final int checked;
  final List<String> errors;
  bool get ok => errors.isEmpty;
}

/// 校验整个 fixtures 目录。
ValidateReport validateFixtures(Directory root, {bool fixSha = false}) {
  final errors = <String>[];
  var checked = 0;

  // 统一正斜杠再做字符串判断/切分(Windows 的 listSync 产反斜杠路径)
  final rootPath = root.path.replaceAll(r'\', '/');
  for (final entity in root.listSync(recursive: true)) {
    final path = entity.path.replaceAll(r'\', '/');
    if (entity is! File || !path.endsWith('.html')) continue;
    if (path.contains('/_meta/')) continue;
    if (path.contains('/scripts/')) continue;

    checked++;
    final relPath = path.substring(rootPath.length + 1);
    final dir = relPath.split('/').first;

    final yamlPath = entity.path.replaceFirst(RegExp(r'\.html$'), '.yaml');
    final yamlFile = File(yamlPath);
    if (!yamlFile.existsSync()) {
      errors.add('$relPath: 缺少配对的 .yaml');
      continue;
    }

    final yamlContent = yamlFile.readAsStringSync();
    YamlMap? doc;
    try {
      doc = loadYaml(yamlContent) as YamlMap?;
    } catch (e) {
      errors.add('$relPath: yaml parse 失败 — $e');
      continue;
    }
    if (doc == null) {
      errors.add('$relPath: yaml 内容为空');
      continue;
    }

    for (final field in _requiredFields) {
      if (!doc.containsKey(field)) {
        errors.add('$relPath: 缺少必填字段 $field');
      }
    }

    final primaryNode = doc['primary_node'] as String?;
    if (primaryNode != null && !validNodeTypes.contains(primaryNode)) {
      errors.add('$relPath: primary_node "$primaryNode" 不在合法枚举内');
    }

    if (primaryNode != null) {
      final isEdgeDir = dir == '_edge_cases';
      if (isEdgeDir && primaryNode != 'edge_case') {
        errors.add(
          '$relPath: 在 _edge_cases/ 下,primary_node 应为 edge_case (当前: $primaryNode)',
        );
      } else if (!isEdgeDir && primaryNode == 'edge_case') {
        errors.add('$relPath: primary_node 为 edge_case 应放在 _edge_cases/ 下');
      } else if (!isEdgeDir && primaryNode != dir) {
        errors.add('$relPath: 目录是 $dir 但 primary_node 是 $primaryNode');
      }
    }

    final actualSha = _sha256OfFile(entity);
    final expectedSha = doc['sha256'] as String?;
    if (expectedSha == null) {
      errors.add('$relPath: yaml 缺 sha256');
    } else if (expectedSha != actualSha) {
      if (fixSha) {
        final fixed = yamlContent.replaceFirst(
          RegExp(r'^sha256:.*$', multiLine: true),
          'sha256: $actualSha',
        );
        yamlFile.writeAsStringSync(fixed);
      } else {
        errors.add(
          '$relPath: sha256 不匹配 (yaml=$expectedSha, actual=$actualSha)',
        );
      }
    }
  }

  return ValidateReport(checked: checked, errors: errors);
}

String _sha256OfFile(File f) =>
    // package:crypto 纯 Dart 实现,跨平台(shasum 命令 Windows 上没有)
    sha256.convert(f.readAsBytesSync()).toString();

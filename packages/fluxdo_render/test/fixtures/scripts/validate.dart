// CLI 入口 —— 实际逻辑在 _meta/validator.dart,这样可以被 flutter test 直接调用。
//
// 用法(在 packages/fluxdo_render 目录下):
//   dart run test/fixtures/scripts/validate.dart
//   dart run test/fixtures/scripts/validate.dart --fix-sha

import 'dart:io';

import '../_meta/validator.dart';

void main(List<String> args) {
  final fixSha = args.contains('--fix-sha');
  final root = Directory('test/fixtures');
  if (!root.existsSync()) {
    stderr.writeln('Run this script from the packages/fluxdo_render directory');
    exit(1);
  }
  final report = validateFixtures(root, fixSha: fixSha);
  if (report.ok) {
    stdout.writeln('✓ Checked ${report.checked} fixtures; all valid');
    exit(0);
  } else {
    stderr.writeln(
      '✗ Checked ${report.checked} fixtures; ${report.errors.length} errors:',
    );
    for (final e in report.errors) {
      stderr.writeln('  - $e');
    }
    exit(1);
  }
}

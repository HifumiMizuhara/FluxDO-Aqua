/// M2 探针(可运行版)—— 喂任意真实 cooked HTML,dump「落到纯文本兜底(未覆盖)」
/// 的标签。把"渲染缺口"从真机踩雷变成可枚举:对真实帖跑一遍,冒出的标签就是待
/// 实现或待登记 intentionallyUnsupported 的 iceberg。
///
/// parser 依赖 `dart:ui`(Color/TextAlign),只能在 flutter test binding 下跑,
/// 故做成 test 而非纯 dart CLI。用法(在 packages/fluxdo_render 下):
///
///   # 探单个/多个文件(把 FAQ 帖 cooked 存成 .html):
///   PROBE_FILES=/tmp/faq.html fvm flutter test test/fwfh_probe_test.dart
///   PROBE_FILES="/tmp/a.html,/tmp/b.html" fvm flutter test test/fwfh_probe_test.dart
///
///   # 直接喂内联 HTML:
///   PROBE_HTML='<p><span style="color:red">x</span></p>' \
///     fvm flutter test test/fwfh_probe_test.dart
///
/// 不设 PROBE_FILES/PROBE_HTML 时:对全 test/fixtures/** 跑一遍(常规自检)。
/// 过滤「刻意不做」交给 fwfh_coverage_test(M3);本探针只产原始数据。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/src/parser/paragraph_parser.dart';

void main() {
  final parser = ParagraphParser();

  test('M2 探针:dump 未覆盖标签', () {
    final inputs = <({String label, String html})>[];

    final inlineHtml = Platform.environment['PROBE_HTML'];
    final files = Platform.environment['PROBE_FILES'];
    if (inlineHtml != null && inlineHtml.trim().isNotEmpty) {
      inputs.add((label: '<PROBE_HTML>', html: inlineHtml));
    } else if (files != null && files.trim().isNotEmpty) {
      for (final path
          in files.split(RegExp('[,\\s]+')).where((p) => p.isNotEmpty)) {
        final f = File(path);
        if (!f.existsSync()) {
          stderr.writeln('Skipping (file does not exist): $path');
          continue;
        }
        inputs.add((label: path, html: f.readAsStringSync()));
      }
    } else {
      // 兜底:扫全部 fixtures(常规自检,等价 M3 语料探针的原始 dump)。
      final dir = Directory('test/fixtures');
      for (final f
          in dir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.html'))) {
        inputs.add((label: f.path.split('/').last, html: f.readAsStringSync()));
      }
    }

    final union = <String, List<String>>{};
    for (final input in inputs) {
      final diag = parser.parseWithDiagnostics(input.html);
      final tags = diag.unhandledTags.toList()..sort();
      if (tags.isNotEmpty) {
        // ignore: avoid_print
        print('── ${input.label}: ${tags.join(', ')}');
        for (final t in tags) {
          union.putIfAbsent(t, () => []).add(input.label);
        }
      }
    }

    // ignore: avoid_print
    print(
      '\n══ 未覆盖标签并集(${union.length} 个):'
      '${union.isEmpty ? " 无(✓)" : ""}',
    );
    final keys = union.keys.toList()..sort();
    for (final k in keys) {
      // ignore: avoid_print
      print('   $k  ←  ${union[k]!.toSet().join(', ')}');
    }
  });
}

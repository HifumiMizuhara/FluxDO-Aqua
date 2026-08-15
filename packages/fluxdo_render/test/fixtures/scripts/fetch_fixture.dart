// fixture 采集脚本
//
// 从公开 Discourse 站点拉取 post 的 cooked HTML,写入 fixture 文件 + 配对元数据。
//
// 用法:
//   dart run test/fixtures/scripts/fetch_fixture.dart \
//     --site https://linux.do \
//     --topic 12345 \
//     --post-number 3 \
//     --out paragraph/my_case.html \
//     --notes "测试 mention 的段落"
//
// 或用完整 URL:
//   dart run test/fixtures/scripts/fetch_fixture.dart \
//     --url https://linux.do/t/topic-slug/12345/3 \
//     --out paragraph/my_case.html
//
// 必需的命令行参数: --out
// 可选参数: --notes / --sanitized / --edge-case / --also-contains "a,b,c"

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  if (opts == null) {
    _printUsage();
    exit(64); // EX_USAGE
  }

  stdout.writeln(
    '[fetch] resolving cooked from ${opts.site}/t/${opts.topicId} post #${opts.postNumber}',
  );

  final cooked = await _fetchCooked(
    site: opts.site,
    topicId: opts.topicId,
    postNumber: opts.postNumber,
  );

  stdout.writeln('[fetch] cooked: ${cooked.length} chars');

  // 写入 .html
  final fixturesDir = Directory('test/fixtures');
  if (!fixturesDir.existsSync()) {
    stderr.writeln(
      'Error: this script must be run from the packages/fluxdo_render directory',
    );
    exit(1);
  }
  final htmlFile = File('test/fixtures/${opts.out}');
  htmlFile.parent.createSync(recursive: true);
  htmlFile.writeAsStringSync(cooked, flush: true);
  stdout.writeln('[write] ${htmlFile.path}');

  // 推断 primary_node
  final primaryNode = _inferPrimaryNode(opts.out, cooked);

  // 算 sha256
  final sha = _sha256OfFile(htmlFile);

  // 写 .yaml
  final yamlPath = htmlFile.path.replaceFirst(RegExp(r'\.html$'), '.yaml');
  final yamlFile = File(yamlPath);
  final today = DateTime.now().toIso8601String().substring(0, 10);
  final notes = opts.notes ?? '(请填写测什么/为什么需要)';
  final alsoContainsLine = opts.alsoContains.isEmpty
      ? 'also_contains: []'
      : 'also_contains: [${opts.alsoContains.join(', ')}]';
  yamlFile.writeAsStringSync('''
source: ${opts.site}/t/${opts.topicId}/${opts.postNumber}
fetched_at: $today
primary_node: $primaryNode
sha256: $sha
$alsoContainsLine
edge_case: ${opts.edgeCase}
notes: |
  $notes
sanitized: ${opts.sanitized}
''', flush: true);
  stdout.writeln('[write] ${yamlFile.path}');

  // PII 启发式检查
  final piiHints = _detectPii(cooked);
  if (piiHints.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln('⚠️  PII heuristic check:');
    for (final hint in piiHints) {
      stdout.writeln('  - $hint');
    }
    stdout.writeln(
      'If PII is intentional, redact it manually and then set sanitized to true.',
    );
  }

  stdout.writeln('');
  stdout.writeln('[done] Review before running git add.');
}

// ─── HTTP ──────────────────────────────────────────────────────────────

Future<String> _fetchCooked({
  required String site,
  required int topicId,
  required int postNumber,
}) async {
  // /t/<topic_id>/<post_number>.json 返回该 topic 的 post stream 含 cooked。
  // 公开 Discourse 站点匿名可读。
  final url = Uri.parse('$site/t/$topicId/$postNumber.json');
  final client = HttpClient();
  client.userAgent = 'fluxdo_render-fixture-fetcher/0.1';
  try {
    final req = await client.getUrl(url);
    final res = await req.close();
    if (res.statusCode != 200) {
      throw 'HTTP ${res.statusCode} from $url';
    }
    final body = await res.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final posts =
        (json['post_stream'] as Map<String, dynamic>?)?['posts']
            as List<dynamic>?;
    if (posts == null) throw 'response has no post_stream.posts';

    // 找到 post_number 对应的 post
    for (final post in posts) {
      final p = post as Map<String, dynamic>;
      if (p['post_number'] == postNumber) {
        final cooked = p['cooked'] as String?;
        if (cooked == null) throw 'post #$postNumber 无 cooked 字段';
        return cooked;
      }
    }
    throw 'post #$postNumber 不在返回的 post_stream 内';
  } finally {
    client.close();
  }
}

// ─── 推断 + 校验 ────────────────────────────────────────────────────────

String _inferPrimaryNode(String relPath, String cooked) {
  // 优先用目录名(已经按节点类型组织)
  final dir = relPath.split('/').first;
  const validDirs = {
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
  };
  if (validDirs.contains(dir)) return dir;
  if (dir == '_edge_cases') return 'edge_case';

  // 否则启发式从 cooked 推断
  if (cooked.contains('<pre><code')) return 'code_block';
  if (cooked.contains('aside class="quote"')) return 'quote_card';
  if (cooked.contains('aside class="onebox"')) return 'onebox';
  if (cooked.contains('class="spoiler') || cooked.contains('class="spoiled'))
    return 'spoiler';
  if (cooked.contains('<details')) return 'details';
  if (cooked.contains('<table')) return 'table';
  if (cooked.contains('<h1')) return 'heading';
  if (cooked.contains('<ul') || cooked.contains('<ol')) return 'list';
  return 'paragraph';
}

String _sha256OfFile(File f) =>
    // package:crypto 纯 Dart 实现,跨平台(shasum 命令 Windows 上没有)
    sha256.convert(f.readAsBytesSync()).toString();

// ─── PII 启发式检查 ─────────────────────────────────────────────────────

List<String> _detectPii(String html) {
  final hints = <String>[];

  final emailRe = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
  if (emailRe.hasMatch(html)) {
    final example = emailRe.firstMatch(html)!.group(0)!;
    hints.add('疑似邮箱:$example');
  }

  // 中国大陆手机号(11 位,1 开头)
  final phoneRe = RegExp(r'(?<!\d)1[3-9]\d{9}(?!\d)');
  if (phoneRe.hasMatch(html)) {
    final example = phoneRe.firstMatch(html)!.group(0)!;
    hints.add('疑似手机号:$example');
  }

  // 中国身份证(18 位)
  final idRe = RegExp(r'(?<!\d)\d{17}[\dXx](?!\d)');
  if (idRe.hasMatch(html)) {
    final example = idRe.firstMatch(html)!.group(0)!;
    hints.add('疑似身份证:$example');
  }

  return hints;
}

// ─── 命令行解析 ─────────────────────────────────────────────────────────

class _Opts {
  final String site;
  final int topicId;
  final int postNumber;
  final String out;
  final String? notes;
  final List<String> alsoContains;
  final bool edgeCase;
  final bool sanitized;

  _Opts({
    required this.site,
    required this.topicId,
    required this.postNumber,
    required this.out,
    this.notes,
    this.alsoContains = const [],
    this.edgeCase = false,
    this.sanitized = false,
  });
}

_Opts? _parseArgs(List<String> args) {
  String? site;
  int? topicId;
  int? postNumber;
  String? out;
  String? notes;
  List<String> alsoContains = const [];
  bool edgeCase = false;
  bool sanitized = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String next() {
      if (i + 1 >= args.length) throw '$arg 缺少参数值';
      return args[++i];
    }

    switch (arg) {
      case '--url':
        final url = Uri.parse(next());
        // /t/slug/<topic>/<post>
        final segs = url.pathSegments;
        if (segs.length < 3 || segs[0] != 't') {
          throw '不识别的 URL 格式:期望 https://站点/t/slug/topic/post';
        }
        site = '${url.scheme}://${url.authority}';
        topicId = int.parse(segs[segs.length - 2]);
        postNumber = int.parse(segs.last);
      case '--site':
        site = next().replaceAll(RegExp(r'/$'), '');
      case '--topic':
        topicId = int.parse(next());
      case '--post-number':
        postNumber = int.parse(next());
      case '--out':
        out = next();
      case '--notes':
        notes = next();
      case '--also-contains':
        alsoContains = next().split(',').map((s) => s.trim()).toList();
      case '--edge-case':
        edgeCase = true;
      case '--sanitized':
        sanitized = true;
      case '--help' || '-h':
        return null;
      default:
        stderr.writeln('Unrecognized argument: $arg');
        return null;
    }
  }

  if (site == null || topicId == null || postNumber == null || out == null) {
    return null;
  }
  return _Opts(
    site: site,
    topicId: topicId,
    postNumber: postNumber,
    out: out,
    notes: notes,
    alsoContains: alsoContains,
    edgeCase: edgeCase,
    sanitized: sanitized,
  );
}

void _printUsage() {
  stderr.writeln('''
用法:
  dart run test/fixtures/scripts/fetch_fixture.dart \\
    --site https://linux.do \\
    --topic 12345 \\
    --post-number 3 \\
    --out paragraph/my_case.html \\
    [--notes "测什么"] \\
    [--also-contains "em,mention"] \\
    [--edge-case] \\
    [--sanitized]

或用 share URL:
  dart run test/fixtures/scripts/fetch_fixture.dart \\
    --url https://linux.do/t/slug/12345/3 \\
    --out paragraph/my_case.html

参数:
  --out         必填,相对 test/fixtures/ 的输出路径(含 .html 后缀)
  --notes       描述这个 fixture 测什么
  --also-contains  逗号分隔,该 fixture 内还出现什么节点类型
  --edge-case   标记为边界 case(_edge_cases/ 目录下默认应加此)
  --sanitized   标记已脱敏(只是 metadata,自动检测到 PII 不会自动脱敏)
''');
}

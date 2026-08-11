import 'dart:async';

import 'package:emoji_extension/emoji_extension.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import '../../constants.dart';
import '../../models/topic.dart';
import '../../utils/export_utils.dart';
import 'markdown_to_notion_blocks.dart';
import 'notion_client.dart';
import 'notion_config.dart';

/// 重复同步时的去重策略。
enum DuplicateAction {
  /// 已存在则跳过，不做任何操作（返回旧 page URL）
  skip,

  /// archive 旧 page，重新创建一份
  overwrite,
}

/// 同步进度阶段。
enum SyncPhase { fetch, convert, create, append, done }

class NotionSyncProgress {
  const NotionSyncProgress(this.phase, {this.current = 0, this.total = 0});
  final SyncPhase phase;
  final int current;
  final int total;
}

class NotionSyncResult {
  const NotionSyncResult({
    required this.pageId,
    required this.pageUrl,
    required this.postCount,
    required this.duplicated,
  });

  /// 新建或命中已有 page 的 id。
  final String pageId;
  final String pageUrl;
  final int postCount;

  /// true 表示同步前 database 里已有同 topic 的 page。
  final bool duplicated;
}

/// 已存在,等待用户决定。
class NotionDuplicateException implements Exception {
  NotionDuplicateException(this.existingPageId, this.existingPageUrl);
  final String existingPageId;
  final String existingPageUrl;
}

/// 把帖子同步到 Notion 的编排器。
///
/// 流程：fetchPostsForExport → renderMarkdown → 转 blocks →
/// createPage (前 100 块) → appendBlockChildren (剩余分批) → 写 ExportHistory。
class NotionSyncService {
  NotionSyncService({required this.config, NotionClient? client})
    : assert(config.isComplete, 'NotionConfig 必须先校验 isComplete 才能创建 service'),
      _client = client ?? NotionClient(config.integrationToken!);

  final NotionConfig config;
  final NotionClient _client;

  /// Notion API 限制：单次 createPage / appendBlockChildren 的 children ≤ 100。
  static const int _kChildrenPerRequest = 100;

  /// 速率限制保护：分批 append 之间 sleep。Notion 大约 3 req/sec。
  static const Duration _kRequestGap = Duration(milliseconds: 350);

  /// 同步一个话题到 Notion。
  ///
  /// [onDuplicate] = ask 时，命中已有 page 会抛 [NotionDuplicateException]，
  /// UI 弹框让用户选 skip / overwrite，然后用对应值重新调用本方法。
  Future<NotionSyncResult> syncTopic({
    required TopicDetail detail,
    required NotionSyncScope scope,
    DuplicateAction onDuplicate = DuplicateAction.skip,
    void Function(NotionSyncProgress)? onProgress,
  }) async {
    final exportScope = scope == NotionSyncScope.firstPostOnly
        ? ExportScope.firstPostOnly
        : ExportScope.allPosts;

    // 1. 抓帖
    onProgress?.call(const NotionSyncProgress(SyncPhase.fetch));
    final posts = await ExportUtils.fetchPostsForExport(
      detail: detail,
      scope: exportScope,
      onProgress: (cur, total) => onProgress?.call(
        NotionSyncProgress(SyncPhase.fetch, current: cur, total: total),
      ),
    );
    if (posts.isEmpty) {
      throw NotionApiException('No posts to sync');
    }

    // 2. 渲染 markdown,再转 Notion blocks
    onProgress?.call(const NotionSyncProgress(SyncPhase.convert));
    final markdown = await ExportUtils.renderMarkdown(
      detail: detail,
      posts: posts,
    );
    // 把 raw markdown 里 `![alt](upload://xxx.png)` 这种 Discourse 短码占位符
    // 替换成 cooked HTML 里的真实 CDN URL。否则图片在 Notion 全部丢失。
    final resolved = _resolveUploadShortUrls(markdown, posts);
    // 把 :joy: / :rocket: 这种 emoji shortcode 转成 Unicode 字符。
    // Discourse cooked 里 emoji 被渲染成 img.emoji,我们已过滤;raw 里是字面文本,
    // 不转换就会以"冒号包名字"的形式落到 Notion,影响阅读。
    final withEmojis = resolved.emojis.fromShortcodes();
    debugPrint('[NotionSync] resolved markdown:\n$withEmojis');
    final blocks = markdownToNotionBlocks(
      _preprocessDiscourseBbcode(withEmojis),
    );
    debugPrint('[NotionSync] generated blocks: ${blocks.length}');
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b['type'] == 'image') {
        debugPrint('[NotionSync]   block[$i] image: ${b['image']}');
      }
    }

    // 3. 去重查询(整篇话题:postId=null)
    final existingPageId = await _client.queryPage(
      config.databaseId!,
      topicId: detail.id,
    );
    final duplicated = existingPageId != null;
    if (duplicated) {
      switch (onDuplicate) {
        case DuplicateAction.skip:
          final url = _pageUrlFromId(existingPageId);
          return NotionSyncResult(
            pageId: existingPageId,
            pageUrl: url,
            postCount: posts.length,
            duplicated: true,
          );
        case DuplicateAction.overwrite:
          try {
            await _client.archivePage(existingPageId);
          } catch (e) {
            debugPrint('[NotionSync] archive old page failed: $e');
            // 失败也继续：新建一份,旧的留着用户自己清。
          }
      }
    }

    // 4. createPage + 分批 append
    onProgress?.call(const NotionSyncProgress(SyncPhase.create));
    final firstBatch = blocks.take(_kChildrenPerRequest).toList();
    final created = await _client.createPage(
      databaseId: config.databaseId!,
      properties: _buildTopicProperties(detail: detail),
      children: firstBatch,
    );
    final pageId = created['id'] as String;
    final pageUrl = (created['url'] as String?) ?? _pageUrlFromId(pageId);

    final remaining = blocks.skip(_kChildrenPerRequest).toList();
    if (remaining.isNotEmpty) {
      final batches = (remaining.length / _kChildrenPerRequest).ceil();
      for (var i = 0; i < batches; i++) {
        if (i > 0) await Future<void>.delayed(_kRequestGap);
        final slice = remaining
            .skip(i * _kChildrenPerRequest)
            .take(_kChildrenPerRequest)
            .toList();
        onProgress?.call(
          NotionSyncProgress(SyncPhase.append, current: i + 1, total: batches),
        );
        await _client.appendBlockChildren(pageId, slice);
      }
    }

    onProgress?.call(const NotionSyncProgress(SyncPhase.done));
    return NotionSyncResult(
      pageId: pageId,
      pageUrl: pageUrl,
      postCount: posts.length,
      duplicated: duplicated,
    );
  }

  /// 同步**单条 post** 到 Notion,生成独立 page。
  ///
  /// 与 [syncTopic] 不同:不受 [NotionSyncScope] 影响,永远只同步这一条;
  /// 去重粒度是 (topicId, postId)。
  Future<NotionSyncResult> syncPost({
    required TopicDetail detail,
    required Post post,
    DuplicateAction onDuplicate = DuplicateAction.skip,
    void Function(NotionSyncProgress)? onProgress,
  }) async {
    onProgress?.call(const NotionSyncProgress(SyncPhase.fetch));
    // 单条 post 也复用 renderMarkdown 一致的格式(自带 ## #N @user 头)
    final markdown = await ExportUtils.renderMarkdown(
      detail: detail,
      posts: [post],
    );

    onProgress?.call(const NotionSyncProgress(SyncPhase.convert));
    final resolved = _resolveUploadShortUrls(markdown, [post]);
    final withEmojis = resolved.emojis.fromShortcodes();
    final blocks = markdownToNotionBlocks(
      _preprocessDiscourseBbcode(withEmojis),
    );

    // 去重:按 (topicId, postId) 双键。如果 database 没有 Post ID 字段
    // (老用户尚未升级),降级到只按 topicId 查 —— 后果是同一 topic 下任意 post
    // 都会被视为已存在,跳过。设置页会提示用户去升级 Database。
    String? existingPageId;
    try {
      existingPageId = await _client.queryPage(
        config.databaseId!,
        topicId: detail.id,
        postId: post.id,
      );
    } on NotionApiException catch (e) {
      if (_looksLikeMissingProperty(e)) {
        debugPrint(
          '[NotionSync] Post ID property missing, fallback to topicId-only query',
        );
        existingPageId = await _client.queryPage(
          config.databaseId!,
          topicId: detail.id,
        );
      } else {
        rethrow;
      }
    }
    final duplicated = existingPageId != null;
    if (duplicated) {
      switch (onDuplicate) {
        case DuplicateAction.skip:
          return NotionSyncResult(
            pageId: existingPageId,
            pageUrl: _pageUrlFromId(existingPageId),
            postCount: 1,
            duplicated: true,
          );
        case DuplicateAction.overwrite:
          try {
            await _client.archivePage(existingPageId);
          } catch (e) {
            debugPrint('[NotionSync] archive old post page failed: $e');
          }
      }
    }

    onProgress?.call(const NotionSyncProgress(SyncPhase.create));
    final firstBatch = blocks.take(_kChildrenPerRequest).toList();
    // createPage 也可能因为 Post ID 字段不存在而报错。同样降级。
    Map<String, dynamic> created;
    try {
      created = await _client.createPage(
        databaseId: config.databaseId!,
        properties: _buildPostProperties(detail: detail, post: post),
        children: firstBatch,
      );
    } on NotionApiException catch (e) {
      if (_looksLikeMissingProperty(e)) {
        debugPrint(
          '[NotionSync] Post ID property missing, fallback to legacy schema',
        );
        // 不带 Post ID
        final legacy = _buildPostProperties(detail: detail, post: post)
          ..remove('Post ID');
        created = await _client.createPage(
          databaseId: config.databaseId!,
          properties: legacy,
          children: firstBatch,
        );
      } else {
        rethrow;
      }
    }
    final pageId = created['id'] as String;
    final pageUrl = (created['url'] as String?) ?? _pageUrlFromId(pageId);

    final remaining = blocks.skip(_kChildrenPerRequest).toList();
    if (remaining.isNotEmpty) {
      final batches = (remaining.length / _kChildrenPerRequest).ceil();
      for (var i = 0; i < batches; i++) {
        if (i > 0) await Future<void>.delayed(_kRequestGap);
        final slice = remaining
            .skip(i * _kChildrenPerRequest)
            .take(_kChildrenPerRequest)
            .toList();
        onProgress?.call(
          NotionSyncProgress(SyncPhase.append, current: i + 1, total: batches),
        );
        await _client.appendBlockChildren(pageId, slice);
      }
    }

    onProgress?.call(const NotionSyncProgress(SyncPhase.done));
    return NotionSyncResult(
      pageId: pageId,
      pageUrl: pageUrl,
      postCount: 1,
      duplicated: duplicated,
    );
  }

  /// 判断 Notion API 错误是否因为缺少 property,用于自动降级到老 schema。
  bool _looksLikeMissingProperty(NotionApiException e) {
    final msg = e.message.toLowerCase();
    return msg.contains('post id') ||
        msg.contains('property') && msg.contains('not') ||
        e.code == 'validation_error';
  }

  /// 检查 database 是否已升级到新 schema(含 Post ID 字段)。
  Future<bool> isDatabaseUpToDate() {
    return _client.hasProperty(config.databaseId!, 'Post ID');
  }

  /// 把老版本 database 升级到新 schema(自动加 Post ID 字段)。
  Future<void> upgradeDatabase() {
    return _client.ensureNumberProperty(config.databaseId!, 'Post ID');
  }

  /// 测试连接：拉一下 database meta。成功返回 database title,失败抛异常。
  Future<String> testConnection() async {
    final data = await _client.retrieveDatabase(config.databaseId!);
    final titleArr = data['title'] as List?;
    if (titleArr == null || titleArr.isEmpty) return '(untitled)';
    final first = titleArr.first as Map<String, dynamic>;
    final plain = first['plain_text'] as String?;
    return plain ?? '(untitled)';
  }

  // -----

  /// 话题级 page 的 properties:Post ID 留空,表示这是整篇话题。
  Map<String, dynamic> _buildTopicProperties({required TopicDetail detail}) {
    final firstPost = detail.postStream.posts.isNotEmpty
        ? detail.postStream.posts.first
        : null;
    final author = firstPost?.username ?? '';
    final created = firstPost?.createdAt.toUtc().toIso8601String();
    final url = '${AppConstants.baseUrl}/t/${detail.slug}/${detail.id}';
    return {
      'Name': {
        'title': [
          {
            'type': 'text',
            'text': {'content': _truncate(detail.title, 200)},
          },
        ],
      },
      'URL': {'url': url},
      'Topic ID': {'number': detail.id},
      if (author.isNotEmpty)
        'Author': {
          'rich_text': [
            {
              'type': 'text',
              'text': {'content': author},
            },
          ],
        },
      if (created != null)
        'Created': {
          'date': {'start': created},
        },
      'Synced': {
        'date': {'start': DateTime.now().toUtc().toIso8601String()},
      },
    };
  }

  /// 帖子级 page 的 properties:标题加 `· @user #N`,带 Post ID 用于去重。
  Map<String, dynamic> _buildPostProperties({
    required TopicDetail detail,
    required Post post,
  }) {
    final name =
        '${_truncate(detail.title, 160)} · @${post.username} #${post.postNumber}';
    final url =
        '${AppConstants.baseUrl}/t/${detail.slug}/${detail.id}/${post.postNumber}';
    return {
      'Name': {
        'title': [
          {
            'type': 'text',
            'text': {'content': name},
          },
        ],
      },
      'URL': {'url': url},
      'Topic ID': {'number': detail.id},
      'Post ID': {'number': post.id},
      'Author': {
        'rich_text': [
          {
            'type': 'text',
            'text': {'content': post.username},
          },
        ],
      },
      'Created': {
        'date': {'start': post.createdAt.toUtc().toIso8601String()},
      },
      'Synced': {
        'date': {'start': DateTime.now().toUtc().toIso8601String()},
      },
    };
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);

  static String _pageUrlFromId(String pageId) {
    final cleaned = pageId.replaceAll('-', '');
    return 'https://www.notion.so/$cleaned';
  }

  /// 把 raw markdown 里的 `upload://shortcode.ext` 替换成 cooked HTML 里
  /// 已被服务端解析的真实 CDN URL。
  ///
  /// 策略：
  /// 1. 按 post 顺序处理；每个 post 自己的 raw 段落只对应自己 cooked 里的 img
  /// 2. 单个 post 内,raw 里出现的 upload:// 与 cooked 里 `<img src>` 顺序一一对应
  /// 3. 找不到对应 img 的占位符保持原样(交给 [_normalizeImageUrl] 降级)
  ///
  /// 假设 `_exportToMarkdown` 的输出形如:
  ///   ## #N @user
  ///   `<raw 1>`
  ///   ---
  ///   ## #N @user
  ///   `<raw 2>`
  ///   ---
  /// 我们按 posts 的顺序提取每个段落对应的 cooked img URLs。
  String _resolveUploadShortUrls(String markdown, List<Post> posts) {
    final perPostUrls = <List<String>>[];
    for (final post in posts) {
      final urls = _extractCookedImageUrls(post.cooked);
      perPostUrls.add(urls);
      debugPrint(
        '[NotionSync] post #${post.postNumber} cooked imgs: ${urls.length}',
      );
    }
    final totalUploadInRaw = RegExp(
      r'upload://[^\s\)\]<>"]+',
    ).allMatches(markdown).length;
    debugPrint('[NotionSync] raw upload:// occurrences: $totalUploadInRaw');

    final segments = markdown.split(RegExp(r'\n---\n'));
    if (segments.length < 2) {
      final flat = perPostUrls.expand((u) => u).toList();
      return _replaceUploadInChunk(markdown, flat);
    }
    final out = <String>[segments.first];
    var postIdx = 0;
    for (var i = 1; i < segments.length; i++) {
      final seg = segments[i];
      final urls = postIdx < perPostUrls.length
          ? perPostUrls[postIdx]
          : const <String>[];
      out.add(_replaceUploadInChunk(seg, urls));
      postIdx++;
    }
    return out.join('\n---\n');
  }

  /// 按出现顺序消费 [urls],替换 chunk 里的 `upload://xxx.ext`。
  String _replaceUploadInChunk(String chunk, List<String> urls) {
    if (urls.isEmpty || !chunk.contains('upload://')) return chunk;
    final queue = List<String>.from(urls);
    final re = RegExp(r'upload://[^\s\)\]<>"]+');
    return chunk.replaceAllMapped(re, (m) {
      if (queue.isEmpty) return m.group(0)!;
      return queue.removeAt(0);
    });
  }

  /// 从 cooked HTML 里按顺序抽出所有真实 img URL。
  /// 忽略 data-: emoji 占位之类。
  List<String> _extractCookedImageUrls(String cooked) {
    if (cooked.isEmpty) return const [];
    final doc = html_parser.parseFragment(cooked);
    final allImgs = doc.querySelectorAll('img');
    debugPrint('[NotionSync] cooked all imgs: ${allImgs.length}');
    for (final img in allImgs) {
      debugPrint(
        '[NotionSync]   img attrs: ${img.attributes} parent=${img.parent?.localName} parentAttrs=${img.parent?.attributes}',
      );
    }
    final urls = <String>[];
    for (final img in allImgs) {
      // 跳过 emoji 这种装饰小图标
      final cls = img.attributes['class'] ?? '';
      if (cls.contains('emoji')) continue;
      // 优先 lightbox 包裹的 a[href](原图);否则 img.src
      String? src;
      final parent = img.parent;
      if (parent != null && parent.localName == 'a') {
        src = parent.attributes['href'];
      }
      src ??= img.attributes['src'];
      if (src == null || src.isEmpty) continue;
      if (src.startsWith('//')) src = 'https:$src';
      urls.add(src);
    }
    return urls;
  }

  /// 把 Discourse BBCode 风格的 `[details=...]...[/details]` 转成 markdown 里
  /// 我们能识别的占位结构。当前实现：转成 `> **summary**\n>\n> body` 引用块 +
  /// 折叠 emoji，因为 package:markdown 不解析 BBCode。
  /// 长期方案是切到 cooked HTML 路径,这里先做最小可用。
  String _preprocessDiscourseBbcode(String raw) {
    final detailsRe = RegExp(
      r'\[details(?:=([^\]]*))?\](.*?)\[/details\]',
      dotAll: true,
      caseSensitive: false,
    );
    final converted = raw.replaceAllMapped(detailsRe, (m) {
      final summary = (m.group(1) ?? '详情').trim();
      final body = (m.group(2) ?? '').trim();
      final quoted = body.split('\n').map((line) => '> $line').join('\n');
      return '> ▾ **$summary**\n>\n$quoted';
    });
    return converted;
  }
}

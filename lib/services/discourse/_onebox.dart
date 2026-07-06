part of 'discourse_service.dart';

/// Onebox 预览相关（编辑器 1:1 预览的链接卡片异步解析）
mixin _OneboxMixin on _DiscourseServiceBase {
  /// 请求块级 onebox 预览 HTML（服务端渲染的 aside.onebox 片段）。
  ///
  /// 对齐 web composer 的 GET /onebox：200 返回纯 HTML 文本；404（无法
  /// onebox）/ 429（并发限流）等一律返回 null，由调用方缓存失败避免重试风暴。
  Future<String?> fetchOneboxPreview(
    String url, {
    int? categoryId,
    int? topicId,
  }) async {
    try {
      final response = await _dio.get<String>(
        '/onebox',
        queryParameters: {
          'url': url,
          'category_id': ?categoryId,
          'topic_id': ?topicId,
        },
        options: Options(
          responseType: ResponseType.plain,
          // 404=该链接不可 onebox，是常态而非错误，别弹 toast
          validateStatus: (s) => s != null && (s == 200 || s == 404),
          extra: {'showErrorToast': false},
        ),
      );
      final html = response.data?.trim();
      if (response.statusCode != 200 || html == null || html.isEmpty) {
        return null;
      }
      return html;
    } catch (e) {
      debugPrint('[Onebox] 预览请求失败 $url: $e');
      return null;
    }
  }

  /// 请求行内 onebox（链接标题替换）。
  ///
  /// 对齐 web 的 GET /inline-onebox（≤10 条/批）：
  /// 返回 {url: (title, cssClass)}，无标题的 url 不在结果里。
  Future<Map<String, ({String title, String? cssClass})>>
  fetchInlineOneboxes(List<String> urls, {int? categoryId, int? topicId}) async {
    final result = <String, ({String title, String? cssClass})>{};
    if (urls.isEmpty) return result;
    try {
      final response = await _dio.get(
        '/inline-onebox',
        queryParameters: {
          'urls[]': urls.take(10).toList(),
          'category_id': ?categoryId,
          'topic_id': ?topicId,
        },
        options: Options(extra: {'showErrorToast': false}),
      );
      final data = response.data;
      if (data is Map) {
        final boxes = data['inline-oneboxes'];
        if (boxes is List) {
          for (final box in boxes) {
            if (box is! Map) continue;
            final url = box['url'] as String?;
            final title = box['title'] as String?;
            if (url == null || title == null || title.isEmpty) continue;
            result[url] = (title: title, cssClass: box['css_class'] as String?);
          }
        }
      }
    } catch (e) {
      debugPrint('[Onebox] inline 请求失败: $e');
    }
    return result;
  }
}

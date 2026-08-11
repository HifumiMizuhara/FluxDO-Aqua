import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/http.dart' as http;

/// AI 流式请求专用 http.Client。
///
/// 默认 `http.Client()` 在 iOS 真机上跑 LLM SSE 会踩两个坑：
/// 1. `HttpClient.idleTimeout` 默认 15s。模型 thinking 阶段（gpt-5 / o1 /
///    sonnet extended thinking）TCP 层面无数据，HttpClient 会主动关连接 →
///    stream 静默 `onDone` 但 buffer 为空 → 上报「未收到 AI 回复」。
/// 2. `connectionTimeout` 默认值在弱网下偶发卡死。
///
/// 改用 dio + IOHttpClientAdapter，手动把所有超时设成无限大，
/// 并且 `close()` 不取消进行中的请求（Kelivo 实测：close 时取消会让流
/// 在自然消费完之前被截断，导致 `await for` 拿不到末尾事件）。
class AiStreamHttpClient extends http.BaseClient {
  AiStreamHttpClient({HttpClientAdapter? adapter})
      : _ownsAdapter = adapter == null,
        _dio = Dio(
          BaseOptions(
            // 全部超时设 null：SSE 长流期间允许任意时长的空闲（thinking）
            connectTimeout: null,
            sendTimeout: null,
            receiveTimeout: null,
            validateStatus: (_) => true,
          ),
        ) {
    _dio.httpClientAdapter = adapter ?? _buildLongLivedIoAdapter();
  }

  final Dio _dio;
  final bool _ownsAdapter;
  final CancelToken _cancelToken = CancelToken();
  bool _closed = false;

  static IOHttpClientAdapter _buildLongLivedIoAdapter() {
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // 关键：禁用 idleTimeout。dart:io HttpClient 默认 15s idle 就关连接，
        // 对 thinking 阶段长达数十秒不发数据的 LLM SSE 是致命的。
        client.idleTimeout = const Duration(days: 3650);
        client.connectionTimeout = null;
        return client;
      },
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException(
          'AiStreamHttpClient has been closed.', request.url);
    }

    final body = await request.finalize().toBytes();
    final headers = Map<String, String>.from(request.headers);

    try {
      final response = await _dio.request<ResponseBody>(
        request.url.toString(),
        data: body.isEmpty ? null : body,
        options: Options(
          method: request.method,
          headers: headers,
          responseType: ResponseType.stream,
          followRedirects: request.followRedirects,
          maxRedirects: request.maxRedirects,
          receiveDataWhenStatusError: true,
        ),
        cancelToken: _cancelToken,
      );

      final statusCode = response.statusCode ?? 0;
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isEmpty) return;
        responseHeaders[name.toLowerCase()] = values.join(', ');
      });

      final responseBody = response.data!;
      final contentLength =
          responseBody.contentLength >= 0 ? responseBody.contentLength : null;

      return http.StreamedResponse(
        responseBody.stream.cast<List<int>>(),
        statusCode,
        contentLength: contentLength,
        request: request,
        headers: responseHeaders,
        isRedirect: response.isRedirect,
        reasonPhrase: response.statusMessage,
      );
    } on DioException catch (e) {
      throw http.ClientException(e.message ?? e.toString(), request.url);
    }
  }

  @override
  void close() {
    // 这个 client 是每次 send chat 时 factory 产出的独立实例，close 只可能来自：
    // - TopicAiChatNotifier.stopGeneration()（用户主动停止）
    // - TopicAiChatNotifier.dispose()
    //
    // 流自然结束时上层 onDone 只把引用置 null，不会调 close。
    // 所以这里直接取消 CancelToken 立即断流是安全的。
    if (_closed) return;
    _closed = true;
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('AiStreamHttpClient.close()');
    }
    if (_ownsAdapter) {
      _dio.close(force: false);
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_model_manager/services/dio_http_bridge.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this._respond);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
  ) _respond;

  RequestOptions? lastOptions;
  List<int>? lastBody;
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    if (requestStream != null) {
      final chunks = await requestStream.toList();
      lastBody = chunks.expand((c) => c).toList();
    }
    return _respond(options, requestStream);
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

void main() {
  group('DioBackedHttpClient', () {
    test('GET 透传 method/url/headers，并解析响应 body', () async {
      final adapter = _RecordingAdapter((options, _) async {
        return ResponseBody.fromString(
          '{"ok":true}',
          200,
          headers: {
            'content-type': ['application/json'],
            'content-length': ['11'],
          },
          statusMessage: 'OK',
        );
      });
      final client = DioBackedHttpClient(adapter);

      final response = await client.get(
        Uri.parse('https://api.example.com/v1/hello?x=1'),
        headers: {'Authorization': 'Bearer abc', 'X-Test': '1'},
      );

      expect(adapter.lastOptions!.method, 'GET');
      expect(adapter.lastOptions!.path, 'https://api.example.com/v1/hello?x=1');
      expect(adapter.lastOptions!.headers['authorization'], 'Bearer abc');
      expect(adapter.lastOptions!.headers['x-test'], '1');
      expect(response.statusCode, 200);
      expect(response.body, '{"ok":true}');
      expect(response.headers['content-type'], 'application/json');
    });

    test('POST 把 body 流式透传到 adapter', () async {
      final adapter = _RecordingAdapter((_, __) async {
        return ResponseBody.fromString('{}', 201,
            headers: {}, statusMessage: 'Created');
      });
      final client = DioBackedHttpClient(adapter);

      await client.post(
        Uri.parse('https://api.example.com/v1/x'),
        headers: {'Content-Type': 'application/json'},
        body: '{"q":"hi"}',
      );

      expect(adapter.lastOptions!.method, 'POST');
      expect(utf8.decode(adapter.lastBody!), '{"q":"hi"}');
    });

    test('流式响应（SSE 风格）按 chunk 透传，不在桥接层缓冲', () async {
      final controller = StreamController<Uint8List>();
      final adapter = _RecordingAdapter((_, __) async {
        return ResponseBody(
          controller.stream,
          200,
          headers: {
            'content-type': ['text/event-stream'],
          },
        );
      });
      final client = DioBackedHttpClient(adapter);

      final responseFuture = client.send(
        http.Request('POST', Uri.parse('https://api.example.com/v1/stream'))
          ..body = '',
      );

      final response = await responseFuture;
      final received = <List<int>>[];
      final sub = response.stream.listen(received.add);

      controller
        ..add(Uint8List.fromList(utf8.encode('data: chunk1\n\n')))
        ..add(Uint8List.fromList(utf8.encode('data: chunk2\n\n')));
      await Future<void>.delayed(Duration.zero);

      expect(received.length, 2);
      expect(utf8.decode(received[0]), 'data: chunk1\n\n');
      expect(utf8.decode(received[1]), 'data: chunk2\n\n');

      await controller.close();
      await sub.cancel();
    });

    test('4xx 不抛错，状态码原样返回', () async {
      final adapter = _RecordingAdapter((_, __) async {
        return ResponseBody.fromString('unauthorized', 401,
            headers: {}, statusMessage: 'Unauthorized');
      });
      final client = DioBackedHttpClient(adapter);

      final response = await client.get(Uri.parse('https://api.example.com/x'));
      expect(response.statusCode, 401);
      expect(response.reasonPhrase, 'Unauthorized');
      expect(response.body, 'unauthorized');
    });

    test('多值响应头按逗号合并', () async {
      final adapter = _RecordingAdapter((_, __) async {
        return ResponseBody.fromString('ok', 200, headers: {
          'set-cookie': ['a=1', 'b=2'],
        });
      });
      final client = DioBackedHttpClient(adapter);

      final response = await client.get(Uri.parse('https://api.example.com/x'));
      expect(response.headers['set-cookie'], 'a=1, b=2');
    });

    test('DioException 转为 http.ClientException', () async {
      final adapter = _RecordingAdapter((options, _) async {
        throw DioException(
          requestOptions: options,
          message: 'connection refused',
          type: DioExceptionType.connectionError,
        );
      });
      final client = DioBackedHttpClient(adapter);

      expect(
        () => client.get(Uri.parse('https://api.example.com/x')),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('close() 后再发请求抛 ClientException', () async {
      final adapter = _RecordingAdapter((_, __) async {
        return ResponseBody.fromString('', 200, headers: {});
      });
      final client = DioBackedHttpClient(adapter);
      client.close();

      expect(
        () => client.get(Uri.parse('https://api.example.com/x')),
        throwsA(isA<http.ClientException>()),
      );
      expect(adapter.closed, isTrue);
    });
  });
}

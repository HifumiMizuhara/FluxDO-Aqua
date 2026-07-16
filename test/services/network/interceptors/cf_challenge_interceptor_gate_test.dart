import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/interceptors/cf_challenge_interceptor.dart';

class _CountingAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final recovery = CfChallengeService();

  setUp(recovery.resetRecoveryState);
  tearDown(recovery.resetRecoveryState);

  Dio buildDio(_CountingAdapter adapter) {
    final dio = Dio(BaseOptions(baseUrl: 'https://linux.do'));
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(
      CfChallengeInterceptor(dio: dio, cookieJarService: CookieJarService()),
    );
    return dio;
  }

  test('原生链路 degraded 后静默业务请求在本地停止', () async {
    final adapter = _CountingAdapter();
    final dio = buildDio(adapter);
    recovery.markNativeNetworkDegraded();

    await expectLater(
      dio.post<void>(
        '/topics/timings',
        options: Options(extra: {'isSilent': true}),
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );

    expect(adapter.requests, 0);
  });

  test('静默恢复失败时后续静默请求不会发往网络', () async {
    final adapter = _CountingAdapter();
    final dio = buildDio(adapter);
    expect(recovery.tryBeginSilentRecovery(), isTrue);

    final request = dio.get<void>(
      '/presence/get',
      options: Options(extra: {'isSilent': true}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, 0);

    recovery.finishSilentRecovery(nativeRecovered: false);
    await expectLater(request, throwsA(isA<DioException>()));
    expect(adapter.requests, 0);
  });

  test('MessageBus 不接入业务请求恢复闸门', () async {
    final adapter = _CountingAdapter();
    final dio = buildDio(adapter);
    recovery.markNativeNetworkDegraded();

    final response = await dio.post<Map<String, dynamic>>(
      '/message-bus/client/poll',
      options: Options(extra: {'isSilent': true}),
    );

    expect(response.statusCode, 200);
    expect(adapter.requests, 1);
  });
}

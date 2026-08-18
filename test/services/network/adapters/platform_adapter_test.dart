import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/adapters/platform_adapter.dart';
import 'package:fluxdo/services/network/cf/cf_bypass_policy.dart';

void main() {
  group('requestAllowsRhttpAdapter', () {
    RequestOptions buildOptions({
      ResponseType? responseType,
      Map<String, dynamic>? extra,
    }) {
      return RequestOptions(
        path: '/latest.json',
        baseUrl: 'https://linux.do',
        responseType: responseType,
        extra: extra ?? <String, dynamic>{},
      );
    }

    test('普通 API 请求允许走 rhttp', () {
      expect(requestAllowsRhttpAdapter(buildOptions()), isTrue);
    });

    test('stream 响应默认允许走 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(responseType: ResponseType.stream),
        ),
        isTrue,
      );
    });

    test('bytes 响应默认允许走 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(responseType: ResponseType.bytes),
        ),
        isTrue,
      );
    });

    test('显式 skipRhttpAdapter 时旁路 rhttp', () {
      expect(
        requestAllowsRhttpAdapter(
          buildOptions(extra: {'skipRhttpAdapter': true}),
        ),
        isFalse,
      );
    });
  });

  group('rhttpAllowedForRequest', () {
    tearDown(CfBypassPolicy.resetForTest);

    RequestOptions options(String url) => RequestOptions(
      path: Uri.parse(url).path,
      baseUrl: '${Uri.parse(url).scheme}://${Uri.parse(url).host}',
    );

    test('要求非依存の解決では常に許可（起動時の表示用）', () {
      CfBypassPolicy.configure(true);
      expect(rhttpAllowedForRequest(null), isTrue);
    });

    test('CF 突破オフなら主站でも rhttp を許可（既定挙動）', () {
      expect(
        rhttpAllowedForRequest(options('https://linux.do/latest.json')),
        isTrue,
      );
    });

    test('CF 突破オンなら主站宛の rhttp を外す', () {
      CfBypassPolicy.configure(true);
      expect(
        rhttpAllowedForRequest(options('https://linux.do/latest.json')),
        isFalse,
      );
    });

    test('CF 突破オンでも CDN は rhttp のまま', () {
      CfBypassPolicy.configure(true);
      expect(
        rhttpAllowedForRequest(options('https://cdn.linux.do/uploads/a.png')),
        isTrue,
      );
    });

    test('明示的な skipRhttpAdapter は CF 突破と独立に効く', () {
      final opts = RequestOptions(
        path: '/latest.json',
        baseUrl: 'https://cdn.linux.do',
        extra: {'skipRhttpAdapter': true},
      );
      expect(rhttpAllowedForRequest(opts), isFalse);
    });
  });

  group('requestCanUseWebViewAdapter', () {
    RequestOptions options(
      String path, {
      String method = 'GET',
      String baseUrl = 'https://linux.do',
      ResponseType? responseType,
      Map<String, dynamic>? headers,
    }) {
      return RequestOptions(
        path: path,
        baseUrl: baseUrl,
        method: method,
        responseType: responseType,
        headers: headers,
      );
    }

    test('主站 JSON API 可以由 WebView 接管', () {
      expect(requestCanUseWebViewAdapter(options('/latest.json')), isTrue);
    });

    test('主站写操作可以由 WebView 接管', () {
      expect(
        requestCanUseWebViewAdapter(options('/posts', method: 'POST')),
        isTrue,
      );
    });

    test('MessageBus、子域和二进制请求不进入兼容提示', () {
      expect(
        requestCanUseWebViewAdapter(options('/message-bus/abc/poll')),
        isFalse,
      );
      expect(
        requestCanUseWebViewAdapter(
          options('/api/v1/user', baseUrl: 'https://cdk.linux.do'),
        ),
        isFalse,
      );
      expect(
        requestCanUseWebViewAdapter(
          options('/download.json', responseType: ResponseType.bytes),
        ),
        isFalse,
      );
    });

    test('明确 HTML 请求不进入兼容提示', () {
      expect(
        requestCanUseWebViewAdapter(
          options('/', headers: {'Accept': 'text/html'}),
        ),
        isFalse,
      );
    });
  });
}

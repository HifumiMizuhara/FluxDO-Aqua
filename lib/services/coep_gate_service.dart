import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'preloaded_data_service.dart';

/// 浏览器 COEP(require-corp)同款的跨域子资源准入判定。
///
/// linux.do 全站下发 `Cross-Origin-Embedder-Policy: require-corp`:网页上
/// 跨域 `<img>` 必须带 `Cross-Origin-Resource-Policy: cross-origin` 或命中
/// CORS(ACAO)才允许加载,否则浏览器整类拒载——第三方签名服务几乎都
/// 不带这些头,所以网页上一律不显示。app 没有 COEP 概念,拉到就能渲染;
/// 若不对齐,用户在网页上永远发现不了自己的签名其实是坏的。此服务在
/// 渲染前做同款判定,让 app 与网页的可见性一致。
///
/// 判定规则(对齐 Fetch spec 的 CORP 检查):
/// - 同站(站点 origin / cdn / s3 cdn 域)→ 允许;
/// - 跨站:HEAD 探测目标,
///   `Cross-Origin-Resource-Policy: cross-origin` 或
///   `Access-Control-Allow-Origin: * / 站点 origin` → 允许;否则拒绝。
/// - 探测网络失败 → 拒绝(网页同样加载不出来)。
///
/// 结论按 host 缓存(内存,会话级):同一签名服务域名只探测一次。
class CoepGateService {
  CoepGateService._();

  static final Map<String, Future<bool>> _verdictByHost = {};

  /// [url] 是否可在 COEP: require-corp 页面上作为子资源加载。
  static Future<bool> allows(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return SynchronousFuture(false);
    if (_isSameSite(uri)) return SynchronousFuture(true);
    return _verdictByHost.putIfAbsent(uri.host, () => _probe(uri));
  }

  static bool _isSameSite(Uri uri) {
    final preloaded = PreloadedDataService();
    final hosts = <String?>{
      Uri.tryParse(preloaded.baseUri)?.host,
      Uri.tryParse(preloaded.cdnUrl ?? '')?.host,
      Uri.tryParse(preloaded.s3CdnUrl ?? '')?.host,
    }..removeWhere((h) => h == null || h.isEmpty);
    return hosts.contains(uri.host);
  }

  static Future<bool> _probe(Uri uri) async {
    try {
      final origin = _siteOrigin();
      var resp = await http
          .head(uri, headers: {'Origin': origin})
          .timeout(const Duration(seconds: 8));
      // 部分服务不支持 HEAD(405/501),退化 GET(headers 足够,body 忽略)
      if (resp.statusCode == 405 || resp.statusCode == 501) {
        resp = await http
            .get(uri, headers: {'Origin': origin})
            .timeout(const Duration(seconds: 8));
      }
      if (resp.statusCode >= 400) return false;

      final corp = resp.headers['cross-origin-resource-policy']?.trim();
      if (corp != null) {
        // 显式 CORP:cross-origin 放行,same-origin/same-site 拒绝
        return corp.toLowerCase() == 'cross-origin';
      }
      final acao = resp.headers['access-control-allow-origin']?.trim();
      return acao == '*' || acao == origin;
    } catch (e) {
      debugPrint('[CoepGate] probe ${uri.host} 失败,按拒载处理: $e');
      return false;
    }
  }

  static String _siteOrigin() {
    final base = Uri.tryParse(PreloadedDataService().baseUri);
    if (base == null || !base.hasScheme) return '';
    return '${base.scheme}://${base.authority}';
  }
}

import '../../../l10n/s.dart';

/// OAuth 登录态过期异常，表示子域名的 401/403 响应
class OAuthExpiredException implements Exception {
  final String serviceName;
  final int? statusCode;

  const OAuthExpiredException({required this.serviceName, this.statusCode});

  @override
  String toString() => '$serviceName ${S.current.common_authExpired}';
}

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../cf_challenge_service.dart';
import '../../cf_challenge_logger.dart';
import '../../cf_clearance_refresh_service.dart';
import '../../app_logger.dart';
import '../adapters/platform_adapter.dart';
import '../cookie/boundary_sync_service.dart';
import '../cookie/cookie_jar_service.dart';
import '../webview/webview_adapter_settings_service.dart';
import '../../../l10n/s.dart';
import '../exceptions/api_exception.dart';

/// Cloudflare 验证拦截器
/// 处理 CF Turnstile 验证
class CfChallengeInterceptor extends Interceptor {
  CfChallengeInterceptor({required this.dio, required this.cookieJarService});

  final Dio dio;
  final CookieJarService cookieJarService;

  /// 共享的 cookie 同步 Future：验证成功后只执行一次 sync
  static Future<bool>? _activeSyncFuture;

  static const _mutationMethods = {'POST', 'PUT', 'DELETE', 'PATCH'};

  /// 验证成功后的共享 Cookie 同步（只执行一次）
  Future<bool> _syncCookiesOnce() async {
    // 如果已有同步任务在进行，复用结果
    if (_activeSyncFuture != null) return _activeSyncFuture!;

    _activeSyncFuture = _doSync();
    try {
      return await _activeSyncFuture!;
    } finally {
      _activeSyncFuture = null;
    }
  }

  Future<bool> _doSync() async {
    // showManualVerify 内部已通过 CDP 将新 cf_clearance 同步到 CookieJar，
    // 先检查是否已存在，避免后续 syncFromWebView 在 Windows 上通过
    // CookieManager.getCookies() 读取到旧值并覆盖（Bug #5 fix 会先删后写）。
    String? cfClearance = await cookieJarService.getCfClearance();
    if (cfClearance != null && cfClearance.isNotEmpty) {
      CfChallengeLogger.log(
        '[INTERCEPTOR] cf_clearance already in CookieJar: ${cfClearance.length} chars',
      );
      return true;
    }

    // CookieJar 中未找到 cf_clearance，走 WebView 同步兜底
    await Future.delayed(const Duration(milliseconds: 1500));
    await BoundarySyncService.instance.syncFromWebView(
      cookieNames: {'cf_clearance'},
    );

    for (var i = 0; i < 3; i++) {
      cfClearance = await cookieJarService.getCfClearance();
      if (cfClearance != null && cfClearance.isNotEmpty) break;
      debugPrint('[Dio] cf_clearance not found, retry ${i + 1}/3...');
      await Future.delayed(const Duration(milliseconds: 500));
      await BoundarySyncService.instance.syncFromWebView(
        cookieNames: {'cf_clearance'},
      );
    }

    if (cfClearance == null || cfClearance.isEmpty) {
      CfChallengeLogger.log('[INTERCEPTOR] cf_clearance not found after sync');
      return false;
    }
    CfChallengeLogger.log(
      '[INTERCEPTOR] cf_clearance verified: ${cfClearance.length} chars',
    );
    return true;
  }

  bool _shouldShowActionPrompt(RequestOptions options) {
    if (options.extra['isSilent'] == true) return false;
    if (options.extra.containsKey('showErrorToast')) {
      return options.extra['showErrorToast'] == true;
    }
    return _mutationMethods.contains(options.method.toUpperCase());
  }

  String _requestMode(RequestOptions options) {
    if (options.extra['isSilent'] == true) return 'silent';
    return _shouldShowActionPrompt(options) ? 'action' : 'data';
  }

  Future<void> _refreshCookieHeader(RequestOptions options) async {
    options.headers.remove('cookie');
    options.headers.remove('Cookie');

    final cookieHeader = await cookieJarService.getCookieHeaderForRequest(
      options.uri,
    );
    if (cookieHeader != null && cookieHeader.isNotEmpty) {
      options.headers['Cookie'] = cookieHeader;
    }
  }

  bool _isCfRejection(Object error) {
    return error is DioException &&
        (error.response?.statusCode == 403 ||
            error.response?.statusCode == 429) &&
        CfChallengeService.isCfChallengeResponse(error.response);
  }

  DioException _blockedLocally(RequestOptions options, {String? cause}) {
    return DioException(
      requestOptions: options,
      type: DioExceptionType.cancel,
      error: CfChallengeException(
        silentBlockedDuringChallenge: options.extra['isSilent'] == true,
        cause: cause,
      ),
    );
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra['_cfSilentRecoveryProbe'] == true) {
      handler.next(options);
      return;
    }
    final cfService = CfChallengeService();
    final isSilent = options.extra['isSilent'] == true;
    final isMessageBus = options.uri.path.startsWith('/message-bus/');

    // MessageBus 保持原有生命周期和恢复行为，不接入本次业务请求恢复闸门。
    if (isMessageBus) {
      handler.next(options);
      return;
    }

    // 静默恢复期间不让后续后台请求继续撞 CF；它们等待 owner 收口后丢弃，
    // 下一轮正常采集会自然使用恢复后的网络状态。
    if (cfService.isSilentRecoveryInProgress) {
      if (isSilent) {
        await cfService.waitForSilentRecovery();
        handler.reject(_blockedLocally(options), true);
        return;
      }
      await cfService.waitForSilentRecovery();
    }

    if (cfService.isNativeNetworkDegraded) {
      if (isSilent) {
        handler.reject(_blockedLocally(options), true);
        return;
      }

      if (requestCanUseWebViewAdapter(options)) {
        if (!cfService.tryBeginForegroundFallbackActivation()) {
          final activated = await cfService
              .waitForForegroundFallbackActivation();
          if (activated) {
            handler.next(options);
          } else {
            handler.reject(_blockedLocally(options), true);
          }
          return;
        }

        final settings = WebViewAdapterSettingsService.instance;
        final confirmed =
            settings.effectiveEnabled ||
            await cfService.confirmSessionCompatibilityMode();
        if (!confirmed) {
          cfService.finishForegroundFallbackActivation(success: false);
          cfService.markNativeNetworkRecovered();
          handler.reject(
            _blockedLocally(options, cause: '原生网络恢复失败，用户未启用临时兼容模式'),
            true,
          );
          return;
        }
        settings.enableSessionFallback();
        options.extra['_cfSessionFallbackActivation'] = true;
      }
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.requestOptions.extra.remove('_cfSessionFallbackActivation') ==
        true) {
      CfChallengeService().markNativeNetworkRecovered();
      CfChallengeService().finishForegroundFallbackActivation(success: true);
      CfChallengeService.showGlobalMessage(
        S.current.cf_sessionCompatEnabled,
        isError: false,
      );
    }
    handler.next(response);
  }

  Future<void> _handleSilentChallenge(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final cfService = CfChallengeService();
    if (!cfService.tryBeginSilentRecovery()) {
      await cfService.waitForSilentRecovery();
      handler.reject(_blockedLocally(err.requestOptions));
      return;
    }

    var recoveryFinished = false;
    void finish(bool recovered) {
      if (recoveryFinished) return;
      recoveryFinished = true;
      cfService.finishSilentRecovery(nativeRecovered: recovered);
    }

    final retryOptions = err.requestOptions;
    retryOptions.extra['skipCfChallenge'] = true;
    retryOptions.extra['skipCfBlock'] = true;
    retryOptions.extra['_cfSilentRecoveryProbe'] = true;

    try {
      final verified = await cfService.showManualVerify(null, false, true);
      if (verified != true || !await _syncCookiesOnce()) {
        finish(false);
        handler.reject(_blockedLocally(retryOptions));
        return;
      }

      await _refreshCookieHeader(retryOptions);
      try {
        final response = await dio.fetch(retryOptions);
        finish(true);
        cfService.clearanceResolvedAt.value = DateTime.now();
        handler.resolve(response);
        return;
      } catch (firstRetryError) {
        if (!_isCfRejection(firstRetryError)) {
          finish(true);
          if (firstRetryError is DioException) {
            handler.reject(firstRetryError);
          } else {
            handler.reject(
              DioException(
                requestOptions: retryOptions,
                error: firstRetryError,
                type: DioExceptionType.unknown,
              ),
            );
          }
          return;
        }
      }

      // 同一 IP 重启应用可以恢复时，优先在进程内重建当前业务 Dio 的
      // 底层适配器与连接池，再用唯一的 owner 请求验证一次。
      rebuildPlatformAdapter(dio);
      await _refreshCookieHeader(retryOptions);
      try {
        final response = await dio.fetch(retryOptions);
        finish(true);
        cfService.clearanceResolvedAt.value = DateTime.now();
        handler.resolve(response);
      } catch (secondRetryError) {
        final stillBlocked = _isCfRejection(secondRetryError);
        finish(!stillBlocked);
        if (secondRetryError is DioException) {
          handler.reject(secondRetryError);
        } else {
          handler.reject(
            DioException(
              requestOptions: retryOptions,
              error: secondRetryError,
              type: DioExceptionType.unknown,
            ),
          );
        }
      }
    } catch (e) {
      finish(false);
      if (e is DioException) {
        handler.reject(e);
      } else {
        handler.reject(
          DioException(
            requestOptions: retryOptions,
            error: e,
            type: DioExceptionType.unknown,
          ),
        );
      }
    } finally {
      if (!recoveryFinished) finish(false);
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.requestOptions.extra.remove('_cfSessionFallbackActivation') ==
        true) {
      final settings = WebViewAdapterSettingsService.instance;
      if (!settings.persistentEnabled) {
        settings.disableSessionFallback();
      }
      CfChallengeService().finishForegroundFallbackActivation(success: false);
      CfChallengeService().markNativeNetworkRecovered();
      CfChallengeLogger.log(
        '[INTERCEPTOR] Initial session WebView request failed; rollback fallback',
        level: 'warning',
      );
    }

    final statusCode = err.response?.statusCode;

    // 检查是否标记跳过 CF 验证（防止重试后再次触发）
    final skipCfChallenge = err.requestOptions.extra['skipCfChallenge'] == true;

    // CF 速率限制规则的 action 配为 managed_challenge / js_challenge / challenge 时,
    // 触发后返回 429 + cf-mitigated: challenge + 挑战页,而不是 403。
    // 因此 403 / 429 都要走 CF 验证流程,由 isCfChallengeResponse 精确判定。
    if ((statusCode == 403 || statusCode == 429) &&
        !skipCfChallenge &&
        CfChallengeService.isCfChallengeResponse(err.response)) {
      // 备选提取 sitekey（从 403 响应体中）
      CfClearanceRefreshService().extractAndUpdateSitekey(
        err.response?.data?.toString() ?? '',
      );
      // 403 说明 cf_clearance 已失效，停止自动续期（避免与手动验证冲突）
      CfClearanceRefreshService().stop();

      final requestUrl = err.requestOptions.uri.toString();
      final requestMethod = err.requestOptions.method.toUpperCase();
      final requestTag = err.requestOptions.extra['requestTag']?.toString();
      final logMessage =
          'CF Challenge detected: $requestMethod $requestUrl '
          '(status=$statusCode, silent=${err.requestOptions.extra['isSilent'] == true}, '
          'tag=${requestTag ?? '-'}, skipCsrf=${err.requestOptions.extra['skipCsrf'] == true})';
      debugPrint('[Dio] $logMessage');
      AppLogger.warning(logMessage, tag: 'CfChallengeInterceptor');
      CfChallengeLogger.logInterceptorDetected(
        url: requestUrl,
        statusCode: statusCode!,
      );
      final cfService = CfChallengeService();
      final isSilent = err.requestOptions.extra['isSilent'] == true;
      final isMessageBus = err.requestOptions.uri.path.startsWith(
        '/message-bus/',
      );
      final shouldShowActionPrompt = _shouldShowActionPrompt(
        err.requestOptions,
      );
      final requestMode = _requestMode(err.requestOptions);

      DioException cfException(CfChallengeException error) {
        return DioException(
          requestOptions: err.requestOptions,
          error: error,
          type: DioExceptionType.unknown,
        );
      }

      if (!cfService.autoVerifyEnabled) {
        CfChallengeLogger.log(
          '[INTERCEPTOR] Auto verify disabled, rejecting: '
          '$requestMethod $requestUrl mode=$requestMode',
        );
        return handler.reject(
          cfException(CfChallengeException(autoVerifyDisabled: true)),
        );
      }

      if (cfService.isInCooldown) {
        debugPrint('[Dio] CF Challenge in cooldown, rejecting request');
        CfChallengeLogger.log(
          '[INTERCEPTOR] Cooldown after 403: $requestMethod $requestUrl '
          'mode=$requestMode',
        );
        if (shouldShowActionPrompt) {
          CfChallengeService.showGlobalMessage(
            S.current.cf_operationBlockedByChallenge,
          );
        }
        return handler.reject(
          cfException(CfChallengeException(inCooldown: true)),
        );
      }

      if (isSilent && !isMessageBus) {
        await _handleSilentChallenge(err, handler);
        return;
      }

      // 用户可见请求已经接管恢复流程；清除后台 degraded gate，避免该请求
      // 在验证后的内部重试阶段再次被 onRequest 拦截。
      if (!isMessageBus) {
        cfService.markNativeNetworkRecovered();
      }

      // 页面数据/操作请求在前台展示验证；静默请求已由上面的单例恢复流程收口。
      final result = await cfService.showManualVerify(null, !isSilent);

      if (result == true) {
        final syncOk = await _syncCookiesOnce();
        if (!syncOk) {
          cfService.startCooldown();
          debugPrint(
            '[Dio] cf_clearance not found after sync, entering cooldown',
          );
          if (shouldShowActionPrompt) {
            CfChallengeService.showGlobalMessage(
              S.current.cf_challengeNotEffective,
            );
          }
          return handler.reject(
            cfException(
              CfChallengeException(cause: 'cf_clearance cookie 同步失败'),
            ),
          );
        }

        // 各自重试自己的原始请求（每个请求 URL/参数不同，无法共享）
        final retryOptions = err.requestOptions;
        try {
          retryOptions.extra['skipCfChallenge'] = true;
          // 绕过 RequestScheduler 的 CF 冻结判定。retry 时序上 isVerifying 已经
          // 复位为 false，但加这个标记是双保险，防止未来逻辑变更引入 race。
          retryOptions.extra['skipCfBlock'] = true;
          // 清除原始请求中残留的 cookie header，并补上最新 Cookie。
          // 这样即使 dio.fetch 不重新经过 CookieManager，也不会继续发送旧值。
          await _refreshCookieHeader(retryOptions);
          // 诊断：记录 CookieJar 中的 cookie 名称和 cf_clearance 状态
          final cookieHeader =
              retryOptions.headers['Cookie']?.toString() ??
              retryOptions.headers['cookie']?.toString();
          final hasCfClearance =
              cookieHeader?.contains('cf_clearance=') ?? false;
          final cookieNames = cookieHeader
              ?.split('; ')
              .map((c) => c.split('=').first)
              .join(', ');
          debugPrint(
            '[Dio] Retry cookies: ${hasCfClearance ? "✓ 包含 cf_clearance" : "⚠️ 缺少 cf_clearance"}, '
            'names=[$cookieNames], total=${cookieHeader?.length ?? 0} chars',
          );
          final response = await dio.fetch(retryOptions);
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: true,
            statusCode: response.statusCode,
          );
          // 广播:Dio 侧重试成功 = 新 cf_clearance 已生效。供 BrowserTrustCoordinator
          // 感知"CF 已解决",从而 force 重跑因同一 CF 失败的 WebView session bootstrap。
          cfService.clearanceResolvedAt.value = DateTime.now();
          cfService.markNativeNetworkRecovered();
          return handler.resolve(response);
        } catch (e) {
          final retryStillBlockedByCf =
              e is DioException &&
              (e.response?.statusCode == 403 ||
                  e.response?.statusCode == 429) &&
              CfChallengeService.isCfChallengeResponse(e.response);

          // 验证拿到新 clearance 后，原生链路仍被 CF 拒绝，说明问题不只是
          // Cookie，而是当前原生网络身份未被信任。仅对用户可见请求询问一次，
          // 用户确认后本次会话改用浏览器网络栈，并立即重放原请求。
          if (retryStillBlockedByCf &&
              !isSilent &&
              requestCanUseWebViewAdapter(retryOptions)) {
            final webViewSettings = WebViewAdapterSettingsService.instance;
            final shouldFallback =
                webViewSettings.effectiveEnabled ||
                await cfService.confirmSessionCompatibilityMode();
            if (shouldFallback) {
              webViewSettings.enableSessionFallback();
              retryOptions.extra['_cfSessionCompatRetry'] = true;
              retryOptions.extra.remove('skipWebViewAdapter');
              try {
                final fallbackResponse = await dio.fetch(retryOptions);
                CfChallengeService.showGlobalMessage(
                  S.current.cf_sessionCompatEnabled,
                  isError: false,
                );
                CfChallengeLogger.log(
                  '[INTERCEPTOR] Native retry still blocked; '
                  'session WebView fallback succeeded',
                );
                cfService.markNativeNetworkRecovered();
                return handler.resolve(fallbackResponse);
              } catch (fallbackError) {
                // 会话级兼容必须以首次真实请求成功为准；失败时立即回滚，
                // 避免所有后续请求被锁在一个坏掉的 WebView 传输状态里。
                if (!webViewSettings.persistentEnabled) {
                  webViewSettings.disableSessionFallback();
                }
                CfChallengeLogger.log(
                  '[INTERCEPTOR] Session WebView fallback failed: '
                  '$fallbackError',
                  level: 'warning',
                );
                if (fallbackError is DioException) {
                  return handler.reject(fallbackError);
                }
                return handler.reject(
                  DioException(
                    requestOptions: retryOptions,
                    error: fallbackError,
                    type: DioExceptionType.unknown,
                  ),
                );
              }
            }
          }

          // 诊断：记录完整的重试失败信息
          if (e is DioException) {
            debugPrint(
              '[Dio] Retry failed: status=${e.response?.statusCode}, '
              'type=${e.type}, url=${e.requestOptions.uri}',
            );
            if (e.response?.statusCode == 403 ||
                e.response?.statusCode == 429) {
              debugPrint(
                '[Dio] Retry got ${e.response?.statusCode} again — cf_clearance may not have been sent or already expired',
              );
            }
          } else {
            debugPrint('[Dio] Retry failed (non-Dio): $e');
          }
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: false,
            error: e.toString(),
          );
          // CF 验证已成功，重试失败是其他原因，传递实际错误以便排查
          if (e is DioException) {
            return handler.reject(e);
          }
          return handler.reject(
            DioException(
              requestOptions: err.requestOptions,
              error: e,
              type: DioExceptionType.unknown,
            ),
          );
        }
      }

      if (result == null) {
        if (cfService.isInCooldown) {
          CfChallengeLogger.log(
            '[INTERCEPTOR] Verification skipped by cooldown: '
            '$requestMethod $requestUrl mode=$requestMode',
          );
          if (shouldShowActionPrompt) {
            CfChallengeService.showGlobalMessage(
              S.current.cf_operationBlockedByChallenge,
            );
          }
          return handler.reject(
            cfException(CfChallengeException(inCooldown: true)),
          );
        }

        // 无 context（应用刚启动，context 还没设置好）
        debugPrint(
          '[Dio] CF Challenge: no context available, cannot show verify page',
        );
        CfChallengeLogger.log('[INTERCEPTOR] No context available');
        if (shouldShowActionPrompt) {
          CfChallengeService.showGlobalMessage(
            S.current.cf_cannotOpenVerifyPage,
          );
        }
        return handler.reject(
          cfException(CfChallengeException(cause: '无法获取 context，验证页面未展示')),
        );
      }

      // 用户取消或验证失败。页面数据请求交给 ErrorView 展示按钮；操作请求给即时提示；静默请求不打扰。
      CfChallengeLogger.log(
        '[INTERCEPTOR] User cancelled or verify failed: '
        '$requestMethod $requestUrl mode=$requestMode',
      );
      if (shouldShowActionPrompt) {
        CfChallengeService.showGlobalMessage(S.current.cf_verifyIncomplete);
      }
      return handler.reject(
        cfException(CfChallengeException(userCancelled: true)),
      );
    }

    handler.next(err);
  }
}

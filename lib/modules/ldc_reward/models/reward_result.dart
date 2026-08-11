import '../../../l10n/s.dart';

/// LDC 打赏结果模型
class LdcRewardResult {
  final bool success;
  final String? tradeNo;
  final String? errorMsg;

  const LdcRewardResult({required this.success, this.tradeNo, this.errorMsg});

  /// 从 API 响应解析
  factory LdcRewardResult.fromResponse(Map<String, dynamic> json) {
    final errorMsg = json['error_msg'] as String? ?? json['msg'] as String?;
    final data = json['data'] as Map<String, dynamic>?;

    // 有 data 且无错误信息即为成功
    if (data != null && (errorMsg == null || errorMsg.isEmpty)) {
      return LdcRewardResult(
        success: true,
        tradeNo: data['trade_no'] as String?,
      );
    }
    return LdcRewardResult(
      success: false,
      errorMsg: errorMsg ?? S.current.reward_defaultError,
    );
  }

  /// 创建错误结果
  factory LdcRewardResult.error(String message) {
    return LdcRewardResult(success: false, errorMsg: message);
  }
}

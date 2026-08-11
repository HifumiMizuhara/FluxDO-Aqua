import 'dart:math';

/// LDC 打赏请求模型
class LdcRewardRequest {
  final int userId;
  final String username;
  final double amount;
  final String outTradeNo;
  final String? remark;

  const LdcRewardRequest({
    required this.userId,
    required this.username,
    required this.amount,
    required this.outTradeNo,
    this.remark,
  });

  /// 生成唯一交易号
  /// 格式: LDR_T{topicId}_P{postId}_{timestamp}_{random4digits}
  static String generateTradeNo(int topicId, int postId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(9000) + 1000; // 1000-9999
    return 'LDR_T${topicId}_P${postId}_${timestamp}_$random';
  }

  /// 转换为 API 请求参数
  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'username': username,
    'amount': amount,
    'out_trade_no': outTradeNo,
    if (remark != null && remark!.isNotEmpty) 'remark': remark,
  };
}

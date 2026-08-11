// 这个测试不验证逻辑，只用于触发 langchain_openai 内部代码的实际编译，
// 检查 dependency_overrides 把 openai_dart 升到 4.x 后是否仍能 build。
import 'package:ai_model_manager/services/ai_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'AiChatService 可被 import 和实例化（验证 langchain_openai 在 openai_dart 4.x 上能编译）',
      () {
    final service = AiChatService();
    expect(service, isNotNull);
  });
}

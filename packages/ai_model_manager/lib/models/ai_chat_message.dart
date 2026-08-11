import '../l10n/ai_l10n.dart';
import 'ai_chat_attachment.dart';

/// 聊天角色
enum ChatRole { system, user, assistant }

/// 消息状态
enum MessageStatus { sending, streaming, completed, error }

/// AI 聊天消息
class AiChatMessage {
  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final MessageStatus status;
  final String? errorMessage;

  /// Anthropic Extended Thinking 块（推理过程），仅 assistant 消息可能有
  final String? thinkingContent;

  /// 用户消息的多模态附件（目前仅图片）
  final List<AiChatAttachment>? attachments;

  /// Token 用量（仅 assistant 完成态消息），来自 LLM provider 的 usage 字段
  final int? promptTokens;
  final int? responseTokens;
  final int? cachedTokens;

  /// 标记该 assistant 消息是图像生成请求（gpt-image / DALL-E 等）。
  /// 用于在 attachments 还为空时显示「正在生成图片」占位。
  /// 持久化时不必保存（已完成的图像消息会有 attachments）。
  final bool isImageGeneration;

  /// 流式过程中的细分阶段（仅 streaming 状态有效，不持久化）。
  /// 例如图像生成的两步流程会经历：
  /// - `'optimizing_prompt'` → 正在调聊天模型分析话题、优化 prompt
  /// - `'generating_image'` → 正在调 image API 出图
  /// UI 据此切换 placeholder 文案。
  final String? loadingStage;

  /// 图像生成时被 LLM 优化器精炼后的实际 prompt（持久化）。
  /// UI 会在 assistant 消息上渲染一个折叠块，让用户验证 optimizer 真的工作了
  /// 以及看清楚到底发给 image 模型的是什么 prompt。
  /// null = 未走优化（默认场景或 fallback）；非空 = 走了优化且成功。
  final String? optimizedPrompt;

  /// 优化器使用的模型 display name（持久化，用于 UI 显示「Optimized by xxx」）。
  final String? optimizerModelName;

  const AiChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.status = MessageStatus.completed,
    this.errorMessage,
    this.thinkingContent,
    this.attachments,
    this.promptTokens,
    this.responseTokens,
    this.cachedTokens,
    this.isImageGeneration = false,
    this.loadingStage,
    this.optimizedPrompt,
    this.optimizerModelName,
  });

  AiChatMessage copyWith({
    String? id,
    ChatRole? role,
    String? content,
    DateTime? createdAt,
    MessageStatus? status,
    String? errorMessage,
    String? thinkingContent,
    List<AiChatAttachment>? attachments,
    int? promptTokens,
    int? responseTokens,
    int? cachedTokens,
    bool? isImageGeneration,
    String? loadingStage,
    String? optimizedPrompt,
    String? optimizerModelName,
  }) {
    return AiChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      thinkingContent: thinkingContent ?? this.thinkingContent,
      attachments: attachments ?? this.attachments,
      promptTokens: promptTokens ?? this.promptTokens,
      responseTokens: responseTokens ?? this.responseTokens,
      cachedTokens: cachedTokens ?? this.cachedTokens,
      isImageGeneration: isImageGeneration ?? this.isImageGeneration,
      loadingStage: loadingStage ?? this.loadingStage,
      optimizedPrompt: optimizedPrompt ?? this.optimizedPrompt,
      optimizerModelName: optimizerModelName ?? this.optimizerModelName,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role.name,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
      'status': status.name,
      if (errorMessage != null) 'errorMessage': errorMessage,
      if (thinkingContent != null) 'thinkingContent': thinkingContent,
      if (attachments != null && attachments!.isNotEmpty)
        'attachments': attachments!.map((a) => a.toJson()).toList(),
      if (promptTokens != null) 'promptTokens': promptTokens,
      if (responseTokens != null) 'responseTokens': responseTokens,
      if (cachedTokens != null) 'cachedTokens': cachedTokens,
      if (optimizedPrompt != null) 'optimizedPrompt': optimizedPrompt,
      if (optimizerModelName != null) 'optimizerModelName': optimizerModelName,
    };
  }

  factory AiChatMessage.fromJson(Map<String, dynamic> json) {
    return AiChatMessage(
      id: json['id'] as String,
      role: ChatRole.values.byName(json['role'] as String),
      content: json['content'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      status: MessageStatus.values.byName(json['status'] as String),
      errorMessage: json['errorMessage'] as String?,
      thinkingContent: json['thinkingContent'] as String?,
      attachments: (json['attachments'] as List<dynamic>?)
          ?.map((e) => AiChatAttachment.fromJson(e as Map<String, dynamic>))
          .toList(),
      promptTokens: json['promptTokens'] as int?,
      responseTokens: json['responseTokens'] as int?,
      cachedTokens: json['cachedTokens'] as int?,
      optimizedPrompt: json['optimizedPrompt'] as String?,
      optimizerModelName: json['optimizerModelName'] as String?,
    );
  }
}

/// AI 聊天会话（元数据）
class AiChatSession {
  final String id;
  final String? title;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AiChatSession({
    required this.id,
    this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  AiChatSession copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AiChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (title != null) 'title': title,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory AiChatSession.fromJson(Map<String, dynamic> json) {
    return AiChatSession(
      id: json['id'] as String,
      title: json['title'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }
}

/// 话题会话组（用于历史列表展示）
class TopicSessionGroup {
  final int topicId;
  final String? topicTitle;
  final List<AiChatSession> sessions;

  const TopicSessionGroup({
    required this.topicId,
    this.topicTitle,
    required this.sessions,
  });
}

/// 上下文范围
enum ContextScope {
  firstPostOnly,
  first5,
  first10,
  first20,
  all;

  String get label {
    switch (this) {
      case ContextScope.firstPostOnly:
        return AiL10n.current.firstPostOnly;
      case ContextScope.first5:
        return AiL10n.current.first5Posts;
      case ContextScope.first10:
        return AiL10n.current.first10Posts;
      case ContextScope.first20:
        return AiL10n.current.first20Posts;
      case ContextScope.all:
        return AiL10n.current.allPosts;
    }
  }
}

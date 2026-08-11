import '../models/ai_provider.dart';

/// 基于模型 ID 的能力推断器。
///
/// 设计原则（参考 Kelivo `ModelRegistry.infer`）：
/// - **只增不减**：推断结果合并到 [AiModel] 已有字段，不会移除用户手动添加的能力
/// - **数据 first-class**：能力存在 [AiModel] 上，UI 直接读字段判断，不在渲染路径上跑正则
/// - **后续可被云端规则覆盖**：未来加云端 capability JSON 时，把 [infer] 的结果作为下层兜底
///
/// 拉取模型列表后调用一次：
/// ```dart
/// final inferred = models.map(ModelCapabilities.infer).toList();
/// ```
class ModelCapabilities {
  ModelCapabilities._();

  /// 视觉模型（input 含 image）
  static final RegExp _vision = RegExp(
    // OpenAI: gpt-4o / gpt-4.1 / gpt-5（排除 gpt-5-chat 纯文本变体）/ o1/o3/o4 / chatgpt-4o
    r'\b(?:'
    r'gpt-4o(?:[-.\w]*)?|gpt-4\.1(?:[-.\w]*)?|gpt-5(?!-chat)(?:[-.\w]*)?|'
    r'chatgpt-4o(?:[-.\w]*)?|o[1-9](?:[-.\w]*)?|'
    // Anthropic
    r'claude-3(?:[-.\w]*)?|claude-(?:haiku|sonnet|opus)-[4-9](?:[-.\w]*)?|'
    // Google
    r'gemini-(?:1\.5|2\.0|2\.5|3)(?:[-.\w]*)?|gemini-(?:flash|pro|flash-lite)-latest|'
    r'gemini-exp(?:[-.\w]*)?|gemma-?[34](?:[-.\w]*)?|'
    // Qwen / Alibaba
    r'qwen[2-3]?(?:\.\d+)?-?vl(?:[-.\w]*)?|qvq(?:[-.\w]*)?|'
    r'qwen3\.[5-9](?:[-.\w]*)?|qwen-omni(?:[-.\w]*)?|'
    // ByteDance
    r'doubao-seed-(?:1[.-][68]|2[.-]0|code)(?:[-.\w]*)?|'
    // Moonshot / Kimi
    r'kimi-vl(?:[-.\w]*)?|kimi-k2\.[56](?:[-.\w]*)?|kimi-thinking-preview|kimi-latest|'
    // Step
    r'step-1[ov](?:[-.\w]*)?|'
    // DeepSeek
    r'deepseek-vl(?:[-.\w]*)?|'
    // Meta / Mistral / xAI / Others
    r'llama-4(?:[-.\w]*)?|llama-guard-4(?:[-.\w]*)?|'
    r'pixtral(?:[-.\w]*)?|mistral-large-(?:2512|latest)|mistral-medium-(?:2508|latest)|mistral-small(?:[-.\w]*)?|'
    r'grok-(?:vision-beta|4)(?:[-.\w]*)?|'
    r'glm-4(?:\.\d+)?v(?:[-.\w]*)?|glm-5v-turbo|'
    r'internvl2(?:[-.\w]*)?|llava(?:[-.\w]*)?|moondream(?:[-.\w]*)?|minicpm(?:[-.\w]*)?'
    r')\b',
    caseSensitive: false,
  );

  /// 推理 / 思考模型（abilities 含 reasoning）
  static final RegExp _reasoning = RegExp(
    r'\b(?:'
    // OpenAI o-series + gpt-5 + gpt-oss
    r'o[1-9](?:[-.\w]*)?|gpt-5(?!-chat)(?:[-.\w]*)?|gpt-oss(?:[-.\w]*)?|'
    // Gemini 2.5+ / 3
    r'gemini-(?:2\.5|3)(?:[-.\w]*)?|gemini-(?:flash|pro)-latest|'
    // Anthropic（4.x 起常态化 thinking 支持）
    r'claude(?:[-.\w]*thinking|[-.\w]*-(?:sonnet|opus|haiku)-[4-9])(?:[-.\w]*)?|'
    // Qwen 3 / Doubao Seed 1.6+ / Kimi K2 / Grok 4 / Step 3 / GLM 4.5+
    r'qwen-?3(?:[-.\w]*)?|doubao-seed-1[.-][68](?:[-.\w]*)?|kimi-k2(?:[-.\w]*)?|kimi-thinking-preview|'
    r'grok-4(?:[-.\w]*)?|step-3(?:[-.\w]*)?|intern-s1(?:[-.\w]*)?|'
    r'glm-(?:4\.[5-9]|5|6|7)(?:[-.\w]*)?|minimax-m2(?:[-.\w]*)?|'
    // DeepSeek R1 / V3.1+ / reasoner
    r'deepseek-(?:r1|v3\.[12]|v4|reasoner)(?:[-.\w]*)?|'
    // 其他
    r'mimo-v2(?:[-.\w]*)?|qvq(?:[-.\w]*)?'
    r')\b',
    caseSensitive: false,
  );

  /// 工具调用 / function calling 模型（abilities 含 tool）
  static final RegExp _tool = RegExp(
    r'\b(?:'
    r'gpt-4o(?:[-.\w]*)?|gpt-4\.1(?:[-.\w]*)?|gpt-5(?!-chat)(?:[-.\w]*)?|gpt-oss(?:[-.\w]*)?|o[1-9](?:[-.\w]*)?|'
    r'gemini(?:[-.\w]*)?|claude(?:[-.\w]*)?|'
    r'qwen-?3(?:[-.\w]*)?|doubao-seed-1[.-][68](?:[-.\w]*)?|grok-4(?:[-.\w]*)?|'
    r'kimi-k2(?:[-.\w]*)?|step-3(?:[-.\w]*)?|intern-s1(?:[-.\w]*)?|'
    r'glm-(?:4\.[5-9]|5|6|7)(?:[-.\w]*)?|minimax-m2(?:[-.\w]*)?|'
    r'deepseek-(?:r1|v3|v3\.[12]|v4|chat|reasoner)(?:[-.\w]*)?|'
    r'mimo-v2(?:[-.\w]*)?'
    r')\b',
    caseSensitive: false,
  );

  /// 图像生成模型（output 含 image）
  static final RegExp _imageOutput = RegExp(
    r'\b(?:'
    r'dall-e(?:[-.\w]*)?|gpt-image(?:[-.\w]*)?|chatgpt-image-latest|'
    r'imagen(?:[-.\w]*)?|gemini-(?:2\.0|2\.5|3)(?:[-.\w]*)?-(?:flash|pro)-image(?:[-.\w]*)?|'
    r'flux(?:[-.\w]*)?|stable-?diffusion(?:[-.\w]*)?|stabilityai(?:[-.\w]*)?|sdxl(?:[-.\w]*)?|'
    r'cogview(?:[-.\w]*)?|qwen-image(?:[-.\w]*)?|midjourney(?:[-.\w]*)?|mj-[\w-]+|'
    r'grok-2-image(?:[-.\w]*)?|seedream(?:[-.\w]*)?|hunyuanimage(?:[-.\w]*)?|'
    r'janus(?:[-.\w]*)?|kandinsky(?:[-.\w]*)?'
    r')\b',
    caseSensitive: false,
  );

  /// 嵌入模型（id 含 embedding 通常说明是嵌入而非聊天）
  static final RegExp _embedding = RegExp(
    r'(?:^|[-_/])embed(?:dings?)?(?:[-.]|$)|embedding',
    caseSensitive: false,
  );

  /// 推断模型能力。
  /// 已有的字段会被保留，仅在缺失时根据模型 ID 添加默认值。
  /// 如果模型已被用户手动编辑过（[AiModel.capabilitiesUserEdited]），
  /// 直接返回原对象，不做任何推断 —— 避免下次拉模型列表覆盖用户的选择。
  static AiModel infer(AiModel base) {
    if (base.capabilitiesUserEdited) return base;
    final id = base.id.toLowerCase();
    final input = [...base.input];
    final output = [...base.output];
    final abilities = [...base.abilities];

    // 嵌入模型：跳过聊天能力推断（embedding 模型不应有 vision/reasoning/tool）
    if (_embedding.hasMatch(id)) {
      return base;
    }

    // 视觉
    if (_vision.hasMatch(id) && !input.contains(Modality.image)) {
      input.add(Modality.image);
    }
    // 图像输出
    if (_imageOutput.hasMatch(id)) {
      if (!output.contains(Modality.image)) output.add(Modality.image);
      // 大多数纯画图模型也接受图片输入（编辑/变体）
      if (!input.contains(Modality.image)) input.add(Modality.image);
    }
    // 推理
    if (_reasoning.hasMatch(id) &&
        !abilities.contains(ModelAbility.reasoning)) {
      abilities.add(ModelAbility.reasoning);
    }
    // 工具
    if (_tool.hasMatch(id) && !abilities.contains(ModelAbility.tool)) {
      abilities.add(ModelAbility.tool);
    }

    return base.copyWith(
      input: input,
      output: output,
      abilities: abilities,
    );
  }

  /// 是否为嵌入模型
  static bool isEmbedding(String modelId) {
    return _embedding.hasMatch(modelId.toLowerCase());
  }

  /// 是否为图像生成模型（output 含 image）。
  /// 用于 service 层路由到 /images/generations 端点（OpenAI 系）
  /// 或 generateContent + responseModalities=[image]（Gemini 系）。
  static bool isImageOutputModel(String modelId) {
    return _imageOutput.hasMatch(modelId.toLowerCase());
  }

  // ────────────────────────── 能力维度统一查询 / 写入 ──────────────────────────
  // 把 input/output/abilities 三个字段抽象为统一的 [ModelCapability]，
  // 方便 UI 用一组 chip 编辑而不必关心底层是 Modality 还是 ModelAbility。

  /// 查询模型是否具备某项能力
  static bool hasCapability(AiModel model, ModelCapability cap) {
    switch (cap) {
      case ModelCapability.vision:
        return model.input.contains(Modality.image);
      case ModelCapability.imageOutput:
        return model.output.contains(Modality.image);
      case ModelCapability.tool:
        return model.abilities.contains(ModelAbility.tool);
      case ModelCapability.reasoning:
        return model.abilities.contains(ModelAbility.reasoning);
    }
  }

  /// 切换某项能力的开关，并标记为用户已编辑（infer 时不再覆盖）
  static AiModel withCapability(
    AiModel model,
    ModelCapability cap,
    bool enabled,
  ) {
    var input = [...model.input];
    var output = [...model.output];
    var abilities = [...model.abilities];

    switch (cap) {
      case ModelCapability.vision:
        if (enabled) {
          if (!input.contains(Modality.image)) input.add(Modality.image);
        } else {
          input.remove(Modality.image);
          if (input.isEmpty) input.add(Modality.text);
        }
      case ModelCapability.imageOutput:
        if (enabled) {
          if (!output.contains(Modality.image)) output.add(Modality.image);
        } else {
          output.remove(Modality.image);
          if (output.isEmpty) output.add(Modality.text);
        }
      case ModelCapability.tool:
        if (enabled) {
          if (!abilities.contains(ModelAbility.tool)) {
            abilities.add(ModelAbility.tool);
          }
        } else {
          abilities.remove(ModelAbility.tool);
        }
      case ModelCapability.reasoning:
        if (enabled) {
          if (!abilities.contains(ModelAbility.reasoning)) {
            abilities.add(ModelAbility.reasoning);
          }
        } else {
          abilities.remove(ModelAbility.reasoning);
        }
    }

    // 排序保持稳定（toJson 顺序一致，便于 diff）
    input.sort((a, b) => a.index.compareTo(b.index));
    output.sort((a, b) => a.index.compareTo(b.index));
    abilities.sort((a, b) => a.index.compareTo(b.index));

    return model.copyWith(
      input: input,
      output: output,
      abilities: abilities,
      capabilitiesUserEdited: true,
    );
  }

  /// 重置某模型为「自动推断」模式：清掉用户编辑标记后重新 infer。
  /// 用于「重置为自动」按钮。
  static AiModel resetToAuto(AiModel model) {
    final cleared = model.copyWith(
      input: const [Modality.text],
      output: const [Modality.text],
      abilities: const [],
      capabilitiesUserEdited: false,
    );
    return infer(cleared);
  }
}

import 'prompt_dimension.dart';

/// 快捷词类型：文本聊天 vs 图像生成
enum PromptType {
  text,
  image;

  String toJson() => name;
  static PromptType fromJson(String value) =>
      PromptType.values.firstWhere((e) => e.name == value, orElse: () => text);
}

/// 一个可点即发的 AI 助手快捷词
///
/// 内置 preset 由主项目通过 `builtInPresetsProvider` 注入；用户可在管理页
/// 增删改、pin/unpin、隐藏内置等。
///
/// promptTemplate 中可以用占位符：
/// - `{title}` 当前话题标题
/// - `{context}` 上下文摘要（图像 prompt 优化器用得更多）
class PromptPreset {
  const PromptPreset({
    required this.id,
    required this.type,
    required this.name,
    required this.iconRaw,
    required this.promptTemplate,
    this.aspectRatio,
    this.tags = const [],
    this.pinned = false,
    this.sortOrder = 0,
    this.builtIn = false,
    this.hidden = false,
    this.dimensions,
    this.defaultDimensionValues,
  });

  /// 内置: 'builtin_image_cover' 等稳定 ID；自定义: uuid
  final String id;
  final PromptType type;

  /// 显示名（已解析的本地化文本，UI 直接展示）
  final String name;

  /// 'image_outlined' / 'brush_outlined' 等 Material icon 名，
  /// 或单个 emoji 字符如 '🎨'
  final String iconRaw;

  /// prompt 模板，含占位符
  final String promptTemplate;

  /// 仅 image preset 用：'1:1' / '16:9' / '9:16' / '4:3' / '3:4'
  /// null 表示用模型默认
  final String? aspectRatio;

  /// 分类标签（筛选用），如 ['封面', '极简']
  final List<String> tags;

  /// 是否常驻外显（聊天页底部 chip 区显示）
  final bool pinned;

  /// 排序权重，越小越靠前
  final int sortOrder;

  /// 是否为内置 preset（不可删，但可隐藏）
  final bool builtIn;

  /// 内置 preset 被用户隐藏（自定义无意义，恒 false）
  final bool hidden;

  /// 多维度配置（可选）。null = 点了直接发，无需维度选择
  final List<PromptDimension>? dimensions;

  /// 维度默认值: {dimensionId: optionValue}
  final Map<String, String>? defaultDimensionValues;

  bool get hasDimensions => dimensions != null && dimensions!.isNotEmpty;

  PromptPreset copyWith({
    String? id,
    PromptType? type,
    String? name,
    String? iconRaw,
    String? promptTemplate,
    String? aspectRatio,
    bool clearAspectRatio = false,
    List<String>? tags,
    bool? pinned,
    int? sortOrder,
    bool? builtIn,
    bool? hidden,
    List<PromptDimension>? dimensions,
    bool clearDimensions = false,
    Map<String, String>? defaultDimensionValues,
    bool clearDefaultDimensionValues = false,
  }) {
    return PromptPreset(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      iconRaw: iconRaw ?? this.iconRaw,
      promptTemplate: promptTemplate ?? this.promptTemplate,
      aspectRatio: clearAspectRatio ? null : (aspectRatio ?? this.aspectRatio),
      tags: tags ?? this.tags,
      pinned: pinned ?? this.pinned,
      sortOrder: sortOrder ?? this.sortOrder,
      builtIn: builtIn ?? this.builtIn,
      hidden: hidden ?? this.hidden,
      dimensions: clearDimensions ? null : (dimensions ?? this.dimensions),
      defaultDimensionValues: clearDefaultDimensionValues
          ? null
          : (defaultDimensionValues ?? this.defaultDimensionValues),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.toJson(),
        'name': name,
        'iconRaw': iconRaw,
        'promptTemplate': promptTemplate,
        if (aspectRatio != null) 'aspectRatio': aspectRatio,
        if (tags.isNotEmpty) 'tags': tags,
        'pinned': pinned,
        'sortOrder': sortOrder,
        'builtIn': builtIn,
        'hidden': hidden,
        if (dimensions != null)
          'dimensions': dimensions!.map((e) => e.toJson()).toList(),
        if (defaultDimensionValues != null)
          'defaultDimensionValues': defaultDimensionValues,
      };

  factory PromptPreset.fromJson(Map<String, dynamic> json) {
    return PromptPreset(
      id: json['id'] as String,
      type: PromptType.fromJson(json['type'] as String? ?? 'text'),
      name: json['name'] as String,
      iconRaw: json['iconRaw'] as String? ?? 'auto_awesome_outlined',
      promptTemplate: json['promptTemplate'] as String,
      aspectRatio: json['aspectRatio'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
      pinned: json['pinned'] as bool? ?? false,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      builtIn: json['builtIn'] as bool? ?? false,
      hidden: json['hidden'] as bool? ?? false,
      dimensions: (json['dimensions'] as List<dynamic>?)
          ?.map((e) => PromptDimension.fromJson(e as Map<String, dynamic>))
          .toList(),
      defaultDimensionValues:
          (json['defaultDimensionValues'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)),
    );
  }
}

/// 用户对内置 preset 的覆盖（部分字段，merge 到内置 preset 上）
///
/// 持久化时只存这部分，避免内置 preset 静态数据膨胀 SharedPreferences。
/// 自定义 preset 完整 toJson，不走这个路径。
class PresetCustomization {
  const PresetCustomization({
    required this.id,
    this.pinned,
    this.hidden,
    this.sortOrder,
    this.dimensionValues,
    this.aspectRatio,
  });

  final String id;
  final bool? pinned;
  final bool? hidden;
  final int? sortOrder;
  final Map<String, String>? dimensionValues;
  final String? aspectRatio;

  /// 把覆盖项 merge 到内置 preset 上
  PromptPreset apply(PromptPreset base) {
    return base.copyWith(
      pinned: pinned ?? base.pinned,
      hidden: hidden ?? base.hidden,
      sortOrder: sortOrder ?? base.sortOrder,
      defaultDimensionValues: dimensionValues ?? base.defaultDimensionValues,
      aspectRatio: aspectRatio ?? base.aspectRatio,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        if (pinned != null) 'pinned': pinned,
        if (hidden != null) 'hidden': hidden,
        if (sortOrder != null) 'sortOrder': sortOrder,
        if (dimensionValues != null) 'dimensionValues': dimensionValues,
        if (aspectRatio != null) 'aspectRatio': aspectRatio,
      };

  factory PresetCustomization.fromJson(Map<String, dynamic> json) {
    return PresetCustomization(
      id: json['id'] as String,
      pinned: json['pinned'] as bool?,
      hidden: json['hidden'] as bool?,
      sortOrder: (json['sortOrder'] as num?)?.toInt(),
      dimensionValues: (json['dimensionValues'] as Map<String, dynamic>?)
          ?.map((k, v) => MapEntry(k, v as String)),
      aspectRatio: json['aspectRatio'] as String?,
    );
  }
}

/// 工具：把 preset.promptTemplate 中的占位符替换为实际值
String renderPromptTemplate(
  String template, {
  String? title,
  String? context,
}) {
  var out = template;
  if (title != null) out = out.replaceAll('{title}', title);
  if (context != null) out = out.replaceAll('{context}', context);
  return out;
}

/// 工具：拼接维度 fragment
///
/// 用户在 [selectedDimensionValues] 中选了哪些维度选项，把对应的 promptFragment
/// 用换行追加到 base prompt 后面。
String appendDimensionFragments(
  String basePrompt,
  List<PromptDimension>? dimensions,
  Map<String, String>? selectedDimensionValues,
) {
  if (dimensions == null || dimensions.isEmpty) return basePrompt;
  if (selectedDimensionValues == null || selectedDimensionValues.isEmpty) {
    return basePrompt;
  }
  final fragments = <String>[];
  for (final dim in dimensions) {
    final value = selectedDimensionValues[dim.id];
    if (value == null) continue;
    final option = dim.options.firstWhere(
      (o) => o.value == value,
      orElse: () => const DimensionOption(
        value: '',
        label: '',
        promptFragment: '',
      ),
    );
    if (option.promptFragment.isNotEmpty) {
      fragments.add(option.promptFragment);
    }
  }
  if (fragments.isEmpty) return basePrompt;
  return '$basePrompt\n\n${fragments.join('；')}';
}

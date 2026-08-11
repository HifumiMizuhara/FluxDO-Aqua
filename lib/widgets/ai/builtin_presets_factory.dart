import 'package:ai_model_manager/ai_model_manager.dart';

import '../../l10n/s.dart';

/// 生成内置 PromptPreset 列表
///
/// 主项目侧实现，因为内置 preset 的 i18n 文本需要走主项目的 slang
/// （`S.current.ai_xxx`）。包内不直接依赖 slang，而是通过
/// `builtInPresetsProvider` 注入这个工厂的输出。
///
/// 调用方应在每次 locale 变化时重新生成（在 ProviderScope override 函数内
/// ref.watch(localeProvider) 即可触发）。
class BuiltInPresetsFactory {
  BuiltInPresetsFactory._();

  static const _titlePlaceholder = '{title}';

  /// 生成全部内置 preset（图像 + 文本）
  static List<PromptPreset> create() {
    return [..._imagePresets(), ..._textPresets()];
  }

  static List<PromptPreset> _imagePresets() {
    final l = S.current;
    final palette = _paletteDimension();
    final rendering = _renderingDimension();
    final aspect = _aspectDimension();

    return [
      PromptPreset(
        id: 'builtin_image_cover',
        type: PromptType.image,
        name: l.ai_imageCoverLabel,
        iconRaw: 'image_outlined',
        promptTemplate: l.ai_imageCoverPrompt(_titlePlaceholder),
        aspectRatio: '16:9',
        tags: const ['封面'],
        pinned: true,
        sortOrder: 10,
        builtIn: true,
        // 给「封面海报」配维度组合做 baoyu demo
        dimensions: [palette, rendering, aspect],
        defaultDimensionValues: const {
          'palette': 'mono',
          'rendering': 'flat-vector',
          'aspect': '16:9',
        },
      ),
      PromptPreset(
        id: 'builtin_image_illustration',
        type: PromptType.image,
        name: l.ai_imageIllustrationLabel,
        iconRaw: 'brush_outlined',
        promptTemplate: l.ai_imageIllustrationPrompt(_titlePlaceholder),
        aspectRatio: '1:1',
        tags: const ['插画'],
        pinned: true,
        sortOrder: 20,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_image_comic',
        type: PromptType.image,
        name: l.ai_imageComicLabel,
        iconRaw: 'emoji_emotions_outlined',
        promptTemplate: l.ai_imageComicPrompt(_titlePlaceholder),
        aspectRatio: '4:3',
        tags: const ['漫画', '幽默'],
        pinned: true,
        sortOrder: 30,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_image_card',
        type: PromptType.image,
        name: l.ai_imageCardLabel,
        iconRaw: 'share_outlined',
        promptTemplate: l.ai_imageCardPrompt(_titlePlaceholder),
        aspectRatio: '1:1',
        tags: const ['分享'],
        pinned: true,
        sortOrder: 40,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_image_infographic',
        type: PromptType.image,
        name: l.ai_imageInfographicLabel,
        iconRaw: 'draw_outlined',
        promptTemplate: l.ai_imageInfographicPrompt(_titlePlaceholder),
        aspectRatio: '16:9',
        tags: const ['信息图', '手绘'],
        pinned: true,
        sortOrder: 50,
        builtIn: true,
        // 给「手绘小报」也配维度
        dimensions: [palette, aspect],
        defaultDimensionValues: const {'palette': 'pastel', 'aspect': '16:9'},
      ),
      PromptPreset(
        id: 'builtin_image_minimal',
        type: PromptType.image,
        name: l.ai_imageMinimalLabel,
        iconRaw: 'crop_din_outlined',
        promptTemplate: l.ai_imageMinimalPrompt(_titlePlaceholder),
        aspectRatio: '1:1',
        tags: const ['极简'],
        sortOrder: 60,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_image_watercolor',
        type: PromptType.image,
        name: l.ai_imageWatercolorLabel,
        iconRaw: 'palette_outlined',
        promptTemplate: l.ai_imageWatercolorPrompt(_titlePlaceholder),
        aspectRatio: '4:3',
        tags: const ['水彩'],
        sortOrder: 70,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_image_pixel',
        type: PromptType.image,
        name: l.ai_imagePixelLabel,
        iconRaw: 'grid_4x4',
        promptTemplate: l.ai_imagePixelPrompt(_titlePlaceholder),
        aspectRatio: '1:1',
        tags: const ['像素', '复古'],
        sortOrder: 80,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_image_3d_clay',
        type: PromptType.image,
        name: l.ai_image3dClayLabel,
        iconRaw: 'view_in_ar_outlined',
        promptTemplate: l.ai_image3dClayPrompt(_titlePlaceholder),
        aspectRatio: '1:1',
        tags: const ['3D'],
        sortOrder: 90,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_image_sketch_notes',
        type: PromptType.image,
        name: l.ai_imageSketchNotesLabel,
        iconRaw: 'sticky_note_2_outlined',
        promptTemplate: l.ai_imageSketchNotesPrompt(_titlePlaceholder),
        aspectRatio: '4:3',
        tags: const ['手绘', '笔记'],
        sortOrder: 100,
        builtIn: true,
        // 给「涂鸦笔记」配 rendering 维度
        dimensions: [rendering, aspect],
        defaultDimensionValues: const {
          'rendering': 'hand-drawn',
          'aspect': '4:3',
        },
      ),
    ];
  }

  static List<PromptPreset> _textPresets() {
    final l = S.current;
    return [
      PromptPreset(
        id: 'builtin_text_summarize',
        type: PromptType.text,
        name: l.ai_summarizeTopic,
        iconRaw: 'summarize_outlined',
        promptTemplate: l.ai_summarizePrompt,
        pinned: true,
        sortOrder: 10,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_text_translate',
        type: PromptType.text,
        name: l.ai_translatePost,
        iconRaw: 'translate_outlined',
        promptTemplate: l.ai_translatePrompt,
        pinned: true,
        sortOrder: 20,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_text_viewpoints',
        type: PromptType.text,
        name: l.ai_listViewpoints,
        iconRaw: 'question_answer_outlined',
        promptTemplate: l.ai_listViewpointsPrompt,
        pinned: true,
        sortOrder: 30,
        builtIn: true,
      ),
      PromptPreset(
        id: 'builtin_text_highlights',
        type: PromptType.text,
        name: l.ai_highlights,
        iconRaw: 'lightbulb_outlined',
        promptTemplate: l.ai_highlightsPrompt,
        pinned: true,
        sortOrder: 40,
        builtIn: true,
      ),
    ];
  }

  // ─────────── 维度库 ───────────

  static PromptDimension _paletteDimension() {
    final l = S.current;
    return PromptDimension(
      id: 'palette',
      label: l.ai_dimensionPaletteLabel,
      options: [
        DimensionOption(
          value: 'warm',
          label: l.ai_paletteWarmLabel,
          promptFragment: l.ai_paletteWarmFragment,
        ),
        DimensionOption(
          value: 'cool',
          label: l.ai_paletteCoolLabel,
          promptFragment: l.ai_paletteCoolFragment,
        ),
        DimensionOption(
          value: 'pastel',
          label: l.ai_palettePastelLabel,
          promptFragment: l.ai_palettePastelFragment,
        ),
        DimensionOption(
          value: 'mono',
          label: l.ai_paletteMonoLabel,
          promptFragment: l.ai_paletteMonoFragment,
        ),
        DimensionOption(
          value: 'vivid',
          label: l.ai_paletteVividLabel,
          promptFragment: l.ai_paletteVividFragment,
        ),
        DimensionOption(
          value: 'earth',
          label: l.ai_paletteEarthLabel,
          promptFragment: l.ai_paletteEarthFragment,
        ),
        DimensionOption(
          value: 'retro',
          label: l.ai_paletteRetroLabel,
          promptFragment: l.ai_paletteRetroFragment,
        ),
      ],
    );
  }

  static PromptDimension _renderingDimension() {
    final l = S.current;
    return PromptDimension(
      id: 'rendering',
      label: l.ai_dimensionRenderingLabel,
      options: [
        DimensionOption(
          value: 'hand-drawn',
          label: l.ai_renderingHandDrawnLabel,
          promptFragment: l.ai_renderingHandDrawnFragment,
        ),
        DimensionOption(
          value: 'flat-vector',
          label: l.ai_renderingFlatVectorLabel,
          promptFragment: l.ai_renderingFlatVectorFragment,
        ),
        DimensionOption(
          value: 'watercolor',
          label: l.ai_renderingWatercolorLabel,
          promptFragment: l.ai_renderingWatercolorFragment,
        ),
        DimensionOption(
          value: 'chalk',
          label: l.ai_renderingChalkLabel,
          promptFragment: l.ai_renderingChalkFragment,
        ),
        DimensionOption(
          value: 'pixel',
          label: l.ai_renderingPixelLabel,
          promptFragment: l.ai_renderingPixelFragment,
        ),
        DimensionOption(
          value: '3d-clay',
          label: l.ai_rendering3dClayLabel,
          promptFragment: l.ai_rendering3dClayFragment,
        ),
      ],
    );
  }

  static PromptDimension _aspectDimension() {
    final l = S.current;
    return PromptDimension(
      id: 'aspect',
      label: l.ai_dimensionAspectLabel,
      // aspect 维度的 fragment 留空 —— aspect 不通过 prompt 表达，
      // 而是直接传给图像 API 的 size 参数。这里只用作 UI 选择。
      options: [
        DimensionOption(
          value: '1:1',
          label: l.ai_aspectSquareLabel,
          promptFragment: '',
        ),
        DimensionOption(
          value: '16:9',
          label: l.ai_aspectWideLabel,
          promptFragment: '',
        ),
        DimensionOption(
          value: '9:16',
          label: l.ai_aspectTallLabel,
          promptFragment: '',
        ),
        DimensionOption(
          value: '4:3',
          label: l.ai_aspect4x3Label,
          promptFragment: '',
        ),
        DimensionOption(
          value: '3:4',
          label: l.ai_aspect3x4Label,
          promptFragment: '',
        ),
      ],
    );
  }
}

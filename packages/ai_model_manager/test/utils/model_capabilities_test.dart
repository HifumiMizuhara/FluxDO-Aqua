import 'package:ai_model_manager/models/ai_provider.dart';
import 'package:ai_model_manager/utils/model_capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

AiModel _bare(String id) => AiModel(id: id);

void main() {
  group('ModelCapabilities.infer', () {
    group('vision', () {
      const visionIds = [
        'gpt-4o',
        'gpt-4o-mini',
        'gpt-4.1',
        'gpt-5',
        'gpt-5-mini-2025-08-07',
        'chatgpt-4o-latest',
        'o1',
        'o3-mini',
        'claude-3-5-sonnet-20241022',
        'claude-sonnet-4-5-20250929',
        'claude-opus-4-20250514',
        'gemini-1.5-pro',
        'gemini-2.5-flash',
        'gemini-3-pro-preview',
        'qwen-vl-plus',
        'qwen2.5-vl-7b-instruct',
        'qwen3-vl-72b',
        'kimi-vl-a3b-thinking',
        'doubao-seed-1.6-pro',
        'pixtral-12b-2409',
        'llava-v1.6-34b',
        'grok-4',
      ];
      for (final id in visionIds) {
        test('$id → input contains image', () {
          final inferred = ModelCapabilities.infer(_bare(id));
          expect(inferred.input, contains(Modality.image),
              reason: '$id should support vision');
        });
      }

      const nonVisionIds = [
        'gpt-3.5-turbo',
        'gpt-4-32k-0613',
        'gpt-5-chat-latest', // 排除 -chat 变体
        'text-embedding-3-small',
        'deepseek-chat',
      ];
      for (final id in nonVisionIds) {
        test('$id → input does not contain image', () {
          final inferred = ModelCapabilities.infer(_bare(id));
          expect(inferred.input, isNot(contains(Modality.image)),
              reason: '$id should NOT support vision');
        });
      }
    });

    group('reasoning', () {
      const reasoningIds = [
        'o1',
        'o1-preview',
        'o3',
        'o3-mini',
        'o4-mini',
        'gpt-5',
        'gpt-oss-20b',
        'gemini-2.5-pro',
        'gemini-3-pro-preview',
        'claude-sonnet-4-5-20250929',
        'deepseek-r1',
        'deepseek-reasoner',
        'qwen3-32b',
        'kimi-k2',
        'grok-4',
      ];
      for (final id in reasoningIds) {
        test('$id → abilities contain reasoning', () {
          final inferred = ModelCapabilities.infer(_bare(id));
          expect(inferred.abilities, contains(ModelAbility.reasoning),
              reason: '$id should support reasoning');
        });
      }

      const nonReasoningIds = [
        'gpt-3.5-turbo',
        'gpt-4o-mini',
        'gpt-5-chat-latest',
        'claude-3-haiku-20240307',
      ];
      for (final id in nonReasoningIds) {
        test('$id → abilities do not contain reasoning', () {
          final inferred = ModelCapabilities.infer(_bare(id));
          expect(inferred.abilities, isNot(contains(ModelAbility.reasoning)),
              reason: '$id should NOT support reasoning');
        });
      }
    });

    group('image generation (output image)', () {
      const imageGenIds = [
        'gpt-image-2',
        'gpt-image-1',
        'gpt-image-1-mini',
        'dall-e-3',
        'dall-e-2',
        'imagen-3',
        'gemini-2.5-flash-image',
        'gemini-3-flash-image-preview',
        'flux-schnell',
        'stable-diffusion-3.5',
        'qwen-image-edit',
        'midjourney-v6',
        'cogview-4',
      ];
      for (final id in imageGenIds) {
        test('$id → output contains image', () {
          final inferred = ModelCapabilities.infer(_bare(id));
          expect(inferred.output, contains(Modality.image),
              reason: '$id should output images');
        });
      }
    });

    group('embedding', () {
      // 仅当模型 ID 显式含 'embed' 字样时能被识别。
      // 纯厂商命名（如 BAAI/bge-large-en-v1.5）需要用户手动标注或云端规则覆盖。
      const embeddingIds = [
        'text-embedding-3-small',
        'text-embedding-3-large',
        'text-embedding-ada-002',
        'voyage-embedding-3',
      ];
      for (final id in embeddingIds) {
        test('$id → identified as embedding, no chat abilities added', () {
          expect(ModelCapabilities.isEmbedding(id), isTrue);
          final inferred = ModelCapabilities.infer(_bare(id));
          expect(inferred.input, isNot(contains(Modality.image)));
          expect(inferred.abilities, isEmpty);
        });
      }
    });

    group('user override', () {
      test('capabilitiesUserEdited=true → infer skips entirely', () {
        // 用户改过：把 gpt-4o 的 vision 关掉
        final user = AiModel(
          id: 'gpt-4o',
          input: const [Modality.text], // 用户故意去掉了 image
          capabilitiesUserEdited: true,
        );
        final inferred = ModelCapabilities.infer(user);
        // 不应被自动推断重新加上 image
        expect(inferred.input, [Modality.text]);
        expect(inferred.capabilitiesUserEdited, isTrue);
      });

      test('hasCapability returns correct status', () {
        final m = AiModel(
          id: 'gpt-4o',
          input: const [Modality.text, Modality.image],
          abilities: const [ModelAbility.tool],
        );
        expect(
            ModelCapabilities.hasCapability(m, ModelCapability.vision), isTrue);
        expect(ModelCapabilities.hasCapability(m, ModelCapability.imageOutput),
            isFalse);
        expect(
            ModelCapabilities.hasCapability(m, ModelCapability.tool), isTrue);
        expect(ModelCapabilities.hasCapability(m, ModelCapability.reasoning),
            isFalse);
      });

      test('withCapability toggles + sets capabilitiesUserEdited', () {
        var m = AiModel(id: 'unknown-model');
        // 启用 vision
        m = ModelCapabilities.withCapability(m, ModelCapability.vision, true);
        expect(m.input, contains(Modality.image));
        expect(m.capabilitiesUserEdited, isTrue);

        // 禁用 vision
        m = ModelCapabilities.withCapability(m, ModelCapability.vision, false);
        expect(m.input, isNot(contains(Modality.image)));
        expect(m.input, [Modality.text]); // 至少保留 text
      });

      test('resetToAuto clears edit flag and re-infers', () {
        // 用户先关掉了 gpt-4o 的 vision
        var m = AiModel(
          id: 'gpt-4o',
          input: const [Modality.text],
          capabilitiesUserEdited: true,
        );
        // 重置 → 应该重新识别为 vision 模型
        m = ModelCapabilities.resetToAuto(m);
        expect(m.capabilitiesUserEdited, isFalse);
        expect(m.input, contains(Modality.image));
      });

      test('persistence: capabilitiesUserEdited round-trips', () {
        final original = AiModel(
          id: 'custom-model',
          input: const [Modality.text, Modality.image],
          abilities: const [ModelAbility.tool],
          capabilitiesUserEdited: true,
        );
        final restored = AiModel.fromJson(original.toJson());
        expect(restored.capabilitiesUserEdited, isTrue);
        expect(restored.input, contains(Modality.image));
      });

      test('persistence: legacy json without flag → defaults false', () {
        final restored = AiModel.fromJson({
          'id': 'gpt-4o',
          'input': ['text', 'image'],
        });
        expect(restored.capabilitiesUserEdited, isFalse);
      });
    });

    test('infer is incremental — preserves user-set capabilities', () {
      // 用户手动给一个不常见的模型勾选了 vision
      final user = AiModel(
        id: 'unknown-model-x',
        input: const [Modality.text, Modality.image],
        abilities: const [ModelAbility.tool],
      );
      final inferred = ModelCapabilities.infer(user);
      expect(inferred.input, contains(Modality.image),
          reason: 'user-set image capability must be preserved');
      expect(inferred.abilities, contains(ModelAbility.tool),
          reason: 'user-set tool capability must be preserved');
    });

    test('toJson / fromJson round-trip preserves capabilities', () {
      final original = AiModel(
        id: 'gpt-4o',
        name: 'GPT-4o',
        input: const [Modality.text, Modality.image],
        output: const [Modality.text],
        abilities: const [ModelAbility.tool, ModelAbility.reasoning],
      );
      final restored = AiModel.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.input, original.input);
      expect(restored.output, original.output);
      expect(restored.abilities, original.abilities);
    });

    test('fromJson tolerates missing capability fields (legacy data)', () {
      // 老数据里没有 input/output/abilities 字段
      final restored = AiModel.fromJson({
        'id': 'gpt-4o-mini',
        'name': 'GPT-4o mini',
        'enabled': true,
      });
      expect(restored.input, [Modality.text]);
      expect(restored.output, [Modality.text]);
      expect(restored.abilities, isEmpty);
    });
  });
}

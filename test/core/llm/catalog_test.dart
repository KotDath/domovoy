import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_llm_provider.dart';

void main() {
  group('built-in catalog', () {
    test('enumerates exactly three profiles and eight models', () {
      expect(BuiltInLlmCatalog.profiles, hasLength(3));
      expect(BuiltInLlmCatalog.models, hasLength(8));
      expect(
        BuiltInLlmCatalog.profiles.map((profile) => profile.id.value),
        <String>['deepseek', 'moonshotai', 'openai'],
      );
      expect(
        BuiltInLlmCatalog.models.map((model) => model.id.value).toList(),
        <String>[
          'deepseek-v4-flash',
          'deepseek-v4-pro',
          'kimi-k2.6',
          'kimi-k2.7-code',
          'kimi-k3',
          'gpt-4o-mini',
          'gpt-5-mini',
          'gpt-5.4',
        ],
      );
    });

    test('profile snapshots never serialize embedded endpoint credentials', () {
      expect(
        () => LlmProviderProfile(
          id: ProviderId('custom'),
          wireFamily: LlmWireFamily.openaiChatCompletions,
          endpoint: Uri.parse('https://user:pass@api.example.test/v1'),
          environmentVariable: 'CUSTOM_API_KEY',
          dialectId: 'custom_chat_completions',
        ),
        throwsA(isA<LlmException>()),
      );
      final json = BuiltInLlmCatalog.deepSeekProfile.toJson();
      expect(json['endpoint'], 'https://api.deepseek.com/chat/completions');
      expect(json['endpoint'].toString(), isNot(contains('@')));
    });

    test('validates capabilities, context, and output bounds', () {
      for (final model in BuiltInLlmCatalog.models) {
        expect(model.capabilities.supportsTextInput, isTrue);
        expect(model.contextBound, greaterThan(0));
        expect(model.outputBound, greaterThan(0));
        expect(model.outputBound, lessThanOrEqualTo(model.contextBound));
      }
      expect(
        BuiltInLlmCatalog.deepSeekV4FlashModel.wireFamily,
        LlmWireFamily.openaiChatCompletions,
      );
      expect(
        BuiltInLlmCatalog.gpt54Model.wireFamily,
        LlmWireFamily.openaiResponses,
      );
      expect(
        BuiltInLlmCatalog.kimiK3Model.capabilities.canDisableReasoning,
        isFalse,
      );
      expect(
        BuiltInLlmCatalog.gpt4oMiniModel.capabilities.reasoning,
        ModelReasoningCapability.unsupported,
      );
      expect(
        BuiltInLlmCatalog.gpt5MiniModel.capabilities.reasoning,
        ModelReasoningCapability.required,
      );
      expect(
        BuiltInLlmCatalog.gpt54Model.capabilities.reasoning,
        ModelReasoningCapability.optional,
      );
      expect(
        BuiltInLlmCatalog.deepSeekV4FlashModel.capabilities.selectableEfforts,
        containsAll(<ReasoningEffort>[
          ReasoningEffort.low,
          ReasoningEffort.medium,
          ReasoningEffort.high,
          ReasoningEffort.max,
        ]),
      );
      expect(
        BuiltInLlmCatalog.kimiK26Model.capabilities.supportsTemperature,
        isFalse,
      );
    });

    test('registry keys do not collide when ids contain separators', () {
      final registry = LlmProviderRegistry();
      final left = LlmModel(
        providerId: ProviderId('a'),
        id: ModelId('b::c'),
        name: 'left',
        wireFamily: LlmWireFamily.openaiChatCompletions,
        capabilities: ModelCapabilities(
          supportsTextInput: true,
          reasoning: ModelReasoningCapability.unsupported,
          supportsTools: false,
        ),
        contextBound: 8,
        outputBound: 4,
      );
      final right = LlmModel(
        providerId: ProviderId('a::b'),
        id: ModelId('c'),
        name: 'right',
        wireFamily: LlmWireFamily.openaiResponses,
        capabilities: ModelCapabilities(
          supportsTextInput: true,
          reasoning: ModelReasoningCapability.unsupported,
          supportsTools: false,
        ),
        contextBound: 8,
        outputBound: 4,
      );
      registry.registerModel(left);
      registry.registerModel(right);
      expect(registry.requireModel(left.ref).name, 'left');
      expect(registry.requireModel(right.ref).name, 'right');
    });

    test('rejects undeclared provider/model pairs locally', () {
      final registry = LlmProviderRegistry();
      BuiltInLlmCatalog.registerInto(registry);
      registry.registerProvider(
        ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
        ),
      );
      expect(
        () => registry.resolve(
          ModelRef(
            providerId: BuiltInLlmCatalog.deepSeek,
            modelId: ModelId('deepseek-chat'),
          ),
        ),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => registry.resolve(
          ModelRef(
            providerId: BuiltInLlmCatalog.deepSeek,
            modelId: BuiltInLlmCatalog.kimiK26,
          ),
        ),
        throwsA(isA<LlmException>()),
      );
    });
  });
}

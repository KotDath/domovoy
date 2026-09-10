import 'capabilities.dart';
import 'generation.dart';
import 'identifiers.dart';
import 'provider.dart';
import 'registry.dart';

abstract final class BuiltInLlmCatalog {
  static final ProviderId deepSeek = ProviderId('deepseek');
  static final ProviderId moonshotAi = ProviderId('moonshotai');
  static final ProviderId openAi = ProviderId('openai');

  static final ModelId deepSeekV4Flash = ModelId('deepseek-v4-flash');
  static final ModelId deepSeekV4Pro = ModelId('deepseek-v4-pro');
  static final ModelId kimiK26 = ModelId('kimi-k2.6');
  static final ModelId kimiK27Code = ModelId('kimi-k2.7-code');
  static final ModelId kimiK3 = ModelId('kimi-k3');
  static final ModelId gpt4oMini = ModelId('gpt-4o-mini');
  static final ModelId gpt5Mini = ModelId('gpt-5-mini');
  static final ModelId gpt54 = ModelId('gpt-5.4');

  static const deepSeekDialectId = 'deepseek_chat_completions';
  static const moonshotDialectId = 'moonshot_chat_completions';
  static const openAiDialectId = 'openai_responses';

  static const deepSeekApiKeyEnvironmentVariable = 'DEEPSEEK_API_KEY';
  static const moonshotApiKeyEnvironmentVariable = 'MOONSHOT_API_KEY';
  static const openAiApiKeyEnvironmentVariable = 'OPENAI_API_KEY';

  static const deepSeekEfforts = <ReasoningEffort>[
    ReasoningEffort.low,
    ReasoningEffort.medium,
    ReasoningEffort.high,
    ReasoningEffort.max,
  ];

  static const kimiK3Efforts = <ReasoningEffort>[
    ReasoningEffort.low,
    ReasoningEffort.high,
    ReasoningEffort.max,
  ];

  static const gpt5MiniEfforts = <ReasoningEffort>[
    ReasoningEffort.low,
    ReasoningEffort.medium,
    ReasoningEffort.high,
  ];

  static const gpt54Efforts = <ReasoningEffort>[
    ReasoningEffort.low,
    ReasoningEffort.medium,
    ReasoningEffort.high,
    ReasoningEffort.max,
  ];

  static final LlmProviderProfile deepSeekProfile = LlmProviderProfile(
    id: deepSeek,
    wireFamily: LlmWireFamily.openaiChatCompletions,
    endpoint: Uri.parse('https://api.deepseek.com/chat/completions'),
    environmentVariable: deepSeekApiKeyEnvironmentVariable,
    dialectId: deepSeekDialectId,
  );

  static final LlmProviderProfile moonshotAiProfile = LlmProviderProfile(
    id: moonshotAi,
    wireFamily: LlmWireFamily.openaiChatCompletions,
    endpoint: Uri.parse('https://api.moonshot.ai/v1/chat/completions'),
    environmentVariable: moonshotApiKeyEnvironmentVariable,
    dialectId: moonshotDialectId,
  );

  static final LlmProviderProfile openAiProfile = LlmProviderProfile(
    id: openAi,
    wireFamily: LlmWireFamily.openaiResponses,
    endpoint: Uri.parse('https://api.openai.com/v1/responses'),
    environmentVariable: openAiApiKeyEnvironmentVariable,
    dialectId: openAiDialectId,
  );

  static final ModelCapabilities deepSeekCapabilities = ModelCapabilities(
    supportsTextInput: true,
    reasoning: ModelReasoningCapability.optional,
    supportsTools: true,
    supportsTemperature: true,
    selectableEfforts: deepSeekEfforts,
  );

  static final ModelCapabilities moonshotK26Capabilities = ModelCapabilities(
    supportsTextInput: true,
    reasoning: ModelReasoningCapability.optional,
    supportsTools: true,
    supportsTemperature: false,
  );

  static final ModelCapabilities moonshotK27Capabilities = ModelCapabilities(
    supportsTextInput: true,
    reasoning: ModelReasoningCapability.required,
    supportsTools: true,
    supportsTemperature: false,
  );

  static final ModelCapabilities moonshotK3Capabilities = ModelCapabilities(
    supportsTextInput: true,
    reasoning: ModelReasoningCapability.required,
    supportsTools: true,
    supportsTemperature: false,
    selectableEfforts: kimiK3Efforts,
  );

  static final ModelCapabilities gpt4oMiniCapabilities = ModelCapabilities(
    supportsTextInput: true,
    reasoning: ModelReasoningCapability.unsupported,
    supportsTools: true,
    supportsTemperature: true,
  );

  static final ModelCapabilities gpt5MiniCapabilities = ModelCapabilities(
    supportsTextInput: true,
    reasoning: ModelReasoningCapability.required,
    supportsTools: true,
    supportsTemperature: true,
    selectableEfforts: gpt5MiniEfforts,
  );

  static final ModelCapabilities gpt54Capabilities = ModelCapabilities(
    supportsTextInput: true,
    reasoning: ModelReasoningCapability.optional,
    supportsTools: true,
    supportsTemperature: true,
    selectableEfforts: gpt54Efforts,
  );

  static final LlmModel deepSeekV4FlashModel = LlmModel(
    providerId: deepSeek,
    id: deepSeekV4Flash,
    name: 'DeepSeek V4 Flash',
    wireFamily: LlmWireFamily.openaiChatCompletions,
    capabilities: deepSeekCapabilities,
    contextBound: 1048576,
    outputBound: 384000,
  );

  static final LlmModel deepSeekV4ProModel = LlmModel(
    providerId: deepSeek,
    id: deepSeekV4Pro,
    name: 'DeepSeek V4 Pro',
    wireFamily: LlmWireFamily.openaiChatCompletions,
    capabilities: deepSeekCapabilities,
    contextBound: 1048576,
    outputBound: 384000,
  );

  static final LlmModel kimiK26Model = LlmModel(
    providerId: moonshotAi,
    id: kimiK26,
    name: 'Kimi K2.6',
    wireFamily: LlmWireFamily.openaiChatCompletions,
    capabilities: moonshotK26Capabilities,
    contextBound: 262144,
    outputBound: 262144,
  );

  static final LlmModel kimiK27CodeModel = LlmModel(
    providerId: moonshotAi,
    id: kimiK27Code,
    name: 'Kimi K2.7 Code',
    wireFamily: LlmWireFamily.openaiChatCompletions,
    capabilities: moonshotK27Capabilities,
    contextBound: 262144,
    outputBound: 262144,
  );

  static final LlmModel kimiK3Model = LlmModel(
    providerId: moonshotAi,
    id: kimiK3,
    name: 'Kimi K3',
    wireFamily: LlmWireFamily.openaiChatCompletions,
    capabilities: moonshotK3Capabilities,
    contextBound: 1048576,
    outputBound: 1048576,
  );

  static final LlmModel gpt4oMiniModel = LlmModel(
    providerId: openAi,
    id: gpt4oMini,
    name: 'GPT-4o mini',
    wireFamily: LlmWireFamily.openaiResponses,
    capabilities: gpt4oMiniCapabilities,
    contextBound: 128000,
    outputBound: 16384,
  );

  static final LlmModel gpt5MiniModel = LlmModel(
    providerId: openAi,
    id: gpt5Mini,
    name: 'GPT-5 mini',
    wireFamily: LlmWireFamily.openaiResponses,
    capabilities: gpt5MiniCapabilities,
    contextBound: 400000,
    outputBound: 128000,
  );

  static final LlmModel gpt54Model = LlmModel(
    providerId: openAi,
    id: gpt54,
    name: 'GPT-5.4',
    wireFamily: LlmWireFamily.openaiResponses,
    capabilities: gpt54Capabilities,
    contextBound: 1050000,
    outputBound: 128000,
  );

  static List<LlmProviderProfile> get profiles => <LlmProviderProfile>[
    deepSeekProfile,
    moonshotAiProfile,
    openAiProfile,
  ];

  static List<LlmModel> get models => <LlmModel>[
    deepSeekV4FlashModel,
    deepSeekV4ProModel,
    kimiK26Model,
    kimiK27CodeModel,
    kimiK3Model,
    gpt4oMiniModel,
    gpt5MiniModel,
    gpt54Model,
  ];

  static void registerInto(LlmProviderRegistry registry) {
    for (final profile in profiles) {
      registry.registerProfile(profile);
    }
    for (final model in models) {
      registry.registerModel(model);
    }
  }
}

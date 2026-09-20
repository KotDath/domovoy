import '../../../core/llm/identifiers.dart';
import '../../../core/llm/provider.dart';

/// App-owned destinations. Metadata refresh may change models, never these URLs.
enum ApiKeyProviderProtocol {
  chatCompletions,
  responses,
  anthropicMessages,
  geminiGenerateContent,
}

/// How a provider's catalog models express a reasoning level on the wire.
/// Only providers whose format this app can encode are enabled; everything
/// else keeps reasoning unavailable for discovered models.
enum ApiKeyProviderReasoningFormat {
  none,

  /// Top-level `reasoning_effort`, as used by plain OpenAI-compatible hosts.
  openAiEffort,

  /// `thinking: {type}` plus `reasoning_effort`.
  deepSeekThinking,

  /// `thinking: {type, clear_thinking}` plus `reasoning_effort`.
  zaiThinking,

  /// Top-level `enable_thinking` plus `reasoning_effort`.
  qwenThinking,

  /// Nested `reasoning: {effort}`.
  openRouterReasoning,

  /// Nested `reasoning: {effort}`, only for an explicit level.
  antLingReasoning,

  /// Nested `reasoning: {enabled}` plus `reasoning_effort`.
  togetherReasoning,
}

final class ApiKeyProviderSpec {
  const ApiKeyProviderSpec({
    required this.id,
    required this.name,
    required this.environmentVariable,
    required this.endpoint,
    required this.metadataId,
    required this.protocol,
    this.modelsEndpoint,
    this.publicModels = false,
    this.sessionAffinityHeader,
    this.reasoningFormat = ApiKeyProviderReasoningFormat.none,
  });

  final String id;
  final String name;
  final String environmentVariable;
  final String endpoint;
  final String metadataId;
  final ApiKeyProviderProtocol protocol;
  final String? modelsEndpoint;
  final bool publicModels;

  /// Gateways such as OpenCode Zen require a per-conversation session header
  /// for request routing. Null for ordinary providers.
  final String? sessionAffinityHeader;

  /// Wire format for reasoning levels of this provider's catalog models.
  final ApiKeyProviderReasoningFormat reasoningFormat;

  LlmWireFamily get wireFamily => switch (protocol) {
    ApiKeyProviderProtocol.chatCompletions =>
      LlmWireFamily.openaiChatCompletions,
    ApiKeyProviderProtocol.responses => LlmWireFamily.openaiResponses,
    ApiKeyProviderProtocol.anthropicMessages => LlmWireFamily.anthropicMessages,
    ApiKeyProviderProtocol.geminiGenerateContent =>
      LlmWireFamily.geminiGenerateContent,
  };

  LlmProviderProfile get profile => LlmProviderProfile(
    id: ProviderId(id),
    displayName: name,
    wireFamily: wireFamily,
    endpoint: Uri.parse(endpoint),
    environmentVariable: environmentVariable,
    dialectId: 'builtin.$id.${protocol.name}',
  );
}

abstract final class ApiKeyProviderManifest {
  static const entries = <ApiKeyProviderSpec>[
    ApiKeyProviderSpec(
      id: 'deepseek',
      name: 'DeepSeek',
      environmentVariable: 'DEEPSEEK_API_KEY',
      endpoint: 'https://api.deepseek.com/chat/completions',
      metadataId: 'deepseek',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.deepSeekThinking,
      modelsEndpoint: 'https://api.deepseek.com/models',
    ),
    ApiKeyProviderSpec(
      id: 'moonshotai',
      name: 'Moonshot AI',
      environmentVariable: 'MOONSHOT_API_KEY',
      endpoint: 'https://api.moonshot.ai/v1/chat/completions',
      metadataId: 'moonshotai',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      modelsEndpoint: 'https://api.moonshot.ai/v1/models',
    ),
    ApiKeyProviderSpec(
      id: 'openai',
      name: 'OpenAI',
      environmentVariable: 'OPENAI_API_KEY',
      endpoint: 'https://api.openai.com/v1/responses',
      metadataId: 'openai',
      protocol: ApiKeyProviderProtocol.responses,
      modelsEndpoint: 'https://api.openai.com/v1/models',
    ),
    ApiKeyProviderSpec(
      id: 'anthropic',
      name: 'Anthropic',
      environmentVariable: 'ANTHROPIC_API_KEY',
      endpoint: 'https://api.anthropic.com/v1/messages',
      metadataId: 'anthropic',
      protocol: ApiKeyProviderProtocol.anthropicMessages,
      modelsEndpoint: 'https://api.anthropic.com/v1/models',
    ),
    ApiKeyProviderSpec(
      id: 'google',
      name: 'Google Gemini',
      environmentVariable: 'GEMINI_API_KEY',
      endpoint: 'https://generativelanguage.googleapis.com/v1beta/models',
      metadataId: 'google',
      protocol: ApiKeyProviderProtocol.geminiGenerateContent,
      modelsEndpoint: 'https://generativelanguage.googleapis.com/v1beta/models',
    ),
    ApiKeyProviderSpec(
      id: 'groq',
      name: 'Groq',
      environmentVariable: 'GROQ_API_KEY',
      endpoint: 'https://api.groq.com/openai/v1/chat/completions',
      metadataId: 'groq',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
      modelsEndpoint: 'https://api.groq.com/openai/v1/models',
    ),
    ApiKeyProviderSpec(
      id: 'cerebras',
      name: 'Cerebras',
      environmentVariable: 'CEREBRAS_API_KEY',
      endpoint: 'https://api.cerebras.ai/v1/chat/completions',
      metadataId: 'cerebras',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
      modelsEndpoint: 'https://api.cerebras.ai/v1/models',
    ),
    ApiKeyProviderSpec(
      id: 'xai',
      name: 'xAI',
      environmentVariable: 'XAI_API_KEY',
      endpoint: 'https://api.x.ai/v1/responses',
      metadataId: 'xai',
      protocol: ApiKeyProviderProtocol.responses,
      modelsEndpoint: 'https://api.x.ai/v1/models',
    ),
    ApiKeyProviderSpec(
      id: 'mistral',
      name: 'Mistral',
      environmentVariable: 'MISTRAL_API_KEY',
      endpoint: 'https://api.mistral.ai/v1/chat/completions',
      metadataId: 'mistral',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
      modelsEndpoint: 'https://api.mistral.ai/v1/models',
    ),
    ApiKeyProviderSpec(
      id: 'openrouter',
      name: 'OpenRouter',
      environmentVariable: 'OPENROUTER_API_KEY',
      endpoint: 'https://openrouter.ai/api/v1/chat/completions',
      metadataId: 'openrouter',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openRouterReasoning,
      modelsEndpoint: 'https://openrouter.ai/api/v1/models',
      publicModels: true,
    ),
    ApiKeyProviderSpec(
      id: 'together',
      name: 'Together AI',
      environmentVariable: 'TOGETHER_API_KEY',
      endpoint: 'https://api.together.ai/v1/chat/completions',
      metadataId: 'togetherai',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.togetherReasoning,
      modelsEndpoint: 'https://api.together.ai/v1/models',
    ),
    ApiKeyProviderSpec(
      id: 'fireworks',
      name: 'Fireworks AI',
      environmentVariable: 'FIREWORKS_API_KEY',
      endpoint: 'https://api.fireworks.ai/inference/v1/chat/completions',
      metadataId: 'fireworks-ai',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
      modelsEndpoint:
          'https://api.fireworks.ai/v1/accounts/fireworks/models?filter=supports_serverless%3Dtrue&pageSize=200',
    ),
    ApiKeyProviderSpec(
      id: 'perplexity',
      name: 'Perplexity',
      environmentVariable: 'PERPLEXITY_API_KEY',
      endpoint: 'https://api.perplexity.ai/chat/completions',
      metadataId: 'perplexity',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
    ),
    ApiKeyProviderSpec(
      id: 'minimax',
      name: 'MiniMax',
      environmentVariable: 'MINIMAX_API_KEY',
      endpoint: 'https://api.minimax.io/anthropic/v1/messages',
      metadataId: 'minimax',
      protocol: ApiKeyProviderProtocol.anthropicMessages,
    ),
    ApiKeyProviderSpec(
      id: 'zai',
      name: 'Z.AI Coding Plan',
      environmentVariable: 'ZAI_API_KEY',
      endpoint: 'https://api.z.ai/api/coding/paas/v4/chat/completions',
      metadataId: 'zai',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.zaiThinking,
    ),
    ApiKeyProviderSpec(
      id: 'huggingface',
      name: 'Hugging Face',
      environmentVariable: 'HF_TOKEN',
      endpoint: 'https://router.huggingface.co/v1/chat/completions',
      metadataId: 'huggingface',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
      modelsEndpoint: 'https://router.huggingface.co/v1/models',
      publicModels: true,
    ),
    ApiKeyProviderSpec(
      id: 'moonshotai-cn',
      name: 'Moonshot AI China',
      environmentVariable: 'MOONSHOT_API_KEY',
      endpoint: 'https://api.moonshot.cn/v1/chat/completions',
      metadataId: 'moonshotai-cn',
      protocol: ApiKeyProviderProtocol.chatCompletions,
    ),
    ApiKeyProviderSpec(
      id: 'minimax-cn',
      name: 'MiniMax China',
      environmentVariable: 'MINIMAX_CN_API_KEY',
      endpoint: 'https://api.minimaxi.com/anthropic/v1/messages',
      metadataId: 'minimax-cn',
      protocol: ApiKeyProviderProtocol.anthropicMessages,
    ),
    ApiKeyProviderSpec(
      id: 'kimi-coding',
      name: 'Kimi Coding',
      environmentVariable: 'KIMI_API_KEY',
      endpoint: 'https://api.kimi.com/coding/v1/messages',
      metadataId: 'kimi-for-coding',
      protocol: ApiKeyProviderProtocol.anthropicMessages,
    ),
    ApiKeyProviderSpec(
      id: 'vercel-ai-gateway',
      name: 'Vercel AI Gateway',
      environmentVariable: 'AI_GATEWAY_API_KEY',
      endpoint: 'https://ai-gateway.vercel.sh/v1/messages',
      metadataId: 'vercel',
      protocol: ApiKeyProviderProtocol.anthropicMessages,
    ),
    ApiKeyProviderSpec(
      id: 'baseten',
      name: 'Baseten',
      environmentVariable: 'BASETEN_API_KEY',
      endpoint: 'https://inference.baseten.co/v1/chat/completions',
      metadataId: 'baseten',
      protocol: ApiKeyProviderProtocol.chatCompletions,
    ),
    ApiKeyProviderSpec(
      id: 'nvidia',
      name: 'NVIDIA',
      environmentVariable: 'NVIDIA_API_KEY',
      endpoint: 'https://integrate.api.nvidia.com/v1/chat/completions',
      metadataId: 'nvidia',
      protocol: ApiKeyProviderProtocol.chatCompletions,
    ),
    ApiKeyProviderSpec(
      id: 'xiaomi',
      name: 'Xiaomi MiMo',
      environmentVariable: 'XIAOMI_API_KEY',
      endpoint: 'https://api.xiaomimimo.com/v1/chat/completions',
      metadataId: 'xiaomi',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
    ),
    ApiKeyProviderSpec(
      id: 'xiaomi-token-plan-ams',
      name: 'Xiaomi Token Plan AMS',
      environmentVariable: 'XIAOMI_TOKEN_PLAN_AMS_API_KEY',
      endpoint: 'https://token-plan-ams.xiaomimimo.com/v1/chat/completions',
      metadataId: 'xiaomi-token-plan-ams',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
    ),
    ApiKeyProviderSpec(
      id: 'xiaomi-token-plan-cn',
      name: 'Xiaomi Token Plan China',
      environmentVariable: 'XIAOMI_TOKEN_PLAN_CN_API_KEY',
      endpoint: 'https://token-plan-cn.xiaomimimo.com/v1/chat/completions',
      metadataId: 'xiaomi-token-plan-cn',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
    ),
    ApiKeyProviderSpec(
      id: 'xiaomi-token-plan-sgp',
      name: 'Xiaomi Token Plan SGP',
      environmentVariable: 'XIAOMI_TOKEN_PLAN_SGP_API_KEY',
      endpoint: 'https://token-plan-sgp.xiaomimimo.com/v1/chat/completions',
      metadataId: 'xiaomi-token-plan-sgp',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
    ),
    ApiKeyProviderSpec(
      id: 'zai-coding-cn',
      name: 'Z.AI Coding China',
      environmentVariable: 'ZAI_CODING_CN_API_KEY',
      endpoint: 'https://open.bigmodel.cn/api/coding/paas/v4/chat/completions',
      metadataId: 'zai-coding-plan',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.zaiThinking,
    ),
    ApiKeyProviderSpec(
      id: 'ant-ling',
      name: 'Ant Ling',
      environmentVariable: 'ANT_LING_API_KEY',
      endpoint: 'https://api.ant-ling.com/v1/chat/completions',
      metadataId: 'ant-ling',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.antLingReasoning,
    ),
    ApiKeyProviderSpec(
      id: 'qwen-token-plan',
      name: 'Qwen Token Plan',
      environmentVariable: 'QWEN_TOKEN_PLAN_API_KEY',
      endpoint:
          'https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/chat/completions',
      metadataId: 'alibaba-token-plan',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.qwenThinking,
    ),
    ApiKeyProviderSpec(
      id: 'qwen-token-plan-cn',
      name: 'Qwen Token Plan China',
      environmentVariable: 'QWEN_TOKEN_PLAN_CN_API_KEY',
      endpoint:
          'https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions',
      metadataId: 'alibaba-token-plan-cn',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.qwenThinking,
    ),
    // OpenCode Zen is a multi-protocol gateway. Only the Chat Completions
    // slice is wired up here; its Responses, Anthropic, and Google models are
    // filtered out during discovery (see ProviderModelCatalog).
    ApiKeyProviderSpec(
      id: 'opencode',
      name: 'OpenCode Zen',
      environmentVariable: 'OPENCODE_API_KEY',
      endpoint: 'https://opencode.ai/zen/v1/chat/completions',
      metadataId: 'opencode',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
      modelsEndpoint: 'https://opencode.ai/zen/v1/models',
      sessionAffinityHeader: 'x-opencode-session',
    ),
    ApiKeyProviderSpec(
      id: 'opencode-go',
      name: 'OpenCode Go',
      environmentVariable: 'OPENCODE_API_KEY',
      endpoint: 'https://opencode.ai/zen/go/v1/chat/completions',
      metadataId: 'opencode-go',
      protocol: ApiKeyProviderProtocol.chatCompletions,
      reasoningFormat: ApiKeyProviderReasoningFormat.openAiEffort,
      modelsEndpoint: 'https://opencode.ai/zen/go/v1/models',
      sessionAffinityHeader: 'x-opencode-session',
    ),
  ];

  static ApiKeyProviderSpec? find(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }
}

import '../../../core/llm/capabilities.dart';
import '../../../core/llm/catalog.dart';
import '../../../core/llm/errors.dart';
import '../../../core/llm/generation.dart';
import '../../../core/llm/identifiers.dart';
import '../../../core/llm/usage.dart';
import '../usage_extraction.dart';

enum ChatCompletionsReasoningProtocol {
  none,
  openAiEffort,
  catalogDeepSeekThinking,
  zaiThinking,
  qwenThinking,
  openRouterReasoning,
  antLingReasoning,
  togetherReasoning,
  deepSeekThinking,
  moonshotK26,
  moonshotK27Code,
  moonshotK3,
}

enum ChatCompletionsOutputTokenField { maxTokens, maxCompletionTokens }

final class ChatCompletionsDialect {
  const ChatCompletionsDialect({
    required this.reasoningDeltaField,
    this.answerDeltaField = 'content',
    required this.reasoningProtocol,
    this.outputTokenField = ChatCompletionsOutputTokenField.maxTokens,
    this.includeReasoningContentInHistory = true,
    this.usage = const ChatCompletionsUsageDialect(),
  });

  static const deepSeek = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.deepSeekThinking,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
    usage: ChatCompletionsUsageDialect.deepSeek,
  );

  static const moonshotK26 = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.moonshotK26,
    outputTokenField: ChatCompletionsOutputTokenField.maxCompletionTokens,
  );

  static const moonshotK27Code = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.moonshotK27Code,
    outputTokenField: ChatCompletionsOutputTokenField.maxCompletionTokens,
  );

  static const moonshotK3 = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.moonshotK3,
    outputTokenField: ChatCompletionsOutputTokenField.maxCompletionTokens,
  );

  static const generic = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.none,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
    includeReasoningContentInHistory: false,
  );

  /// Plain OpenAI-compatible hosts that take a top-level `reasoning_effort`
  /// and stream reasoning back as `reasoning_content`.
  static const openAiReasoningEffort = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.openAiEffort,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
    includeReasoningContentInHistory: true,
  );

  /// Catalog models of the DeepSeek API: `thinking: {type}` plus an explicit
  /// `reasoning_effort`. Unlike [deepSeek], an "auto" level sends no effort.
  static const catalogDeepSeekThinking = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.catalogDeepSeekThinking,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
    includeReasoningContentInHistory: true,
  );

  static const zaiThinking = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.zaiThinking,
    outputTokenField: ChatCompletionsOutputTokenField.maxCompletionTokens,
    includeReasoningContentInHistory: true,
  );

  static const qwenThinking = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.qwenThinking,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
    includeReasoningContentInHistory: true,
  );

  // OpenRouter and Ant Ling stream reasoning under their own structured
  // fields and do not take `reasoning_content` back, so history replay stays
  // off for them.
  static const openRouterReasoning = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.openRouterReasoning,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
    includeReasoningContentInHistory: false,
  );

  static const antLingReasoning = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.antLingReasoning,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
    includeReasoningContentInHistory: false,
  );

  static const togetherReasoning = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.togetherReasoning,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
    includeReasoningContentInHistory: true,
  );

  final String reasoningDeltaField;
  final String answerDeltaField;
  final ChatCompletionsReasoningProtocol reasoningProtocol;
  final ChatCompletionsOutputTokenField outputTokenField;
  final bool includeReasoningContentInHistory;
  final ChatCompletionsUsageDialect usage;

  String get outputTokenFieldName => switch (outputTokenField) {
    ChatCompletionsOutputTokenField.maxTokens => 'max_tokens',
    ChatCompletionsOutputTokenField.maxCompletionTokens =>
      'max_completion_tokens',
  };

  void applyReasoning(
    Map<String, Object?> body,
    LlmGenerationConfig generation, [
    ModelCapabilities? capabilities,
  ]) {
    final mode = generation.reasoningMode;
    final effort = generation.reasoningEffort;
    switch (reasoningProtocol) {
      case ChatCompletionsReasoningProtocol.none:
        if (mode == ReasoningMode.enabled || effort.isExplicit) {
          throwLlm(
            LlmErrorKind.configuration,
            'This compatible profile does not support reasoning controls.',
          );
        }
        return;
      case ChatCompletionsReasoningProtocol.openAiEffort:
        if (mode == ReasoningMode.enabled) {
          // "Авто" (the model default) sends no explicit level and lets the
          // provider choose.
          final value = _effortValue(effort);
          if (value != null) body['reasoning_effort'] = value;
        } else if (capabilities?.reasoning ==
            ModelReasoningCapability.optional) {
          // Optional capability is granted only when the catalog declared an
          // explicit "none" effort, which is the provider's off value.
          body['reasoning_effort'] = 'none';
        }
        return;
      case ChatCompletionsReasoningProtocol.catalogDeepSeekThinking:
        if (mode == ReasoningMode.enabled) {
          body['thinking'] = const <String, String>{'type': 'enabled'};
          final value = _effortValue(effort);
          if (value != null) body['reasoning_effort'] = value;
        } else if (capabilities?.reasoning ==
            ModelReasoningCapability.optional) {
          body['thinking'] = const <String, String>{'type': 'disabled'};
        }
        return;
      case ChatCompletionsReasoningProtocol.zaiThinking:
        if (mode == ReasoningMode.enabled) {
          body['thinking'] = const <String, Object?>{
            'type': 'enabled',
            'clear_thinking': false,
          };
          final value = _effortValue(effort);
          if (value != null) body['reasoning_effort'] = value;
        } else {
          body['thinking'] = const <String, String>{'type': 'disabled'};
        }
        return;
      case ChatCompletionsReasoningProtocol.qwenThinking:
        body['enable_thinking'] = mode == ReasoningMode.enabled;
        if (mode == ReasoningMode.enabled) {
          final value = _effortValue(effort);
          if (value != null) body['reasoning_effort'] = value;
        }
        return;
      case ChatCompletionsReasoningProtocol.openRouterReasoning:
      case ChatCompletionsReasoningProtocol.antLingReasoning:
        if (mode == ReasoningMode.enabled) {
          final value = _effortValue(effort);
          if (value != null) {
            body['reasoning'] = <String, Object?>{'effort': value};
          }
        } else if (reasoningProtocol ==
                ChatCompletionsReasoningProtocol.openRouterReasoning &&
            capabilities?.reasoning == ModelReasoningCapability.optional) {
          body['reasoning'] = const <String, Object?>{'effort': 'none'};
        }
        return;
      case ChatCompletionsReasoningProtocol.togetherReasoning:
        body['reasoning'] = <String, Object?>{
          'enabled': mode == ReasoningMode.enabled,
        };
        if (mode == ReasoningMode.enabled) {
          final value = _effortValue(effort);
          if (value != null) body['reasoning_effort'] = value;
        }
        return;
      case ChatCompletionsReasoningProtocol.deepSeekThinking:
        if (mode == ReasoningMode.enabled) {
          body['thinking'] = const <String, String>{'type': 'enabled'};
          body['reasoning_effort'] = switch (effort) {
            ReasoningEffort.low => 'low',
            ReasoningEffort.medium => 'high',
            ReasoningEffort.high => 'high',
            ReasoningEffort.max => 'max',
            ReasoningEffort.modelDefault => 'high',
          };
        } else {
          body['thinking'] = const <String, String>{'type': 'disabled'};
        }
      case ChatCompletionsReasoningProtocol.moonshotK26:
        if (effort.isExplicit) {
          throwLlm(
            LlmErrorKind.configuration,
            'kimi-k2.6 does not accept explicit reasoning effort.',
          );
        }
        body['thinking'] = <String, String>{
          'type': mode == ReasoningMode.enabled ? 'enabled' : 'disabled',
        };
      case ChatCompletionsReasoningProtocol.moonshotK27Code:
        if (mode == ReasoningMode.disabled) {
          throwLlm(
            LlmErrorKind.configuration,
            'kimi-k2.7-code cannot disable reasoning.',
          );
        }
        if (effort.isExplicit) {
          throwLlm(
            LlmErrorKind.configuration,
            'kimi-k2.7-code does not accept explicit reasoning effort.',
          );
        }
        body['thinking'] = const <String, String>{
          'type': 'enabled',
          'keep': 'all',
        };
      case ChatCompletionsReasoningProtocol.moonshotK3:
        if (mode == ReasoningMode.disabled) {
          throwLlm(
            LlmErrorKind.configuration,
            'kimi-k3 cannot disable reasoning.',
          );
        }
        if (effort == ReasoningEffort.medium) {
          throwLlm(
            LlmErrorKind.configuration,
            'kimi-k3 does not accept medium reasoning effort.',
          );
        }
        body['reasoning_effort'] = switch (effort) {
          ReasoningEffort.low => 'low',
          ReasoningEffort.high => 'high',
          ReasoningEffort.max => 'max',
          ReasoningEffort.modelDefault => 'high',
          ReasoningEffort.medium => 'high',
        };
    }
  }

  static String? _effortValue(ReasoningEffort effort) => switch (effort) {
    ReasoningEffort.low => 'low',
    ReasoningEffort.medium => 'medium',
    ReasoningEffort.high => 'high',
    ReasoningEffort.max => 'max',
    ReasoningEffort.modelDefault => null,
  };

  static ChatCompletionsDialect forBuiltInModel(ModelId modelId) {
    if (modelId == BuiltInLlmCatalog.deepSeekFlash ||
        modelId == BuiltInLlmCatalog.deepSeekV4Flash ||
        modelId == BuiltInLlmCatalog.deepSeekV4Pro) {
      return deepSeek;
    }
    if (modelId == BuiltInLlmCatalog.kimiK26) {
      return moonshotK26;
    }
    if (modelId == BuiltInLlmCatalog.kimiK27Code) {
      return moonshotK27Code;
    }
    if (modelId == BuiltInLlmCatalog.kimiK3) {
      return moonshotK3;
    }
    return generic;
  }
}

/// Typed wire semantics for Chat Completions usage extraction.
final class ChatCompletionsUsageDialect {
  const ChatCompletionsUsageDialect({
    this.inputPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['prompt_tokens']),
      LlmUsageFieldPath(<String>['input_tokens']),
    ],
    this.outputPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['completion_tokens']),
      LlmUsageFieldPath(<String>['output_tokens']),
    ],
    this.overallPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['total_tokens']),
      LlmUsageFieldPath(<String>['total']),
    ],
    this.cacheReadPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['prompt_cache_hit_tokens']),
      LlmUsageFieldPath(<String>['cached_tokens']),
      LlmUsageFieldPath(<String>['prompt_tokens_details', 'cached_tokens']),
    ],
    this.cacheWritePaths = const <LlmUsageFieldPath>[],
    this.cacheMissPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['prompt_cache_miss_tokens']),
    ],
    this.reasoningPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['reasoning_tokens']),
      LlmUsageFieldPath(<String>[
        'completion_tokens_details',
        'reasoning_tokens',
      ]),
      LlmUsageFieldPath(<String>['output_tokens_details', 'reasoning_tokens']),
    ],
    this.inputIncludesCacheRead = true,
    this.inputIncludesCacheWrite = false,
    this.outputIncludesReasoning = true,
    this.cacheMissPartitionsInput = false,
  });

  static const deepSeek = ChatCompletionsUsageDialect(
    cacheMissPartitionsInput: true,
  );

  final List<LlmUsageFieldPath> inputPaths;
  final List<LlmUsageFieldPath> outputPaths;
  final List<LlmUsageFieldPath> overallPaths;
  final List<LlmUsageFieldPath> cacheReadPaths;
  final List<LlmUsageFieldPath> cacheWritePaths;
  final List<LlmUsageFieldPath> cacheMissPaths;
  final List<LlmUsageFieldPath> reasoningPaths;
  final bool inputIncludesCacheRead;
  final bool inputIncludesCacheWrite;
  final bool outputIncludesReasoning;
  final bool cacheMissPartitionsInput;

  LlmUsageNormalizationSemantics get normalizationSemantics =>
      LlmUsageNormalizationSemantics(
        inputIncludesCacheRead: inputIncludesCacheRead,
        inputIncludesCacheWrite: inputIncludesCacheWrite,
        outputIncludesReasoning: outputIncludesReasoning,
        cacheMissPartitionsInput: cacheMissPartitionsInput,
      );
}

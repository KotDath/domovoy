import '../../../core/llm/catalog.dart';
import '../../../core/llm/errors.dart';
import '../../../core/llm/generation.dart';
import '../../../core/llm/identifiers.dart';

enum ChatCompletionsReasoningProtocol {
  none,
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
  });

  static const deepSeek = ChatCompletionsDialect(
    reasoningDeltaField: 'reasoning_content',
    reasoningProtocol: ChatCompletionsReasoningProtocol.deepSeekThinking,
    outputTokenField: ChatCompletionsOutputTokenField.maxTokens,
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

  final String reasoningDeltaField;
  final String answerDeltaField;
  final ChatCompletionsReasoningProtocol reasoningProtocol;
  final ChatCompletionsOutputTokenField outputTokenField;
  final bool includeReasoningContentInHistory;

  String get outputTokenFieldName => switch (outputTokenField) {
    ChatCompletionsOutputTokenField.maxTokens => 'max_tokens',
    ChatCompletionsOutputTokenField.maxCompletionTokens =>
      'max_completion_tokens',
  };

  void applyReasoning(
    Map<String, Object?> body,
    LlmGenerationConfig generation,
  ) {
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

  static ChatCompletionsDialect forBuiltInModel(ModelId modelId) {
    if (modelId == BuiltInLlmCatalog.deepSeekV4Flash ||
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

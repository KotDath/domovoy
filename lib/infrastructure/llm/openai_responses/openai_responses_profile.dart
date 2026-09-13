import '../../../core/llm/capabilities.dart';
import '../../../core/llm/catalog.dart';
import '../../../core/llm/errors.dart';
import '../../../core/llm/identifiers.dart';
import '../../../core/llm/provider.dart';
import '../../../core/llm/usage.dart';
import '../usage_extraction.dart';

final class OpenAiResponsesProfile {
  OpenAiResponsesProfile({
    required this.snapshot,
    required List<LlmModel> models,
    this.usage = const OpenAiResponsesUsageDialect(),
  }) : models = List<LlmModel>.unmodifiable(List<LlmModel>.from(models)) {
    if (this.models.isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'An OpenAI Responses profile must declare explicit model entries.',
      );
    }
    if (snapshot.wireFamily != LlmWireFamily.openaiResponses) {
      throwLlm(
        LlmErrorKind.configuration,
        'OpenAI Responses profiles must use the Responses wire family.',
      );
    }
    final seen = <String>{};
    for (final model in this.models) {
      if (model.providerId != snapshot.id) {
        throwLlm(
          LlmErrorKind.configuration,
          'Model ${model.id.value} does not belong to provider ${snapshot.id.value}.',
        );
      }
      if (model.wireFamily != LlmWireFamily.openaiResponses) {
        throwLlm(
          LlmErrorKind.configuration,
          'Model ${model.id.value} must declare the Responses wire family.',
        );
      }
      if (!seen.add(model.id.value)) {
        throwLlm(
          LlmErrorKind.configuration,
          'Duplicate model ${model.id.value} in Responses profile.',
        );
      }
    }
  }

  factory OpenAiResponsesProfile.builtIn() {
    return OpenAiResponsesProfile(
      snapshot: BuiltInLlmCatalog.openAiProfile,
      models: <LlmModel>[
        BuiltInLlmCatalog.gpt4oMiniModel,
        BuiltInLlmCatalog.gpt5MiniModel,
        BuiltInLlmCatalog.gpt54Model,
      ],
    );
  }

  final LlmProviderProfile snapshot;
  final List<LlmModel> models;
  final OpenAiResponsesUsageDialect usage;

  ProviderId get id => snapshot.id;

  LlmModel requireModel(ModelId id) {
    for (final model in models) {
      if (model.id == id) {
        return model;
      }
    }
    throwLlm(
      LlmErrorKind.configuration,
      'Model ${id.value} is not registered on provider ${snapshot.id.value}.',
    );
  }
}

/// Typed wire semantics for Responses usage extraction.
final class OpenAiResponsesUsageDialect {
  const OpenAiResponsesUsageDialect({
    this.inputPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['input_tokens']),
      LlmUsageFieldPath(<String>['prompt_tokens']),
    ],
    this.outputPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['output_tokens']),
      LlmUsageFieldPath(<String>['completion_tokens']),
    ],
    this.overallPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['total_tokens']),
      LlmUsageFieldPath(<String>['total']),
    ],
    this.cacheReadPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['input_tokens_details', 'cached_tokens']),
    ],
    this.cacheWritePaths = const <LlmUsageFieldPath>[],
    this.reasoningPaths = const <LlmUsageFieldPath>[
      LlmUsageFieldPath(<String>['output_tokens_details', 'reasoning_tokens']),
    ],
    this.inputIncludesCacheRead = true,
    this.inputIncludesCacheWrite = false,
    this.outputIncludesReasoning = true,
  });

  final List<LlmUsageFieldPath> inputPaths;
  final List<LlmUsageFieldPath> outputPaths;
  final List<LlmUsageFieldPath> overallPaths;
  final List<LlmUsageFieldPath> cacheReadPaths;
  final List<LlmUsageFieldPath> cacheWritePaths;
  final List<LlmUsageFieldPath> reasoningPaths;
  final bool inputIncludesCacheRead;
  final bool inputIncludesCacheWrite;
  final bool outputIncludesReasoning;

  LlmUsageNormalizationSemantics get normalizationSemantics =>
      LlmUsageNormalizationSemantics(
        inputIncludesCacheRead: inputIncludesCacheRead,
        inputIncludesCacheWrite: inputIncludesCacheWrite,
        outputIncludesReasoning: outputIncludesReasoning,
      );
}

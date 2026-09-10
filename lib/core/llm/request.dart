import 'capabilities.dart';
import 'continuation.dart';
import 'errors.dart';
import 'generation.dart';
import 'identifiers.dart';
import 'json.dart';
import 'messages.dart';
import 'tools.dart';

final class LlmContext {
  LlmContext({
    String? systemPrompt,
    List<LlmMessage> messages = const <LlmMessage>[],
    List<LlmToolDescriptor> tools = const <LlmToolDescriptor>[],
    List<LlmContinuationEntry> continuationEntries =
        const <LlmContinuationEntry>[],
  }) : systemPrompt = _normalizePrompt(systemPrompt),
       messages = List<LlmMessage>.unmodifiable(
         List<LlmMessage>.from(messages),
       ),
       tools = List<LlmToolDescriptor>.unmodifiable(
         List<LlmToolDescriptor>.from(tools),
       ),
       continuationEntries = List<LlmContinuationEntry>.unmodifiable(
         List<LlmContinuationEntry>.from(continuationEntries),
       ) {
    final names = <String>{};
    for (final tool in this.tools) {
      if (!names.add(tool.name)) {
        throwLlm(
          LlmErrorKind.configuration,
          'Duplicate tool name "${tool.name}".',
        );
      }
    }
  }

  factory LlmContext.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmContext(
      systemPrompt: optionalString(map, 'systemPrompt'),
      messages: requireList(
        map,
        'messages',
      ).map(LlmMessage.fromJson).toList(growable: false),
      tools: requireList(
        map,
        'tools',
      ).map(LlmToolDescriptor.fromJson).toList(growable: false),
      continuationEntries: map['continuationEntries'] == null
          ? const <LlmContinuationEntry>[]
          : requireList(
              map,
              'continuationEntries',
            ).map(LlmContinuationEntry.fromJson).toList(growable: false),
    );
  }

  static const jsonType = 'llm.context';

  final String? systemPrompt;
  final List<LlmMessage> messages;
  final List<LlmToolDescriptor> tools;
  final List<LlmContinuationEntry> continuationEntries;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{
      'messages': messages.map((message) => message.toJson()).toList(),
      'tools': tools.map((tool) => tool.toJson()).toList(),
      'continuationEntries': continuationEntries
          .map((entry) => entry.toJson())
          .toList(),
    };
    if (systemPrompt != null) {
      fields['systemPrompt'] = systemPrompt;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmContext &&
          other.systemPrompt == systemPrompt &&
          listEquals(other.messages, messages) &&
          listEquals(other.tools, tools) &&
          listEquals(other.continuationEntries, continuationEntries);

  @override
  int get hashCode => Object.hash(
    systemPrompt,
    Object.hashAll(messages),
    Object.hashAll(tools),
    Object.hashAll(continuationEntries),
  );
}

final class LlmRequest {
  LlmRequest({
    required this.model,
    required this.context,
    LlmGenerationConfig? generation,
  }) : generation = generation ?? LlmGenerationConfig.defaults;

  final ModelRef model;
  final LlmContext context;
  final LlmGenerationConfig generation;

  LlmRequestSnapshot snapshot() => LlmRequestSnapshot(
    model: model,
    context: context,
    generation: generation,
  );
}

final class LlmRequestSnapshot {
  LlmRequestSnapshot({
    required this.model,
    required this.context,
    required this.generation,
  });

  factory LlmRequestSnapshot.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmRequestSnapshot(
      model: ModelRef.fromJson(map['model']),
      context: LlmContext.fromJson(map['context']),
      generation: LlmGenerationConfig.fromJson(map['generation']),
    );
  }

  static const jsonType = 'llm.request_snapshot';

  final ModelRef model;
  final LlmContext context;
  final LlmGenerationConfig generation;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'model': model.toJson(),
      'context': context.toJson(),
      'generation': generation.toJson(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmRequestSnapshot &&
          other.model == model &&
          other.context == context &&
          other.generation == generation;

  @override
  int get hashCode => Object.hash(model, context, generation);
}

void validateRequestAgainstModel(LlmRequest request, LlmModel model) {
  if (request.model.providerId != model.providerId ||
      request.model.modelId != model.id) {
    throwLlm(
      LlmErrorKind.configuration,
      'Request model ${request.model} does not match catalog model ${model.ref}.',
    );
  }
  if (request.context.tools.isNotEmpty && !model.capabilities.supportsTools) {
    throwLlm(
      LlmErrorKind.configuration,
      'Model ${model.id.value} does not support tools.',
    );
  }
  validateReasoningAgainstModel(request.generation, model);
  validateContinuationEntries(
    messages: request.context.messages,
    entries: request.context.continuationEntries,
    origin: request.model,
    wireFamily: model.wireFamily,
  );
  if (request.generation.temperature != null &&
      !model.capabilities.supportsTemperature) {
    throwLlm(
      LlmErrorKind.configuration,
      'Model ${model.id.value} does not support temperature.',
    );
  }
  if (request.generation.maxOutputTokens != null &&
      request.generation.maxOutputTokens! > model.outputBound) {
    throwLlm(
      LlmErrorKind.configuration,
      'maxOutputTokens exceeds the output bound for ${model.id.value}.',
    );
  }
  for (final message in request.context.messages) {
    for (final part in message.parts) {
      if (part is LlmReasoningPart &&
          model.capabilities.reasoning ==
              ModelReasoningCapability.unsupported) {
        throwLlm(
          LlmErrorKind.configuration,
          'Model ${model.id.value} does not support reasoning content.',
        );
      }
      if ((part is LlmToolCallPart || part is LlmToolResultPart) &&
          !model.capabilities.supportsTools) {
        throwLlm(
          LlmErrorKind.configuration,
          'Model ${model.id.value} does not support tool content.',
        );
      }
    }
  }
}

void validateReasoningAgainstModel(
  LlmGenerationConfig generation,
  LlmModel model,
) {
  final capability = model.capabilities.reasoning;
  if (generation.reasoningMode == ReasoningMode.enabled &&
      capability == ModelReasoningCapability.unsupported) {
    throwLlm(
      LlmErrorKind.configuration,
      'Model ${model.id.value} does not support reasoning.',
    );
  }
  if (generation.reasoningMode == ReasoningMode.disabled &&
      capability == ModelReasoningCapability.required) {
    throwLlm(
      LlmErrorKind.configuration,
      'Model ${model.id.value} cannot disable reasoning.',
    );
  }
  if (generation.reasoningEffort.isExplicit &&
      !model.capabilities.selectableEfforts.contains(
        generation.reasoningEffort,
      )) {
    throwLlm(
      LlmErrorKind.configuration,
      'Model ${model.id.value} does not accept reasoning effort '
      '"${generation.reasoningEffort.name}".',
    );
  }
}

String? _normalizePrompt(String? systemPrompt) {
  if (systemPrompt == null) {
    return null;
  }
  final trimmed = systemPrompt.trim();
  return trimmed.isEmpty ? null : trimmed;
}

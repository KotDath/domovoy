import 'errors.dart';
import 'generation.dart';
import 'identifiers.dart';
import 'json.dart';

final class ModelCapabilities {
  ModelCapabilities({
    required this.supportsTextInput,
    required this.reasoning,
    required this.supportsTools,
    this.supportsTemperature = true,
    List<ReasoningEffort> selectableEfforts = const <ReasoningEffort>[],
  }) : selectableEfforts = List<ReasoningEffort>.unmodifiable(
         List<ReasoningEffort>.from(selectableEfforts),
       ) {
    if (!supportsTextInput) {
      throwLlm(
        LlmErrorKind.configuration,
        'Catalog models must support text input.',
      );
    }
    final seen = <ReasoningEffort>{};
    for (final effort in this.selectableEfforts) {
      if (effort == ReasoningEffort.modelDefault) {
        throwLlm(
          LlmErrorKind.configuration,
          'selectableEfforts must not include modelDefault.',
        );
      }
      if (!seen.add(effort)) {
        throwLlm(
          LlmErrorKind.configuration,
          'Duplicate selectable reasoning effort "${effort.name}".',
        );
      }
    }
    if (reasoning == ModelReasoningCapability.unsupported &&
        this.selectableEfforts.isNotEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Unsupported-reasoning models cannot declare selectable efforts.',
      );
    }
  }

  factory ModelCapabilities.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ModelCapabilities(
      supportsTextInput: requireBool(map, 'supportsTextInput'),
      reasoning: ModelReasoningCapability.fromName(
        requireNonBlankString(map, 'reasoning'),
      ),
      supportsTools: requireBool(map, 'supportsTools'),
      supportsTemperature: requireBool(map, 'supportsTemperature'),
      selectableEfforts: requireList(map, 'selectableEfforts').map((value) {
        if (value is! String) {
          throwLlm(
            LlmErrorKind.protocol,
            'selectableEfforts entries must be strings.',
          );
        }
        return ReasoningEffort.fromName(value);
      }).toList(),
    );
  }

  static const jsonType = 'llm.model_capabilities';

  final bool supportsTextInput;
  final ModelReasoningCapability reasoning;
  final bool supportsTools;
  final bool supportsTemperature;
  final List<ReasoningEffort> selectableEfforts;

  bool get supportsReasoning =>
      reasoning != ModelReasoningCapability.unsupported;

  bool get canDisableReasoning =>
      reasoning != ModelReasoningCapability.required;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'supportsTextInput': supportsTextInput,
      'reasoning': reasoning.name,
      'supportsTools': supportsTools,
      'supportsTemperature': supportsTemperature,
      'selectableEfforts': selectableEfforts
          .map((effort) => effort.name)
          .toList(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelCapabilities &&
          other.supportsTextInput == supportsTextInput &&
          other.reasoning == reasoning &&
          other.supportsTools == supportsTools &&
          other.supportsTemperature == supportsTemperature &&
          listEquals(other.selectableEfforts, selectableEfforts);

  @override
  int get hashCode => Object.hash(
    supportsTextInput,
    reasoning,
    supportsTools,
    supportsTemperature,
    Object.hashAll(selectableEfforts),
  );
}

final class LlmModel {
  LlmModel({
    required this.providerId,
    required this.id,
    required String name,
    required this.wireFamily,
    required this.capabilities,
    required int? contextBound,
    required int? outputBound,
  }) : name = name.trim(),
       knownContextBound = contextBound,
       knownOutputBound = outputBound,
       contextBound = contextBound ?? unknownBoundGuardCeiling,
       outputBound = outputBound ?? unknownBoundGuardCeiling {
    if (this.name.isEmpty) {
      throwLlm(LlmErrorKind.configuration, 'Model name must not be blank.');
    }
    if (contextBound != null && contextBound <= 0) {
      throwLlm(
        LlmErrorKind.configuration,
        'Model context bound must be positive.',
      );
    }
    if (outputBound != null && outputBound <= 0) {
      throwLlm(
        LlmErrorKind.configuration,
        'Model output bound must be positive.',
      );
    }
  }

  factory LlmModel.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmModel(
      providerId: ProviderId.fromJson(map['providerId']),
      id: ModelId.fromJson(map['id']),
      name: requireString(map, 'name'),
      wireFamily: LlmWireFamily.fromJson(map['wireFamily']),
      capabilities: ModelCapabilities.fromJson(map['capabilities']),
      contextBound: map['contextBound'] == null
          ? null
          : requirePositiveInt(map, 'contextBound'),
      outputBound: map['outputBound'] == null
          ? null
          : requirePositiveInt(map, 'outputBound'),
    );
  }

  static const jsonType = 'llm.model';

  /// Internal compatibility ceiling only; never an advertised model limit.
  static const unknownBoundGuardCeiling = 4503599627370495;

  final ProviderId providerId;
  final ModelId id;
  final String name;
  final LlmWireFamily wireFamily;
  final ModelCapabilities capabilities;
  final int contextBound;
  final int outputBound;
  final int? knownContextBound;
  final int? knownOutputBound;

  ModelRef get ref => ModelRef(providerId: providerId, modelId: id);

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'providerId': providerId.toJson(),
      'id': id.toJson(),
      'name': name,
      'wireFamily': wireFamily.toJson(),
      'capabilities': capabilities.toJson(),
      'contextBound': knownContextBound,
      'outputBound': knownOutputBound,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmModel &&
          other.providerId == providerId &&
          other.id == id &&
          other.name == name &&
          other.wireFamily == wireFamily &&
          other.capabilities == capabilities &&
          other.contextBound == contextBound &&
          other.outputBound == outputBound &&
          other.knownContextBound == knownContextBound &&
          other.knownOutputBound == knownOutputBound;

  @override
  int get hashCode => Object.hash(
    providerId,
    id,
    name,
    wireFamily,
    capabilities,
    contextBound,
    outputBound,
    knownContextBound,
    knownOutputBound,
  );
}

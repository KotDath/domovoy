import 'errors.dart';
import 'json.dart';

final class ProviderId {
  ProviderId(String value) : value = _validateId(value, 'Provider id');

  factory ProviderId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ProviderId(requireString(map, 'value'));
  }

  static const jsonType = 'llm.provider_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProviderId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ModelId {
  ModelId(String value) : value = _validateId(value, 'Model id');

  factory ModelId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ModelId(requireString(map, 'value'));
  }

  static const jsonType = 'llm.model_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ModelId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ToolCallId {
  ToolCallId(String value) : value = _validateId(value, 'Tool call id');

  factory ToolCallId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ToolCallId(requireString(map, 'value'));
  }

  static const jsonType = 'llm.tool_call_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ToolCallId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ModelRef {
  ModelRef({required this.providerId, required this.modelId});

  factory ModelRef.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ModelRef(
      providerId: ProviderId.fromJson(map['providerId']),
      modelId: ModelId.fromJson(map['modelId']),
    );
  }

  static const jsonType = 'llm.model_ref';

  final ProviderId providerId;
  final ModelId modelId;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'providerId': providerId.toJson(),
      'modelId': modelId.toJson(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelRef &&
          other.providerId == providerId &&
          other.modelId == modelId;

  @override
  int get hashCode => Object.hash(providerId, modelId);

  @override
  String toString() => '${providerId.value}/${modelId.value}';
}

enum LlmWireFamily {
  openaiChatCompletions,
  openaiResponses;

  static const jsonType = 'llm.wire_family';

  String get wireName => switch (this) {
    LlmWireFamily.openaiChatCompletions => 'openai_chat_completions',
    LlmWireFamily.openaiResponses => 'openai_responses',
  };

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': wireName});

  static LlmWireFamily fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final value = requireNonBlankString(map, 'value');
    return switch (value) {
      'openai_chat_completions' => LlmWireFamily.openaiChatCompletions,
      'openai_responses' => LlmWireFamily.openaiResponses,
      _ => throwLlm(LlmErrorKind.protocol, 'Unknown wire family "$value".'),
    };
  }
}

String _validateId(String value, String label) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throwLlm(LlmErrorKind.configuration, '$label must not be blank.');
  }
  return normalized;
}

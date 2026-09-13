import '../llm/errors.dart';
import '../llm/json.dart';

final class AgentId {
  AgentId(String value) : value = _validate(value, 'Agent id');

  factory AgentId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AgentId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ToolId {
  ToolId(String value) : value = _validate(value, 'Tool id');

  factory ToolId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ToolId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.tool_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ToolId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class PolicyId {
  PolicyId(String value) : value = _validate(value, 'Policy id');

  factory PolicyId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return PolicyId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.policy_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PolicyId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class AgentSessionId {
  AgentSessionId(String value) : value = _validate(value, 'Session id');

  factory AgentSessionId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentSessionId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.session_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AgentSessionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class RunId {
  RunId(String value) : value = _validate(value, 'Run id');

  factory RunId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return RunId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.run_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RunId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class AgentCompactionOperationId {
  AgentCompactionOperationId(String value)
    : value = _validate(value, 'Compaction operation id');

  factory AgentCompactionOperationId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentCompactionOperationId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.compaction_operation_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentCompactionOperationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class AgentSelectionOperationId {
  AgentSelectionOperationId(String value)
    : value = _validate(value, 'Selection operation id');

  factory AgentSelectionOperationId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentSelectionOperationId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.selection_operation_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentSelectionOperationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ProviderAttemptId {
  ProviderAttemptId(String value)
    : value = _validate(value, 'Provider attempt id');

  factory ProviderAttemptId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ProviderAttemptId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.provider_attempt_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProviderAttemptId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Stable identity for one transcript message across compaction and restore.
///
/// This is deliberately separate from [MessageId], which identifies inbound
/// mailbox delivery rather than a retained chat message.
final class AgentTranscriptMessageId {
  AgentTranscriptMessageId(String value)
    : value = _validate(value, 'Transcript message id');

  factory AgentTranscriptMessageId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentTranscriptMessageId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.transcript_message_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTranscriptMessageId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class TurnId {
  TurnId(String value) : value = _validate(value, 'Turn id');

  factory TurnId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return TurnId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.turn_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is TurnId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class MessageId {
  MessageId(String value) : value = _validate(value, 'Message id');

  factory MessageId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return MessageId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.message_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MessageId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class CorrelationId {
  CorrelationId(String value) : value = _validate(value, 'Correlation id');

  factory CorrelationId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return CorrelationId(requireString(map, 'value'));
  }

  static const jsonType = 'agent.correlation_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CorrelationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

String _validate(String value, String label) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throwLlm(LlmErrorKind.configuration, '$label must not be blank.');
  }
  return normalized;
}

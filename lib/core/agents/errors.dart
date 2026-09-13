import '../llm/errors.dart';
import '../llm/json.dart';

enum AgentErrorKind {
  configuration,
  persistence,
  conflict,
  busy,
  compaction,
  protocol,
  provider,
  runtime,
  budgetUnverifiable,
  cancelled,
  unknown,
}

final class AgentError implements Exception {
  AgentError({
    required this.kind,
    required String message,
    this.safeProviderMessage = false,
  }) : message = message.trim() {
    if (this.message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'Error message must not be blank.',
      );
    }
  }

  factory AgentError.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final kindName = requireNonBlankString(map, 'kind');
    final kind = AgentErrorKind.values
        .where((value) => value.name == kindName)
        .firstOrNull;
    if (kind == null) {
      throwLlm(LlmErrorKind.protocol, 'Unknown agent error kind "$kindName".');
    }
    return AgentError(
      kind: kind,
      message: requireNonBlankString(map, 'message'),
      safeProviderMessage: map['safeProviderMessage'] == true,
    );
  }

  static const jsonType = 'agent.error';

  final AgentErrorKind kind;
  final String message;
  final bool safeProviderMessage;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'kind': kind.name,
      'message': message,
      if (safeProviderMessage) 'safeProviderMessage': true,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentError &&
          other.kind == kind &&
          other.message == message &&
          other.safeProviderMessage == safeProviderMessage;

  @override
  int get hashCode => Object.hash(kind, message, safeProviderMessage);

  @override
  String toString() => 'AgentError($kind: $message)';
}

final class AgentException implements Exception {
  AgentException(this.error);

  final AgentError error;

  @override
  String toString() => error.toString();
}

Never throwAgent(AgentErrorKind kind, String message) {
  throw AgentException(AgentError(kind: kind, message: message));
}

AgentError sanitizedRuntimeError() {
  return AgentError(
    kind: AgentErrorKind.runtime,
    message: 'Агент остановился из-за внутренней ошибки выполнения.',
  );
}

AgentError sanitizedPersistenceError() {
  return AgentError(
    kind: AgentErrorKind.persistence,
    message: 'Не удалось сохранить состояние сессии.',
  );
}

AgentError sanitizedCompactionError() {
  return AgentError(
    kind: AgentErrorKind.compaction,
    message: 'Не удалось безопасно сжать контекст сессии.',
  );
}

AgentError sanitizedCloseError() {
  return AgentError(
    kind: AgentErrorKind.runtime,
    message: 'Не удалось корректно остановить агентную среду.',
  );
}

AgentError sanitizeCloseFailure(Object error) {
  if (error is AgentException) {
    if (error.error.kind == AgentErrorKind.persistence ||
        error.error.kind == AgentErrorKind.conflict) {
      return sanitizedPersistenceError();
    }
    if (error.error.kind == AgentErrorKind.runtime) {
      return sanitizedRuntimeError();
    }
    return sanitizedCloseError();
  }
  return sanitizedCloseError();
}

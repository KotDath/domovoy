import '../llm/json.dart';

enum MemoryErrorKind {
  configuration,
  protocol,
  conflict,
  cancelled,
  unsupported,
  notFound,
  secretDetected,
  persistence,
}

final class MemoryError implements Exception {
  MemoryError({required this.kind, required String message})
    : message = message.trim() {
    if (this.message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'Error message must not be blank.',
      );
    }
  }

  factory MemoryError.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      final kindName = requireNonBlankString(map, 'kind');
      final kind = MemoryErrorKind.values
          .where((value) => value.name == kindName)
          .firstOrNull;
      if (kind == null) {
        throwMemory(
          MemoryErrorKind.protocol,
          'Unknown memory error kind "$kindName".',
        );
      }
      return MemoryError(
        kind: kind,
        message: requireNonBlankString(map, 'message'),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.error';

  final MemoryErrorKind kind;
  final String message;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{'kind': kind.name, 'message': message},
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryError && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'MemoryError($kind: $message)';
}

final class MemoryException implements Exception {
  MemoryException(this.error);

  final MemoryError error;

  @override
  String toString() => error.toString();
}

Never throwMemory(MemoryErrorKind kind, String message) {
  throw MemoryException(MemoryError(kind: kind, message: message));
}

MemoryError sanitizedMemoryPersistenceError() {
  return MemoryError(
    kind: MemoryErrorKind.persistence,
    message: 'Не удалось сохранить память.',
  );
}

MemoryError sanitizedMemorySecretError() {
  return MemoryError(
    kind: MemoryErrorKind.secretDetected,
    message: 'Память содержит обнаруженный секрет и не может быть сохранена.',
  );
}

MemoryError sanitizedMemoryNotFoundError() {
  return MemoryError(
    kind: MemoryErrorKind.notFound,
    message: 'Запись памяти не найдена.',
  );
}

MemoryException wrapMemoryCodecFailure(Object error) {
  if (error is MemoryException) {
    return error;
  }
  return MemoryException(
    MemoryError(
      kind: MemoryErrorKind.configuration,
      message: 'Некорректная запись памяти.',
    ),
  );
}

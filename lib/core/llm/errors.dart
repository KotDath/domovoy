import 'json.dart';

enum LlmErrorKind {
  configuration,
  authentication,
  rateLimit,
  contextOverflow,
  provider,
  network,
  protocol,
  interrupted,
  unknown,
}

final class LlmError implements Exception {
  LlmError({
    required this.kind,
    required String message,
    this.safeForDisplay = false,
  }) : message = message.trim() {
    if (this.message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'Error message must not be blank.',
      );
    }
  }

  factory LlmError.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final kindName = requireNonBlankString(map, 'kind');
    final kind = LlmErrorKind.values
        .where((value) => value.name == kindName)
        .firstOrNull;
    if (kind == null) {
      throwLlm(LlmErrorKind.protocol, 'Unknown error kind "$kindName".');
    }
    return LlmError(
      kind: kind,
      message: requireNonBlankString(map, 'message'),
      safeForDisplay: map['safeForDisplay'] == true,
    );
  }

  static const jsonType = 'llm.error';

  final LlmErrorKind kind;
  final String message;
  final bool safeForDisplay;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'kind': kind.name,
      'message': message,
      if (safeForDisplay) 'safeForDisplay': true,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmError &&
          other.kind == kind &&
          other.message == message &&
          other.safeForDisplay == safeForDisplay;

  @override
  int get hashCode => Object.hash(kind, message, safeForDisplay);

  @override
  String toString() => 'LlmError($kind: $message)';
}

final class LlmException implements Exception {
  LlmException(this.error);

  final LlmError error;

  @override
  String toString() => error.toString();
}

Never throwLlm(LlmErrorKind kind, String message) {
  throw LlmException(LlmError(kind: kind, message: message));
}

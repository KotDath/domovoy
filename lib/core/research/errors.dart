/// Errors raised by versioned research wire contracts (`Paper`/`Digest`).
enum ResearchErrorKind {
  /// The payload is not a JSON object of the expected shape.
  format,

  /// The payload declares a schema version this build does not understand.
  unsupportedVersion,

  /// A required field is missing, blank or of the wrong type.
  invalidField,

  /// An arXiv identifier or URL cannot be normalized safely.
  invalidArxivId,
}

final class ResearchError implements Exception {
  ResearchError({required this.kind, required String message})
    : message = message.trim() {
    if (this.message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'Error message must not be blank.',
      );
    }
  }

  final ResearchErrorKind kind;
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResearchError && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'ResearchError($kind: $message)';
}

final class ResearchException implements Exception {
  ResearchException(this.error);

  final ResearchError error;

  @override
  String toString() => error.toString();
}

Never throwResearch(ResearchErrorKind kind, String message) {
  throw ResearchException(ResearchError(kind: kind, message: message));
}

/// Rejects [json] when it is not an object or carries a field outside
/// [allowed]; returns the accepted object for further nested checks.
///
/// Versioned research contracts whose readers must fail closed on unexpected
/// nested data (the library tool boundary and the library JSONL replay) use
/// this instead of silently dropping unknown fields. The message names only
/// the offending field, bounded in length, never the whole payload.
Map<Object?, Object?> verifyResearchFields(
  Object? json,
  Set<String> allowed,
  String label,
) {
  if (json is! Map) {
    throwResearch(
      ResearchErrorKind.format,
      'Expected a JSON object for $label.',
    );
  }
  for (final key in json.keys) {
    if (key is! String || !allowed.contains(key)) {
      throwResearch(
        ResearchErrorKind.invalidField,
        '$label does not allow field "${_describeFieldKey(key)}".',
      );
    }
  }
  return json;
}

String _describeFieldKey(Object? key) {
  final text = key is String ? key : '<${key.runtimeType}>';
  const limit = 64;
  if (text.length <= limit) {
    return text;
  }
  return '${text.substring(0, limit)}…';
}

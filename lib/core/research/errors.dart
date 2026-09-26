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

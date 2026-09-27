/// Error taxonomy of the local research library (B5).
///
/// The `library` MCP server maps these kinds to stable `[library:<wire>]`
/// failure texts; the JSONL store never lets raw filesystem or codec errors
/// escape to the tool boundary.
enum LibraryErrorKind {
  /// The caller supplied arguments the library refuses to persist.
  invalidInput,

  /// No saved record matches the requested identity.
  notFound,

  /// A `runId` is already bound to a different payload.
  conflict,

  /// The payload declares a schema version this build does not understand.
  versionMismatch,

  /// Stored bytes could not be replayed as a complete library record.
  corruption,

  /// The storage boundary itself failed (unreadable list, failed publish).
  persistence,

  /// The MCP client cancelled the call before it finished.
  cancelled,
}

/// One sanitized, bounded library failure.
final class LibraryError implements Exception {
  LibraryError({required this.kind, required String message})
    : message = message.trim() {
    if (this.message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'Library error message must not be blank.',
      );
    }
  }

  final LibraryErrorKind kind;

  /// Single-line explanation safe to show to the model and in logs.
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryError && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'LibraryError(${kind.name}: $message)';
}

final class LibraryException implements Exception {
  LibraryException(this.error);

  final LibraryError error;

  @override
  String toString() => error.toString();
}

Never throwLibrary(LibraryErrorKind kind, String message) {
  throw LibraryException(LibraryError(kind: kind, message: message));
}

import '../../../../core/research/research.dart';

/// Error taxonomy of the local `library` MCP server.
///
/// MCP has no machine-readable error codes for `tools/call` results, so the
/// server distinguishes its failures by a stable `[library:<kind>]` prefix in
/// the text block. Domain failures stay separate from transport and protocol
/// failures, which lets the agent bridge and the call trace react differently.
enum LibraryFailureKind {
  /// The caller supplied arguments the server refuses to persist.
  invalidInput('invalid_input'),

  /// No saved record matches the requested identity.
  notFound('not_found'),

  /// A `runId` is already bound to a different payload.
  conflict('conflict'),

  /// The payload declares a schema version this build does not understand.
  versionMismatch('version_mismatch'),

  /// Stored bytes could not be replayed as a complete library record.
  corruption('corruption'),

  /// The storage boundary itself failed (unreadable list, failed publish).
  persistence('persistence'),

  /// The MCP client cancelled the call before it finished.
  cancelled('cancelled'),

  /// Unexpected server failure; no partial library state was published.
  internal('internal');

  const LibraryFailureKind(this.wireName);

  /// Stable machine-readable name used in the tool text result.
  final String wireName;
}

/// One sanitized, bounded failure of the `library` server.
final class LibraryFailure implements Exception {
  LibraryFailure({required this.kind, required String message})
    : message = _sanitizeMessage(message);

  final LibraryFailureKind kind;

  /// Single-line, bounded explanation safe to show to the model and in logs.
  final String message;

  /// Text placed in the MCP error result, for example
  /// `[library:conflict] runId ... уже связан с другой записью.`
  String get mcpText => '[library:${kind.wireName}] $message';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryFailure && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'LibraryFailure(${kind.name}: $message)';
}

/// Throws a sanitized [LibraryFailure]; keeps error construction consistent.
Never throwLibraryFailure(LibraryFailureKind kind, String message) {
  throw LibraryFailure(kind: kind, message: message);
}

/// Maps one domain/storage error to the wire taxonomy of this server.
LibraryFailure libraryFailureFromError(LibraryException error) {
  final kind = switch (error.error.kind) {
    LibraryErrorKind.invalidInput => LibraryFailureKind.invalidInput,
    LibraryErrorKind.notFound => LibraryFailureKind.notFound,
    LibraryErrorKind.conflict => LibraryFailureKind.conflict,
    LibraryErrorKind.versionMismatch => LibraryFailureKind.versionMismatch,
    LibraryErrorKind.corruption => LibraryFailureKind.corruption,
    LibraryErrorKind.persistence => LibraryFailureKind.persistence,
    LibraryErrorKind.cancelled => LibraryFailureKind.cancelled,
  };
  return LibraryFailure(kind: kind, message: error.error.message);
}

String _sanitizeMessage(String message) {
  final normalized = message
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(message, 'message', 'must not be blank');
  }
  const limit = 400;
  return normalized.length <= limit
      ? normalized
      : '${normalized.substring(0, limit)}…';
}

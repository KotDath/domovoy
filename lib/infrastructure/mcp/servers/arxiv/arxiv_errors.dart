/// Error taxonomy of the local `arxiv` MCP server.
///
/// MCP has no machine-readable error codes for `tools/call` results, so the
/// server distinguishes its failures by a stable `[arxiv:<kind>]` prefix in
/// the text block. Domain failures (bad arguments, missing paper) stay
/// separate from transport and protocol failures, which lets the agent bridge
/// and the call trace react to them differently.
library;

/// Categories of failures produced by [ArxivClient] and its tools.
enum ArxivFailureKind {
  /// The caller supplied arguments the server refuses to send to arXiv.
  invalidInput('invalid_input'),

  /// The request was valid but arXiv has no such paper or version.
  notFound('not_found'),

  /// arXiv answered with 429 or asked to slow down via `Retry-After`.
  rateLimited('rate_limited'),

  /// The request never reached a usable arXiv HTTP response.
  network('network'),

  /// The whole arXiv call exceeded its deadline.
  timeout('timeout'),

  /// The response was malformed, oversized or otherwise not usable.
  protocol('protocol'),

  /// The MCP client cancelled the call before it finished.
  cancelled('cancelled');

  const ArxivFailureKind(this.wireName);

  /// Stable machine-readable name used in the tool text result.
  final String wireName;
}

/// One sanitized, bounded failure of the `arxiv` server.
final class ArxivFailure implements Exception {
  ArxivFailure({required this.kind, required String message, this.retryAfter})
    : message = _sanitizeMessage(message);

  final ArxivFailureKind kind;

  /// Single-line, bounded explanation safe to show to the model and in logs.
  final String message;

  /// Server-provided backoff for [ArxivFailureKind.rateLimited], if any.
  final Duration? retryAfter;

  /// Text placed in the MCP error result, for example
  /// `[arxiv:rate_limited] arXiv ограничил частоту запросов.`
  String get mcpText => '[arxiv:${kind.wireName}] $message';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArxivFailure &&
          other.kind == kind &&
          other.message == message &&
          other.retryAfter == retryAfter;

  @override
  int get hashCode => Object.hash(kind, message, retryAfter);

  @override
  String toString() => 'ArxivFailure(${kind.name}: $message)';
}

/// Throws a sanitized [ArxivFailure]; keeps error construction consistent.
Never throwArxiv(
  ArxivFailureKind kind,
  String message, {
  Duration? retryAfter,
}) {
  throw ArxivFailure(kind: kind, message: message, retryAfter: retryAfter);
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

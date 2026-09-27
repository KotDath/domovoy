/// Error taxonomy of the local `digest` MCP server.
///
/// MCP has no machine-readable error codes for `tools/call` results, so the
/// server distinguishes its failures by a stable `[digest:<kind>]` prefix in
/// the text block. Domain failures (bad arguments, unavailable model, invalid
/// model output) stay separate from transport and protocol failures, which
/// lets the agent bridge and the call trace react to them differently.
library;

/// Categories of failures produced by the `digest` server.
enum DigestFailureKind {
  /// The caller supplied arguments the server refuses to process.
  invalidInput('invalid_input'),

  /// No trusted per-invocation model pin exists, or the pinned model is not
  /// available in the current provider catalog.
  modelUnavailable('model_unavailable'),

  /// The LLM provider failed, refused or never finished its answer.
  provider('provider'),

  /// The model answered, but the answer is blank, malformed, truncated or
  /// references papers outside the supplied set.
  modelResponse('model_response'),

  /// The model answer exceeded the configured byte limit.
  outputTooLarge('output_too_large'),

  /// The provider-reported token usage exceeded the configured budget.
  budgetExceeded('budget_exceeded'),

  /// The whole synthesis exceeded its deadline.
  timeout('timeout'),

  /// The MCP client cancelled the call before it finished.
  cancelled('cancelled'),

  /// An unexpected server-side failure; the call never succeeded.
  internal('internal');

  const DigestFailureKind(this.wireName);

  /// Stable machine-readable name used in the tool text result.
  final String wireName;
}

/// One sanitized, bounded failure of the `digest` server.
final class DigestFailure implements Exception {
  DigestFailure({required this.kind, required String message})
    : message = sanitizeDigestText(message);

  final DigestFailureKind kind;

  /// Single-line, bounded explanation safe to show to the model and in logs.
  final String message;

  /// Text placed in the MCP error result, for example
  /// `[digest:model_unavailable] Для вызова не закреплена модель.`
  String get mcpText => '[digest:${kind.wireName}] $message';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DigestFailure && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'DigestFailure(${kind.name}: $message)';
}

/// Throws a sanitized [DigestFailure]; keeps error construction consistent.
Never throwDigest(DigestFailureKind kind, String message) {
  throw DigestFailure(kind: kind, message: message);
}

/// Normalizes arbitrary text for an MCP error block.
///
/// Control characters are replaced, whitespace is collapsed to single spaces
/// and the result is bounded, so untrusted provider text cannot deform the
/// tool result or grow it without limit.
String sanitizeDigestText(String message, {int limit = 400}) {
  final normalized = message
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(message, 'message', 'must not be blank');
  }
  return normalized.length <= limit
      ? normalized
      : '${normalized.substring(0, limit)}…';
}

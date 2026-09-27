/// Error taxonomy of the local automation scheduler (B6).
///
/// The `automation` MCP server maps these kinds to stable `[automation:<wire>]`
/// failure texts. The taxonomy stays in `core` because the same failures are
/// produced by the application service used directly by the tasks UI (B8).
enum AutomationErrorKind {
  /// The caller supplied arguments that fail domain validation.
  invalidInput,

  /// The cron expression or time zone cannot produce the requested schedule.
  invalidSchedule,

  /// No task or run matches the requested identity.
  notFound,

  /// An identity already exists, or a mutating operation was rejected.
  conflict,

  /// The caller's `expectedRevision` does not match the stored revision.
  revisionMismatch,

  /// The stored bytes could not be replayed as a complete record.
  corruption,

  /// The storage boundary itself failed (unreadable list, failed publish).
  persistence,

  /// The operation is denied by policy, not by the caller's allowlist.
  denied,

  /// Another run of the same task is already executing.
  noOverlap,

  /// A run limit (time, turns, tool calls, result size) stopped the work.
  limits,

  /// The model, a pinned tool or a provider secret is not available.
  unavailable,

  /// The operation was cancelled (background transition or shutdown).
  cancelled,

  /// The work was cut off without a clean termination (crash, process exit).
  interrupted,

  /// Unexpected internal failure; no partial state was published.
  internal,
}

/// One sanitized, bounded automation failure.
final class AutomationError implements Exception {
  AutomationError({required this.kind, required String message})
    : message = message.trim() {
    if (this.message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'Automation error message must not be blank.',
      );
    }
  }

  final AutomationErrorKind kind;

  /// Single-line explanation safe to show to the model and in logs.
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationError &&
          other.kind == kind &&
          other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'AutomationError(${kind.name}: $message)';
}

final class AutomationException implements Exception {
  AutomationException(this.error);

  final AutomationError error;

  @override
  String toString() => error.toString();
}

Never throwAutomation(AutomationErrorKind kind, String message) {
  throw AutomationException(AutomationError(kind: kind, message: message));
}

/// Sanitizes one message so it never leaks a secret-looking token and stays a
/// single bounded line. The automation record text is shown in the task list
/// and may be copied into an agent transcript, so it is treated as public.
String sanitizeAutomationText(String raw, {int maxLength = 400}) {
  final single = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  final clipped = single.length <= maxLength
      ? single
      : '${single.substring(0, maxLength - 1)}…';
  if (_secretPattern.hasMatch(clipped)) {
    return 'Сообщение скрыто: похоже на секрет.';
  }
  return clipped;
}

final _secretPattern = RegExp(
  r'(sk-[A-Za-z0-9]+)|api[_-]?key|bearer\s+\S+|-----BEGIN',
  caseSensitive: false,
);

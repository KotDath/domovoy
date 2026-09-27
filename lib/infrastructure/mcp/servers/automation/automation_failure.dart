import '../../../../core/automation/automation.dart';

/// Error taxonomy of the local `automation` MCP server.
///
/// MCP has no machine-readable error codes for `tools/call` results, so the
/// server distinguishes failures by a stable `[automation:<kind>]` prefix in
/// the text block. Domain failures stay separate from transport failures, which
/// lets the agent bridge and the run trace react differently.
enum AutomationFailureKind {
  /// The caller supplied arguments the server refuses.
  invalidInput('invalid_input'),

  /// The cron expression or time zone cannot produce a schedule.
  invalidSchedule('invalid_schedule'),

  /// No task matches the requested identity.
  notFound('not_found'),

  /// The requested state change conflicts with the current task state.
  conflict('conflict'),

  /// `expectedRevision` does not match the stored revision.
  revisionMismatch('revision_mismatch'),

  /// The operation is refused by policy (for example a scheduled run trying to
  /// start another task).
  denied('denied'),

  /// Another run of the same task is already executing.
  noOverlap('no_overlap'),

  /// A configured limit stopped the operation.
  limits('limits'),

  /// The model, tool or secret is not available.
  unavailable('unavailable'),

  /// Stored bytes could not be replayed.
  corruption('corruption'),

  /// The storage boundary failed.
  persistence('persistence'),

  /// The MCP client cancelled the call.
  cancelled('cancelled'),

  /// Unexpected server failure; no partial state was published.
  internal('internal');

  const AutomationFailureKind(this.wireName);

  /// Stable machine-readable name used in the tool text result.
  final String wireName;
}

/// One sanitized, bounded failure of the `automation` server.
final class AutomationFailure implements Exception {
  AutomationFailure({required this.kind, required String message})
    : message = sanitizeAutomationText(message);

  factory AutomationFailure.fromError(AutomationError error) {
    return AutomationFailure(
      kind: switch (error.kind) {
        AutomationErrorKind.invalidInput => AutomationFailureKind.invalidInput,
        AutomationErrorKind.invalidSchedule =>
          AutomationFailureKind.invalidSchedule,
        AutomationErrorKind.notFound => AutomationFailureKind.notFound,
        AutomationErrorKind.conflict => AutomationFailureKind.conflict,
        AutomationErrorKind.revisionMismatch =>
          AutomationFailureKind.revisionMismatch,
        AutomationErrorKind.denied => AutomationFailureKind.denied,
        AutomationErrorKind.noOverlap => AutomationFailureKind.noOverlap,
        AutomationErrorKind.limits => AutomationFailureKind.limits,
        AutomationErrorKind.unavailable => AutomationFailureKind.unavailable,
        AutomationErrorKind.corruption => AutomationFailureKind.corruption,
        AutomationErrorKind.persistence => AutomationFailureKind.persistence,
        AutomationErrorKind.cancelled => AutomationFailureKind.cancelled,
        AutomationErrorKind.interrupted => AutomationFailureKind.conflict,
        AutomationErrorKind.internal => AutomationFailureKind.internal,
      },
      message: error.message,
    );
  }

  final AutomationFailureKind kind;

  /// Single-line, bounded explanation safe to show to the model and in logs.
  final String message;

  /// Text placed in the MCP error result, for example
  /// `[automation:denied] запланированный запуск ...`.
  String get mcpText => '[automation:${kind.wireName}] $message';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutomationFailure &&
          other.kind == kind &&
          other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => mcpText;
}

Never throwAutomationFailure(AutomationFailureKind kind, String message) {
  throw AutomationFailure(kind: kind, message: message);
}

import 'errors.dart';
import 'ids.dart';
import 'run.dart';
import 'task.dart';

/// Observable outcome of one scheduler action.
///
/// The tasks UI (B8) listens for task and run changes instead of polling; the
/// MCP server does not consume events because tool results are synchronous.
sealed class AutomationServiceEvent {
  const AutomationServiceEvent();
}

/// A task was created or its revision changed.
final class AutomationTaskChangedEvent extends AutomationServiceEvent {
  const AutomationTaskChangedEvent(this.task);

  final AutomationTask task;
}

/// A run record changed state; `running` is emitted on start, terminal
/// statuses on completion, skip and interruption.
final class AutomationRunChangedEvent extends AutomationServiceEvent {
  const AutomationRunChangedEvent(this.run);

  final AutomationRun run;
}

/// Foreground/background transition (mobile timers pause on background).
final class AutomationForegroundChangedEvent extends AutomationServiceEvent {
  const AutomationForegroundChangedEvent(this.foreground);

  final bool foreground;
}

/// A tick failed for one task without bringing the whole scheduler down.
final class AutomationServiceErrorEvent extends AutomationServiceEvent {
  AutomationServiceErrorEvent({
    this.taskId,
    required this.kind,
    required String message,
  }) : message = sanitizeAutomationText(message);

  final AutomationTaskId? taskId;
  final AutomationErrorKind kind;
  final String message;
}

import 'run.dart';
import 'task.dart';

/// Which code path requested an automation mutation.
///
/// The distinction is a security boundary, not telemetry: a scheduled run may
/// never create tasks or launch other tasks, and an agent tool call is refused
/// while a scheduled run is executing in this process.
enum AutomationCallOrigin {
  /// The tasks UI or another explicit human action.
  human,

  /// An interactive agent tool call (`create_task` or `run_task_now`).
  agentTool,

  /// The scheduler itself while executing a scheduled or catch-up run.
  scheduledRun,
}

/// Whether a task's pinned model, tools and secret are usable right now.
final class AutomationRunAvailability {
  const AutomationRunAvailability.available()
    : isAvailable = true,
      kind = null,
      message = null;

  const AutomationRunAvailability.unavailable(
    AutomationRunErrorKind this.kind,
    String this.message,
  ) : isAvailable = false;

  final bool isAvailable;
  final AutomationRunErrorKind? kind;
  final String? message;
}

/// Immutable snapshot handed to the executor when a run starts.
///
/// The snapshot pins exactly what the user approved: prompt, model, allowed
/// tools, delivery and limits. Editing the task while the run executes affects
/// only later runs.
final class AutomationRunRequest {
  AutomationRunRequest({
    required this.task,
    required this.runId,
    required this.trigger,
    required this.scheduledAt,
  });

  /// Task snapshot of the revision the run started from.
  final AutomationTask task;
  final String runId;
  final AutomationRunTrigger trigger;
  final DateTime scheduledAt;

  String get prompt => task.prompt;
  String get taskName => task.name;
  String get sessionLabel => 'Задача «${task.name}»';
}

/// What the executor reports back after an agent session settled.
final class AutomationRunOutcome {
  AutomationRunOutcome({
    required this.status,
    this.resultText,
    this.error,
    Iterable<AutomationToolTraceEntry> trace =
        const <AutomationToolTraceEntry>[],
    this.modelTurns = 0,
    this.toolCalls = 0,
  }) : trace = List<AutomationToolTraceEntry>.unmodifiable(trace);

  /// `succeeded`, `failed` or `interrupted`.
  final AutomationRunStatus status;
  final String? resultText;
  final AutomationRunError? error;
  final List<AutomationToolTraceEntry> trace;
  final int modelTurns;
  final int toolCalls;
}

/// Starts one agent session per run and returns its result.
///
/// The production implementation (B6 infrastructure) builds a pinned
/// [AgentDefinition] with `interactiveApproval: false` and a scheduled-task
/// tool grant, then drives a fresh session. Tests inject scripted executors.
abstract interface class AutomationRunExecutor {
  /// Checks the pinned model/tools/secret before any model call.
  Future<AutomationRunAvailability> availability(AutomationTask task);

  Future<AutomationRunOutcome> execute(
    AutomationRunRequest request, {
    required AutomationResultCancellation cancellation,
  });
}

/// Cancellation handle of one run; the scheduler cancels on background,
/// shutdown or after the hard time limit.
abstract interface class AutomationResultCancellation {
  bool get isCancelled;

  /// Completes when the run is cancelled; the executor forwards it to the
  /// agent run so the model stream stops promptly.
  Future<void> get whenCancelled;

  void cancel();
}

/// Optional sink for the "card in a chat" delivery mode.
///
/// B8/B9 provide the real implementation; when it is absent, a chat delivery
/// is recorded as not delivered with a visible reason instead of being
/// silently dropped.
abstract interface class AutomationResultDelivery {
  Future<AutomationDeliveryResult?> deliver({
    required AutomationTask task,
    required AutomationRun run,
  });
}

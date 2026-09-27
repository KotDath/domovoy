import '../../../core/automation/automation.dart';

enum TasksStatus { loading, ready, failed }

enum TasksCommandStatus {
  succeeded,
  unchanged,
  busy,
  cancelled,
  notFound,
  conflict,
  failed,
}

/// Result of one tasks command, for UI notices and tests.
final class TasksCommandResult {
  const TasksCommandResult._({required this.status, this.message});

  const TasksCommandResult.succeeded()
    : this._(status: TasksCommandStatus.succeeded);

  const TasksCommandResult.unchanged()
    : this._(status: TasksCommandStatus.unchanged);

  const TasksCommandResult.busy() : this._(status: TasksCommandStatus.busy);

  const TasksCommandResult.cancelled(String message)
    : this._(status: TasksCommandStatus.cancelled, message: message);

  const TasksCommandResult.notFound(String message)
    : this._(status: TasksCommandStatus.notFound, message: message);

  const TasksCommandResult.conflict(String message)
    : this._(status: TasksCommandStatus.conflict, message: message);

  const TasksCommandResult.failed(String message)
    : this._(status: TasksCommandStatus.failed, message: message);

  final TasksCommandStatus status;
  final String? message;

  bool get isSuccess =>
      status == TasksCommandStatus.succeeded ||
      status == TasksCommandStatus.unchanged;
}

/// Observable state of the tasks section.
final class TasksState {
  const TasksState({
    this.status = TasksStatus.loading,
    this.tasks = const <AutomationTask>[],
    this.selectedTaskId,
    this.runs = const <AutomationRun>[],
    this.selectedRunId,
    this.error,
    this.busy = false,
    this.foreground = true,
  });

  final TasksStatus status;

  /// Alive tasks, UI order (proposal first, then active, paused, completed).
  final List<AutomationTask> tasks;

  final AutomationTaskId? selectedTaskId;

  /// Run history of the selected task, newest first.
  final List<AutomationRun> runs;

  final AutomationRunId? selectedRunId;
  final String? error;
  final bool busy;

  /// False while the application is in the background: no run can start.
  final bool foreground;

  bool get isReady => status == TasksStatus.ready;

  bool get isLoading => status == TasksStatus.loading;

  AutomationTask? get selectedTask {
    final id = selectedTaskId;
    if (id == null) {
      return null;
    }
    for (final task in tasks) {
      if (task.taskId == id) {
        return task;
      }
    }
    return null;
  }

  AutomationRun? get selectedRun {
    final id = selectedRunId;
    if (id == null) {
      return null;
    }
    for (final run in runs) {
      if (run.runId == id) {
        return run;
      }
    }
    return null;
  }

  /// Last finished run of the selected task, if any.
  AutomationRun? get lastRun {
    for (final run in runs) {
      if (run.status.isTerminal) {
        return run;
      }
    }
    return runs.isEmpty ? null : runs.first;
  }

  TasksState copyWith({
    TasksStatus? status,
    List<AutomationTask>? tasks,
    Object? selectedTaskId = _unset,
    List<AutomationRun>? runs,
    Object? selectedRunId = _unset,
    Object? error = _unset,
    bool? busy,
    bool? foreground,
  }) {
    return TasksState(
      status: status ?? this.status,
      tasks: tasks ?? this.tasks,
      selectedTaskId: identical(selectedTaskId, _unset)
          ? this.selectedTaskId
          : selectedTaskId as AutomationTaskId?,
      runs: runs ?? this.runs,
      selectedRunId: identical(selectedRunId, _unset)
          ? this.selectedRunId
          : selectedRunId as AutomationRunId?,
      error: identical(error, _unset) ? this.error : error as String?,
      busy: busy ?? this.busy,
      foreground: foreground ?? this.foreground,
    );
  }
}

const Object _unset = Object();

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/automation/automation.dart';
import 'tasks_state.dart';

/// State and commands of the tasks section (B8).
///
/// One controller serves the list, run history, manual start, pause/resume,
/// confirmation of agent proposals and the explicit retry of a chat card. It
/// never writes tasks directly: every mutation goes through
/// [AutomationService], so the UI and the `automation` MCP server share the
/// same scheduler, store and policy checks.
final class TasksController extends ChangeNotifier {
  TasksController({required this.service, this.delivery}) {
    _state = TasksState(foreground: service.isForeground);
    _events = service.events.listen(_onServiceEvent);
  }

  final AutomationService service;

  /// Chat card sink, used to retry an uncertain or failed delivery. Null when
  /// this composition has no chat delivery.
  final AutomationResultDelivery? delivery;

  late final StreamSubscription<AutomationServiceEvent> _events;
  late TasksState _state;
  var _initialized = false;
  var _busy = false;
  var _disposed = false;

  TasksState get state => _state;

  /// Loads tasks and the history of the first one.
  Future<TasksCommandResult> initialize() async {
    if (_disposed) {
      return const TasksCommandResult.failed('Раздел задач закрыт.');
    }
    if (_initialized) {
      return refresh();
    }
    _initialized = true;
    return _run(() async {
      final tasks = _sortedTasks(await service.listTasks());
      final selected = tasks.isEmpty ? null : tasks.first.taskId;
      final runs = selected == null
          ? const <AutomationRun>[]
          : await service.listRuns(selected);
      _emit(
        _state.copyWith(
          status: TasksStatus.ready,
          tasks: tasks,
          selectedTaskId: selected,
          runs: runs,
          selectedRunId: runs.isEmpty ? null : runs.first.runId,
          error: null,
        ),
      );
    });
  }

  /// Reloads tasks and the history of the selected task.
  Future<TasksCommandResult> refresh() {
    if (_disposed) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.failed('Раздел задач закрыт.'),
      );
    }
    if (!_initialized) {
      return initialize();
    }
    return _run(() async {
      final tasks = _sortedTasks(await service.listTasks());
      final selected = _liveSelection(tasks);
      final runs = selected == null
          ? const <AutomationRun>[]
          : await service.listRuns(selected);
      _emit(
        _state.copyWith(
          status: TasksStatus.ready,
          tasks: tasks,
          selectedTaskId: selected,
          runs: runs,
          selectedRunId: _keepRunSelection(runs),
          error: null,
        ),
      );
    });
  }

  /// Selects a task and loads its run history.
  Future<TasksCommandResult> selectTask(AutomationTaskId taskId) {
    if (_disposed) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.failed('Раздел задач закрыт.'),
      );
    }
    if (!_state.tasks.any((task) => task.taskId == taskId)) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.notFound('Задача не найдена.'),
      );
    }
    if (_state.selectedTaskId == taskId && _state.runs.isNotEmpty) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.unchanged(),
      );
    }
    return _run(() async {
      final runs = await service.listRuns(taskId);
      _emit(
        _state.copyWith(
          selectedTaskId: taskId,
          runs: runs,
          selectedRunId: runs.isEmpty ? null : runs.first.runId,
          error: null,
        ),
      );
    });
  }

  void selectRun(AutomationRunId? runId) {
    if (_disposed || _state.selectedRunId == runId) {
      return;
    }
    _emit(_state.copyWith(selectedRunId: runId));
  }

  /// Starts a manual run of [taskId]; the planned moment does not move.
  Future<TasksCommandResult> runNow(AutomationTaskId taskId) {
    if (_disposed) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.failed('Раздел задач закрыт.'),
      );
    }
    return _run(() async {
      final task = _taskOrNull(taskId);
      if (task == null) {
        throwAutomation(AutomationErrorKind.notFound, 'Задача не найдена.');
      }
      final handle = await service.runTaskNow(taskId);
      final started = await service.findRun(handle.runId);
      if (started != null) {
        _upsertRun(started);
      }
    });
  }

  /// Pauses or resumes a task; a paused task never replays missed periods.
  Future<TasksCommandResult> setPaused(AutomationTaskId taskId, bool paused) {
    if (_disposed) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.failed('Раздел задач закрыт.'),
      );
    }
    return _run(() async {
      final task = await service.setPaused(taskId, paused);
      _upsertTask(task);
    });
  }

  /// Confirms an agent proposal so it may start.
  Future<TasksCommandResult> confirmTask(AutomationTaskId taskId) {
    if (_disposed) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.failed('Раздел задач закрыт.'),
      );
    }
    return _run(() async {
      final task = await service.confirmTask(taskId);
      _upsertTask(task);
    });
  }

  /// Tombstones a task; its running execution is interrupted.
  Future<TasksCommandResult> deleteTask(AutomationTaskId taskId) {
    if (_disposed) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.failed('Раздел задач закрыт.'),
      );
    }
    return _run(() async {
      await service.deleteTask(taskId);
      final tasks = _sortedTasks(await service.listTasks());
      final selected = _liveSelection(tasks);
      final runs = selected == null
          ? const <AutomationRun>[]
          : await service.listRuns(selected);
      _emit(
        _state.copyWith(
          tasks: tasks,
          selectedTaskId: selected,
          runs: runs,
          selectedRunId: runs.isEmpty ? null : runs.first.runId,
          error: null,
        ),
      );
    });
  }

  /// Retries the chat card of a terminal run whose delivery marker is missing
  /// or reports a failure.
  ///
  /// The card store is idempotent by runId, so a retry after an uncertain
  /// response or a crash between the terminal run and the delivery marker can
  /// never create a second card. The outcome of the retry is written back into
  /// the run record as the explicit delivery state; a missing chat stays a
  /// visible undelivered error.
  Future<TasksCommandResult> retryDelivery(AutomationRunId runId) {
    if (_disposed) {
      return Future<TasksCommandResult>.value(
        const TasksCommandResult.failed('Раздел задач закрыт.'),
      );
    }
    return _run(() async {
      final sink = delivery;
      final run = await service.findRun(runId);
      if (run == null) {
        throwAutomation(AutomationErrorKind.notFound, 'Запуск не найден.');
      }
      if (run.status != AutomationRunStatus.succeeded &&
          run.status != AutomationRunStatus.failed) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'Карточку можно доставить только после успешного или неуспешного завершения запуска.',
        );
      }
      if (run.delivery?.delivered == true) {
        throwAutomation(
          AutomationErrorKind.conflict,
          'Результат уже доставлен в чат.',
        );
      }
      final target = run.deliveryTarget;
      if (target == null || target.kind != AutomationDeliveryKind.chat) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'У запуска нет доставки в чат; результат остаётся в разделе «Задачи».',
        );
      }
      if (sink == null) {
        throwAutomation(
          AutomationErrorKind.unavailable,
          'Доставка в чат недоступна в этой сборке; результат сохранён в '
          'разделе «Задачи».',
        );
      }
      AutomationDeliveryResult result;
      try {
        result =
            await sink.deliver(target: target, run: run) ??
            const AutomationDeliveryResult(
              delivered: false,
              error: 'Доставка результата в чат не удалась.',
            );
      } on Object {
        result = const AutomationDeliveryResult(
          delivered: false,
          error: 'Доставка результата в чат не удалась.',
        );
      }
      final updated = run.copyWith(
        delivery: result,
        revision: run.revision + 1,
      );
      final persisted = await service.runs.appendRun(
        updated,
        expectedRevision: run.revision,
      );
      _upsertRun(persisted);
      if (!result.delivered) {
        throwAutomation(
          AutomationErrorKind.denied,
          result.error ??
              'Доставка результата в чат не удалась; он остаётся в разделе '
                  '«Задачи».',
        );
      }
    });
  }

  Future<TasksCommandResult> _run(Future<void> Function() action) async {
    if (_busy) {
      return const TasksCommandResult.busy();
    }
    _busy = true;
    _emit(_state.copyWith(busy: true, error: null));
    try {
      await action();
      return const TasksCommandResult.succeeded();
    } on AutomationException catch (error) {
      _emit(_state.copyWith(error: error.error.message));
      return _mapFailure(error.error);
    } on Object {
      const message = 'Операция с задачей завершилась внутренней ошибкой.';
      _emit(_state.copyWith(error: message));
      return const TasksCommandResult.failed(message);
    } finally {
      _busy = false;
      _emit(_state.copyWith(busy: false));
    }
  }

  TasksCommandResult _mapFailure(AutomationError error) => switch (error.kind) {
    AutomationErrorKind.notFound => TasksCommandResult.notFound(error.message),
    AutomationErrorKind.conflict || AutomationErrorKind.revisionMismatch =>
      TasksCommandResult.conflict(error.message),
    AutomationErrorKind.cancelled => TasksCommandResult.cancelled(
      error.message,
    ),
    _ => TasksCommandResult.failed(error.message),
  };

  void _onServiceEvent(AutomationServiceEvent event) {
    if (_disposed) {
      return;
    }
    switch (event) {
      case AutomationTaskChangedEvent(:final task):
        if (task.state == AutomationTaskState.deleted) {
          final next = _state.tasks
              .where((candidate) => candidate.taskId != task.taskId)
              .toList(growable: false);
          final deletedSelected = _state.selectedTaskId == task.taskId;
          final selection = deletedSelected
              ? (next.isEmpty ? null : next.first.taskId)
              : _state.selectedTaskId;
          _emit(
            _state.copyWith(
              tasks: next,
              selectedTaskId: selection,
              runs: deletedSelected ? const <AutomationRun>[] : null,
              selectedRunId: deletedSelected ? null : _state.selectedRunId,
            ),
          );
          if (deletedSelected && selection != null) {
            unawaited(_reloadRunsAfterExternalDelete(selection));
          }
        } else {
          _upsertTask(task);
        }
      case AutomationRunChangedEvent(:final run):
        _upsertRun(run);
      case AutomationForegroundChangedEvent(:final foreground):
        _emit(_state.copyWith(foreground: foreground));
      case AutomationServiceErrorEvent(:final message):
        _emit(_state.copyWith(error: message));
    }
  }

  Future<void> _reloadRunsAfterExternalDelete(AutomationTaskId taskId) async {
    try {
      final runs = await service.listRuns(taskId);
      if (_disposed || _state.selectedTaskId != taskId) return;
      _emit(
        _state.copyWith(
          runs: runs,
          selectedRunId: runs.isEmpty ? null : runs.first.runId,
        ),
      );
    } on AutomationException catch (error) {
      if (!_disposed && _state.selectedTaskId == taskId) {
        _emit(_state.copyWith(error: error.error.message));
      }
    } on Object {
      if (!_disposed && _state.selectedTaskId == taskId) {
        _emit(
          _state.copyWith(
            error: 'Не удалось загрузить историю выбранной задачи.',
          ),
        );
      }
    }
  }

  void _upsertTask(AutomationTask task) {
    final next = List<AutomationTask>.of(_state.tasks);
    final index = next.indexWhere(
      (candidate) => candidate.taskId == task.taskId,
    );
    if (index < 0) {
      next.add(task);
    } else {
      next[index] = task;
    }
    final sorted = _sortedTasks(next);
    _emit(
      _state.copyWith(
        tasks: sorted,
        selectedTaskId:
            _state.selectedTaskId ??
            (sorted.isEmpty ? null : sorted.first.taskId),
      ),
    );
  }

  void _upsertRun(AutomationRun run) {
    if (_state.selectedTaskId != run.taskId) {
      return;
    }
    final next = List<AutomationRun>.of(_state.runs);
    final index = next.indexWhere((candidate) => candidate.runId == run.runId);
    if (index < 0) {
      next.add(run);
    } else {
      next[index] = run;
    }
    next.sort(_compareRuns);
    _emit(
      _state.copyWith(
        runs: next,
        selectedRunId: _state.selectedRunId ?? run.runId,
      ),
    );
  }

  AutomationTask? _taskOrNull(AutomationTaskId taskId) {
    for (final task in _state.tasks) {
      if (task.taskId == taskId) {
        return task;
      }
    }
    return null;
  }

  AutomationTaskId? _liveSelection(List<AutomationTask> tasks) {
    if (tasks.isEmpty) {
      return null;
    }
    final current = _state.selectedTaskId;
    if (current != null && tasks.any((task) => task.taskId == current)) {
      return current;
    }
    return tasks.first.taskId;
  }

  AutomationRunId? _keepRunSelection(List<AutomationRun> runs) {
    if (runs.isEmpty) {
      return null;
    }
    final current = _state.selectedRunId;
    if (current != null && runs.any((run) => run.runId == current)) {
      return current;
    }
    return runs.first.runId;
  }

  void _emit(TasksState next) {
    if (_disposed) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  static List<AutomationTask> _sortedTasks(Iterable<AutomationTask> tasks) {
    final sorted = tasks.toList(growable: false)
      ..sort((left, right) {
        final byState = _taskPriority(
          left.state,
        ).compareTo(_taskPriority(right.state));
        if (byState != 0) {
          return byState;
        }
        final byUpdated = right.updatedAt.compareTo(left.updatedAt);
        if (byUpdated != 0) {
          return byUpdated;
        }
        return left.taskId.value.compareTo(right.taskId.value);
      });
    return List<AutomationTask>.unmodifiable(sorted);
  }

  static int _compareRuns(AutomationRun left, AutomationRun right) {
    final bySchedule = right.scheduledAt.compareTo(left.scheduledAt);
    return bySchedule != 0
        ? bySchedule
        : right.runId.value.compareTo(left.runId.value);
  }

  static int _taskPriority(AutomationTaskState state) => switch (state) {
    AutomationTaskState.proposed => 0,
    AutomationTaskState.active => 1,
    AutomationTaskState.paused => 2,
    AutomationTaskState.completed => 3,
    AutomationTaskState.deleted => 4,
  };

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_events.cancel());
    super.dispose();
  }
}

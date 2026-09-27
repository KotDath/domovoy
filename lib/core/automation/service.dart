import 'dart:async';

import 'clock.dart';
import 'errors.dart';
import 'events.dart';
import 'executor.dart';
import 'ids.dart';
import 'limits.dart';
import 'repository.dart';
import 'run.dart';
import 'schedule.dart';
import 'task.dart';
import 'time_zones.dart';

/// Result of starting a manual run.
final class AutomationRunHandle {
  const AutomationRunHandle({
    required this.runId,
    required this.taskId,
    required this.trigger,
    required this.status,
    required this.scheduledAt,
    required this.done,
  });

  final AutomationRunId runId;
  final AutomationTaskId taskId;
  final AutomationRunTrigger trigger;
  final AutomationRunStatus status;
  final DateTime scheduledAt;

  /// Settles with the terminal run record.
  final Future<AutomationRun> done;
}

/// Application service that owns the automation schedule of this device.
///
/// UI (B8) and the `automation` MCP server (B6) call the same instance; there
/// is no second scheduler and no second task store.
///
/// Guarantees:
/// - one catch-up on reopen/resume: at most one fresh run, older missed periods
///   are aggregated as skipped and never replayed one by one;
/// - `(taskId, scheduledAt)` idempotency: a period never runs twice, including
///   after a crash or a late timer;
/// - no overlap: while a task has an active run, further periods are recorded
///   as `skipped` and manual starts are refused;
/// - manual runs never shift the planned `nextDueAt`;
/// - a scheduled run may never create tasks or start other tasks.
final class AutomationService {
  AutomationService({
    required this.tasks,
    required this.runs,
    required this.executor,
    required this.timeZones,
    required this.clock,
    AutomationLimits limits = const AutomationLimits(),
    this.delivery,
    AutomationIdGenerator? ids,
  }) : limits = limits.validate(),
       ids = ids ?? RandomAutomationIdGenerator();

  final AutomationTaskRepository tasks;
  final AutomationRunRepository runs;
  final AutomationRunExecutor executor;
  final AutomationTimeZones timeZones;
  final AutomationClock clock;
  final AutomationLimits limits;
  final AutomationResultDelivery? delivery;
  final AutomationIdGenerator ids;

  final StreamController<AutomationServiceEvent> _events =
      StreamController<AutomationServiceEvent>.broadcast();

  AutomationTimer? _timer;
  var _started = false;
  var _foreground = true;
  var _disposed = false;
  Future<void>? _tickFuture;
  final Map<String, _ActiveRun> _active = <String, _ActiveRun>{};
  final Set<Future<void>> _pending = <Future<void>>{};
  var _scheduledRunsActive = 0;

  /// Task/run/foreground events for the tasks UI.
  Stream<AutomationServiceEvent> get events => _events.stream;

  bool get isRunning => _started;

  bool get isForeground => _foreground;

  /// True while a scheduled or catch-up run executes in this process.
  ///
  /// Used as a defense-in-depth guard by the `automation` MCP server: while a
  /// scheduled run is active, `run_task_now` from an agent tool is refused even
  /// if the tool somehow reached the server.
  bool get isScheduledRunActive => _scheduledRunsActive > 0;

  /// Replays storage, marks runs left by a crashed process as `interrupted`,
  /// and runs one catch-up.
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _foreground = true;
    await _markInterruptedRuns();
    await tick();
  }

  /// Stops timers and cancels active runs (app shutdown, foreground loss).
  Future<void> stop() async {
    if (!_started) {
      return;
    }
    _started = false;
    _timer?.cancel();
    _timer = null;
    for (final active in _active.values.toList(growable: false)) {
      active.cancel(reason: _CancellationReason.background);
    }
    await waitForIdle();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    await stop();
    _disposed = true;
    await _events.close();
  }

  /// Waits until every started run settled (tests and shutdown).
  Future<void> waitForIdle() async {
    while (_pending.isNotEmpty) {
      final pending = List<Future<void>>.of(_pending);
      await Future.wait(pending);
    }
  }

  /// Pauses or resumes timers; mobile compositions call this from the app
  /// lifecycle. A running execution is cancelled and recorded as interrupted.
  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) {
      return;
    }
    _foreground = foreground;
    _emitEvent(AutomationForegroundChangedEvent(foreground));
    if (!foreground) {
      _timer?.cancel();
      _timer = null;
      for (final active in _active.values.toList(growable: false)) {
        active.cancel(reason: _CancellationReason.background);
      }
      return;
    }
    unawaited(tick());
  }

  /// Creates a task.
  ///
  /// [AutomationCallOrigin.agentTool] always produces a `proposed` task that
  /// waits for a human confirmation; [AutomationCallOrigin.scheduledRun] is
  /// denied intrinsically.
  Future<AutomationTask> createTask(
    AutomationTaskDraft draft, {
    AutomationCallOrigin origin = AutomationCallOrigin.human,
  }) async {
    _requireCreationOrigin(origin);
    draft.schedule.validate(timeZones);
    final now = clock.nowUtc();
    final alive = await tasks.listTasks(includeDeleted: true);
    if (alive.where((task) => task.isAlive).length >= limits.maxTasks) {
      throwAutomation(
        AutomationErrorKind.limits,
        'Достигнут лимит задач (${limits.maxTasks}).',
      );
    }
    final state = origin == AutomationCallOrigin.agentTool
        ? AutomationTaskState.proposed
        : AutomationTaskState.active;
    final nextDueAt = _requireNextOccurrence(draft.schedule, now);
    final task = AutomationTask(
      taskId: ids.nextTaskId().value,
      name: draft.name,
      prompt: draft.prompt,
      schedule: draft.schedule,
      model: draft.model,
      allowedToolIds: draft.allowedToolIds,
      delivery: draft.delivery,
      state: state,
      origin: origin == AutomationCallOrigin.agentTool
          ? AutomationTaskOrigin.agent
          : AutomationTaskOrigin.human,
      nextDueAt: nextDueAt,
      createdAt: now,
      updatedAt: now,
    ).validateAgainst(limits);
    final created = await tasks.createTask(task);
    _emitTask(created);
    await _armTimer();
    return created;
  }

  /// Human confirmation of an agent proposal: `proposed` → `active`.
  Future<AutomationTask> confirmTask(
    AutomationTaskId taskId, {
    int? expectedRevision,
  }) async {
    final task = await _requireTask(taskId);
    if (task.state != AutomationTaskState.proposed) {
      throwAutomation(
        AutomationErrorKind.conflict,
        'Подтвердить можно только задачу-предложение; текущее состояние '
        '${task.state.name}.',
      );
    }
    final now = clock.nowUtc();
    final nextDueAt = _requireNextOccurrence(task.schedule, now);
    return _saveTask(
      task,
      task.nextRevision(
        state: AutomationTaskState.active,
        nextDueAt: nextDueAt,
        now: now,
      ),
      expectedRevision: expectedRevision ?? task.revision,
    );
  }

  /// All tasks, newest first; tombstones are excluded unless requested.
  Future<List<AutomationTask>> listTasks({
    bool includeDeleted = false,
    AutomationTaskState? state,
  }) async {
    final all = await tasks.listTasks(includeDeleted: includeDeleted);
    if (state == null) {
      return all;
    }
    return List<AutomationTask>.unmodifiable(
      all.where((task) => task.state == state),
    );
  }

  Future<AutomationTask?> findTask(AutomationTaskId taskId) async {
    final task = await tasks.findTask(taskId);
    if (task == null || !task.state.isAlive) {
      return null;
    }
    return task;
  }

  /// Pauses or resumes a task. Pausing clears `nextDueAt`, so periods that
  /// pass while paused are never replayed; resuming arms the next future
  /// occurrence.
  Future<AutomationTask> setPaused(
    AutomationTaskId taskId,
    bool paused, {
    int? expectedRevision,
  }) async {
    final task = await _requireTask(taskId);
    final now = clock.nowUtc();
    if (paused) {
      if (task.state == AutomationTaskState.paused) {
        return task;
      }
      if (task.state != AutomationTaskState.active) {
        throwAutomation(
          AutomationErrorKind.conflict,
          'Приостановить можно только активную задачу; текущее состояние '
          '${task.state.name}.',
        );
      }
      return _saveTask(
        task,
        task.nextRevision(
          state: AutomationTaskState.paused,
          nextDueAt: null,
          now: now,
        ),
        expectedRevision: expectedRevision ?? task.revision,
      );
    }
    if (task.state == AutomationTaskState.active) {
      return task;
    }
    if (task.state != AutomationTaskState.paused) {
      throwAutomation(
        AutomationErrorKind.conflict,
        'Возобновить можно только приостановленную задачу; текущее состояние '
        '${task.state.name}.',
      );
    }
    final nextDueAt = _requireNextOccurrence(task.schedule, now);
    return _saveTask(
      task,
      task.nextRevision(
        state: AutomationTaskState.active,
        nextDueAt: nextDueAt,
        now: now,
      ),
      expectedRevision: expectedRevision ?? task.revision,
    );
  }

  /// Tombstone of a task; an executing run is cancelled and interrupted.
  Future<AutomationTask> deleteTask(
    AutomationTaskId taskId, {
    int? expectedRevision,
  }) async {
    final task = await _requireTask(taskId);
    _active[task.taskId.value]?.cancel(reason: _CancellationReason.deleted);
    final now = clock.nowUtc();
    return _saveTask(
      task,
      task.nextRevision(
        state: AutomationTaskState.deleted,
        nextDueAt: null,
        now: now,
      ),
      expectedRevision: expectedRevision ?? task.revision,
    );
  }

  /// Starts a manual run now; the planned `nextDueAt` does not move.
  ///
  /// Refused for proposals (a human must confirm first), for a task that is
  /// already running, and for every call coming from a scheduled run.
  Future<AutomationRunHandle> runTaskNow(
    AutomationTaskId taskId, {
    AutomationCallOrigin origin = AutomationCallOrigin.human,
    int? expectedRevision,
  }) async {
    if (origin == AutomationCallOrigin.scheduledRun) {
      throwAutomation(
        AutomationErrorKind.denied,
        'Запланированный запуск не может запускать другие задачи.',
      );
    }
    if (origin == AutomationCallOrigin.agentTool && isScheduledRunActive) {
      throwAutomation(
        AutomationErrorKind.denied,
        'Инструмент run_task_now недоступен, пока выполняется запланированный '
        'запуск.',
      );
    }
    final task = await _requireTask(taskId);
    if (task.state == AutomationTaskState.deleted) {
      throwAutomation(AutomationErrorKind.notFound, 'Задача удалена.');
    }
    if (task.state == AutomationTaskState.proposed) {
      throwAutomation(
        AutomationErrorKind.denied,
        'Задача-предложение не запускается, пока человек не подтвердит её в '
        'разделе «Задачи».',
      );
    }
    if (expectedRevision != null && task.revision != expectedRevision) {
      throwAutomation(
        AutomationErrorKind.revisionMismatch,
        'Ревизия задачи изменилась: ожидалась $expectedRevision, сейчас '
        '${task.revision}.',
      );
    }
    if (_active.containsKey(task.taskId.value)) {
      throwAutomation(
        AutomationErrorKind.noOverlap,
        'Задача уже выполняется; дождитесь завершения текущего запуска.',
      );
    }
    final now = clock.nowUtc();
    final run = await _createRunRecord(
      task,
      scheduledAt: now,
      trigger: AutomationRunTrigger.manual,
      startedAt: now,
    );
    _launchRun(task, run);
    return AutomationRunHandle(
      runId: run.runId,
      taskId: run.taskId,
      trigger: run.trigger,
      status: run.status,
      scheduledAt: run.scheduledAt,
      done: _active[task.taskId.value]!.done.future,
    );
  }

  /// Run history of one task, newest first.
  Future<List<AutomationRun>> listRuns(
    AutomationTaskId taskId, {
    int limit = 50,
  }) {
    if (limit <= 0 || limit > limits.maxRunHistoryPage) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'limit должен быть от 1 до ${limits.maxRunHistoryPage}.',
      );
    }
    return runs.listRuns(taskId: taskId, limit: limit);
  }

  Future<AutomationRun?> findRun(AutomationRunId runId) => runs.findRun(runId);

  /// Next [count] occurrences of [schedule] from now, for the task editor and
  /// the `create_task` proposal preview.
  List<DateTime> previewOccurrences(
    AutomationSchedule schedule, {
    int count = 3,
  }) => schedule.nextOccurrences(
    afterUtc: clock.nowUtc(),
    zones: timeZones,
    count: count,
  );

  /// One scheduler tick: fires due tasks, catches up missed periods, records
  /// overlaps as skipped and re-arms the timer.
  ///
  /// Concurrent calls coalesce into a single tick.
  Future<void> tick() {
    if (!_started || !_foreground || _disposed) {
      return Future<void>.value();
    }
    final inFlight = _tickFuture;
    if (inFlight != null) {
      return inFlight;
    }
    late final Future<void> future;
    future = _performTick().whenComplete(() {
      if (identical(_tickFuture, future)) {
        _tickFuture = null;
      }
    });
    _tickFuture = future;
    return future;
  }

  Future<void> _performTick() async {
    final now = clock.nowUtc();
    late final List<AutomationTask> all;
    try {
      all = await tasks.listTasks();
    } on AutomationException catch (error) {
      _emitError(null, error.error);
      return;
    }
    for (final task in all) {
      if (!task.isActive) {
        continue;
      }
      try {
        await _processDueTask(task, now);
      } on AutomationException catch (error) {
        _emitError(task.taskId, error.error);
      } on Object {
        _emitError(
          task.taskId,
          AutomationError(
            kind: AutomationErrorKind.internal,
            message:
                'Не удалось обработать задачу; следующая попытка — на '
                'следующем тике.',
          ),
        );
      }
    }
    await _armTimer();
  }

  Future<void> _processDueTask(AutomationTask task, DateTime now) async {
    final due = task.nextDueAt;
    if (due == null || due.isAfter(now)) {
      return;
    }
    final last = task.schedule.lastAtOrBefore(now, timeZones);
    if (last == null) {
      // Defensive: no occurrence at all before now means the schedule is
      // exhausted; finish the task instead of retrying forever.
      await _saveTaskState(task, AutomationTaskState.completed, null, now);
      return;
    }
    final consumed = await runs.findRunBySchedule(task.taskId, last);
    if (task.schedule is OneShotSchedule) {
      if (consumed == null) {
        await _startDueRun(
          task,
          scheduledAt: due,
          trigger: AutomationRunTrigger.scheduled,
          aggregatedSkippedCount: 0,
          skippedFrom: null,
          skippedTruncated: false,
          now: now,
        );
      }
      await _saveTaskState(task, AutomationTaskState.completed, null, now);
      return;
    }
    final next = task.schedule.nextAfter(last, timeZones);
    if (consumed != null) {
      // The freshest missed period was already consumed (for example by an
      // interrupted run): never replay its side effects.
      await _saveTaskState(
        task,
        next == null
            ? AutomationTaskState.completed
            : AutomationTaskState.active,
        next,
        now,
      );
      return;
    }
    final skipped = await _countMissedPeriods(task, from: due, to: last);
    final isCatchUp = skipped.count > 0 || last != due;
    if (_active.containsKey(task.taskId.value)) {
      // No overlap: the period is recorded as skipped without a queue.
      await _createRunRecord(
        task,
        scheduledAt: last,
        trigger: isCatchUp
            ? AutomationRunTrigger.catchUp
            : AutomationRunTrigger.scheduled,
        startedAt: null,
        status: AutomationRunStatus.skipped,
        finishedAt: now,
        error: AutomationRunError(
          kind: AutomationRunErrorKind.noOverlap,
          message:
              'Предыдущий запуск задачи ещё выполняется; период пропущен '
              'без очереди.',
        ),
        aggregatedSkippedCount: skipped.count,
        skippedFrom: skipped.count > 0 ? skipped.from : null,
        skippedTruncated: skipped.truncated,
      );
      await _saveTaskState(
        task,
        next == null
            ? AutomationTaskState.completed
            : AutomationTaskState.active,
        next,
        now,
      );
      return;
    }
    await _startDueRun(
      task,
      scheduledAt: last,
      trigger: isCatchUp
          ? AutomationRunTrigger.catchUp
          : AutomationRunTrigger.scheduled,
      aggregatedSkippedCount: skipped.count,
      skippedFrom: skipped.count > 0 ? skipped.from : null,
      skippedTruncated: skipped.truncated,
      now: now,
    );
    await _saveTaskState(
      task,
      next == null ? AutomationTaskState.completed : AutomationTaskState.active,
      next,
      now,
    );
  }

  /// Persists the `running` record, saves the advanced task state and launches
  /// the agent session.
  Future<void> _startDueRun(
    AutomationTask task, {
    required DateTime scheduledAt,
    required AutomationRunTrigger trigger,
    required int aggregatedSkippedCount,
    required DateTime? skippedFrom,
    required bool skippedTruncated,
    required DateTime now,
  }) async {
    final run = await _createRunRecord(
      task,
      scheduledAt: scheduledAt,
      trigger: trigger,
      startedAt: now,
      aggregatedSkippedCount: aggregatedSkippedCount,
      skippedFrom: skippedFrom,
      skippedTruncated: skippedTruncated,
    );
    _launchRun(task, run);
  }

  Future<_MissedPeriods> _countMissedPeriods(
    AutomationTask task, {
    required DateTime from,
    required DateTime to,
  }) async {
    final existing = await _scheduledKeys(task.taskId);
    var count = 0;
    var truncated = false;
    var cursor = from;
    while (cursor.isBefore(to)) {
      if (count >= limits.maxAggregatedSkipped) {
        truncated = true;
        break;
      }
      if (!_containsInstant(existing, cursor)) {
        count += 1;
      }
      final next = task.schedule.nextAfter(cursor, timeZones);
      if (next == null || !next.isBefore(to)) {
        break;
      }
      cursor = next;
    }
    return _MissedPeriods(count: count, from: from, truncated: truncated);
  }

  /// Scheduled instants already occupied by a run of this task.
  Future<Set<DateTime>> _scheduledKeys(AutomationTaskId taskId) async {
    late final List<AutomationRun> history;
    try {
      history = await runs.listRuns(
        taskId: taskId,
        limit: limits.maxRunHistoryPage,
      );
    } on AutomationException {
      return const <DateTime>{};
    }
    return <DateTime>{for (final run in history) run.scheduledAt};
  }

  bool _containsInstant(Set<DateTime> values, DateTime instant) {
    for (final value in values) {
      if (value.isAtSameMomentAs(instant)) {
        return true;
      }
    }
    return false;
  }

  Future<AutomationRun> _createRunRecord(
    AutomationTask task, {
    required DateTime scheduledAt,
    required AutomationRunTrigger trigger,
    required DateTime? startedAt,
    AutomationRunStatus status = AutomationRunStatus.running,
    DateTime? finishedAt,
    AutomationRunError? error,
    int aggregatedSkippedCount = 0,
    DateTime? skippedFrom,
    bool skippedTruncated = false,
  }) async {
    final run = AutomationRun(
      runId: ids.nextRunId().value,
      taskId: task.taskId.value,
      taskRevision: task.revision,
      trigger: trigger,
      status: status,
      scheduledAt: scheduledAt,
      startedAt: startedAt,
      finishedAt: finishedAt,
      model: task.model,
      allowedToolIds: task.allowedToolIds,
      error: error,
      aggregatedSkippedCount: aggregatedSkippedCount,
      skippedFrom: skippedFrom,
      skippedTruncated: skippedTruncated,
    ).validateAgainst(limits);
    final created = await runs.appendRun(run, expectedRevision: 0);
    _emitEvent(AutomationRunChangedEvent(created));
    return created;
  }

  void _launchRun(AutomationTask task, AutomationRun run) {
    final cancellation = _ActiveRunCancellation();
    final completer = Completer<AutomationRun>();
    final active = _ActiveRun(
      run: run,
      cancellation: cancellation,
      done: completer,
    );
    _active[task.taskId.value] = active;
    final scheduled = run.trigger != AutomationRunTrigger.manual;
    if (scheduled) {
      _scheduledRunsActive += 1;
    }
    late final Future<void> future;
    future = () async {
      try {
        final terminal = await _executeRun(task, run, active);
        completer.complete(terminal);
      } on Object {
        // The run record itself failed to persist; the error stays visible on
        // the service event stream and the handle settles with the run at its
        // last persisted revision.
        AutomationRun terminal = run;
        try {
          terminal = await _finishRun(
            run,
            status: AutomationRunStatus.failed,
            error: AutomationRunError(
              kind: AutomationRunErrorKind.internal,
              message:
                  'Внутренняя ошибка планировщика; запуск завершён видимо.',
            ),
          );
        } on Object {
          _emitError(
            task.taskId,
            AutomationError(
              kind: AutomationErrorKind.persistence,
              message: 'Не удалось сохранить итог запуска.',
            ),
          );
        }
        if (!completer.isCompleted) {
          completer.complete(terminal);
        }
      } finally {
        _active.remove(task.taskId.value);
        if (scheduled) {
          _scheduledRunsActive -= 1;
        }
        _pending.remove(future);
      }
    }();
    _pending.add(future);
  }

  Future<AutomationRun> _executeRun(
    AutomationTask task,
    AutomationRun run,
    _ActiveRun active,
  ) async {
    AutomationRunAvailability availability;
    try {
      availability = await executor.availability(task);
    } on Object {
      availability = const AutomationRunAvailability.unavailable(
        AutomationRunErrorKind.internal,
        'Проверка доступности модели и инструментов не удалась.',
      );
    }
    if (!availability.isAvailable) {
      return _finishRun(
        run,
        status: AutomationRunStatus.failed,
        error: AutomationRunError(
          kind: availability.kind ?? AutomationRunErrorKind.unavailable,
          message: availability.message ?? 'Запуск недоступен.',
        ),
      );
    }
    final request = AutomationRunRequest(
      task: task,
      runId: run.runId.value,
      trigger: run.trigger,
      scheduledAt: run.scheduledAt,
    );
    final deadline = clock.schedule(limits.run.maxDuration, () {
      active.timeout = true;
      active.cancel(reason: _CancellationReason.timeout);
    });
    AutomationRunOutcome outcome;
    try {
      outcome = await executor.execute(
        request,
        cancellation: active.cancellation,
      );
    } on Object {
      outcome = AutomationRunOutcome(
        status: AutomationRunStatus.failed,
        error: AutomationRunError(
          kind: AutomationRunErrorKind.internal,
          message: 'Исполнитель запуска завершился ошибкой.',
        ),
      );
    } finally {
      deadline.cancel();
    }
    if (active.cancellation.isCancelled) {
      if (active.timeout) {
        return _finishRun(
          run,
          status: AutomationRunStatus.failed,
          error: AutomationRunError(
            kind: AutomationRunErrorKind.timeout,
            message:
                'Запуск остановлен по лимиту времени '
                '(${limits.run.maxDuration.inMinutes} мин).',
          ),
          resultText: outcome.resultText,
          trace: outcome.trace,
          modelTurns: outcome.modelTurns,
          toolCalls: outcome.toolCalls,
        );
      }
      return _finishRun(
        run,
        status: AutomationRunStatus.interrupted,
        error: AutomationRunError(
          kind: AutomationRunErrorKind.interrupted,
          message: active.cancellation.reason == _CancellationReason.background
              ? 'Запуск прерван: приложение ушло в фон. Побочные эффекты не '
                    'повторяются.'
              : 'Запуск прерван до завершения.',
        ),
        resultText: outcome.resultText,
        trace: outcome.trace,
        modelTurns: outcome.modelTurns,
        toolCalls: outcome.toolCalls,
      );
    }
    final status = outcome.status == AutomationRunStatus.running
        ? AutomationRunStatus.failed
        : outcome.status;
    return _finishRun(
      run,
      status: status,
      error: outcome.error,
      resultText: outcome.resultText,
      trace: outcome.trace,
      modelTurns: outcome.modelTurns,
      toolCalls: outcome.toolCalls,
    );
  }

  Future<AutomationRun> _finishRun(
    AutomationRun run, {
    required AutomationRunStatus status,
    AutomationRunError? error,
    String? resultText,
    Iterable<AutomationToolTraceEntry>? trace,
    int? modelTurns,
    int? toolCalls,
  }) async {
    final terminalCandidate = run
        .copyWith(
          status: status,
          finishedAt: clock.nowUtc(),
          error: error,
          resultText: _clipResult(resultText),
          trace: _clipTrace(trace),
          modelTurns: modelTurns,
          toolCalls: toolCalls,
          revision: run.revision + 1,
        )
        .validateAgainst(limits);
    var terminal = await runs.appendRun(
      terminalCandidate,
      expectedRevision: run.revision,
    );
    _emitEvent(AutomationRunChangedEvent(terminal));
    // Delivery runs after the terminal record exists, so a chat card can
    // always reference a persisted run. The delivery update is a second
    // append; the replay keeps the last revision of the run stream.
    final delivered = await _deliver(terminal, terminalCandidate);
    if (delivered != null) {
      terminal = await runs.appendRun(
        terminal.copyWith(revision: terminal.revision + 1, delivery: delivered),
        expectedRevision: terminal.revision,
      );
      _emitEvent(AutomationRunChangedEvent(terminal));
    }
    return terminal;
  }

  Future<AutomationDeliveryResult?> _deliver(
    AutomationRun persisted,
    AutomationRun reference,
  ) async {
    final task = await tasks.findTask(persisted.taskId);
    if (task == null) {
      return null;
    }
    if (task.delivery.kind == AutomationDeliveryKind.tasks) {
      return AutomationDeliveryResult(
        delivered: true,
        reference: persisted.runId.runRef,
      );
    }
    final sink = delivery;
    if (sink == null) {
      return const AutomationDeliveryResult(
        delivered: false,
        error:
            'Доставка в чат недоступна в этой сборке; результат сохранён в '
            'разделе «Задачи».',
      );
    }
    try {
      return await sink.deliver(task: task, run: reference);
    } on Object {
      return const AutomationDeliveryResult(
        delivered: false,
        error: 'Доставка результата в чат не удалась.',
      );
    }
  }

  Future<void> _markInterruptedRuns() async {
    final now = clock.nowUtc();
    late final List<AutomationRun> running;
    try {
      running = await runs.listRunningRuns();
    } on AutomationException {
      return;
    }
    for (final run in running) {
      try {
        final terminal = await runs.appendRun(
          run.copyWith(
            status: AutomationRunStatus.interrupted,
            finishedAt: now,
            error: AutomationRunError(
              kind: AutomationRunErrorKind.interrupted,
              message:
                  'Запуск остался незавершённым после закрытия приложения; '
                  'побочные эффекты не повторяются.',
            ),
            revision: run.revision + 1,
          ),
          expectedRevision: run.revision,
        );
        _emitEvent(AutomationRunChangedEvent(terminal));
      } on AutomationException {
        // Another writer finished the run first; nothing to repair.
      }
    }
  }

  Future<void> _saveTaskState(
    AutomationTask task,
    AutomationTaskState state,
    DateTime? nextDueAt,
    DateTime now,
  ) async {
    await _saveTask(
      task,
      task.nextRevision(state: state, nextDueAt: nextDueAt, now: now),
      expectedRevision: task.revision,
    );
  }

  Future<AutomationTask> _saveTask(
    AutomationTask current,
    AutomationTask next, {
    required int expectedRevision,
  }) async {
    if (expectedRevision != current.revision) {
      throwAutomation(
        AutomationErrorKind.revisionMismatch,
        'Ревизия задачи изменилась: ожидалась $expectedRevision, сейчас '
        '${current.revision}.',
      );
    }
    final saved = await tasks.saveTask(
      next,
      expectedRevision: expectedRevision,
    );
    _emitTask(saved);
    await _armTimer();
    return saved;
  }

  Future<AutomationTask> _requireTask(AutomationTaskId taskId) async {
    final task = await tasks.findTask(taskId);
    if (task == null || !task.state.isAlive) {
      throwAutomation(
        AutomationErrorKind.notFound,
        'Задача ${taskId.value} не найдена.',
      );
    }
    return task;
  }

  DateTime _requireNextOccurrence(AutomationSchedule schedule, DateTime now) {
    final next = schedule.nextAfter(now, timeZones);
    if (next == null) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'У расписания нет следующего момента; выберите другую дату или '
        'выражение.',
      );
    }
    return next;
  }

  void _requireCreationOrigin(AutomationCallOrigin origin) {
    if (origin == AutomationCallOrigin.scheduledRun) {
      throwAutomation(
        AutomationErrorKind.denied,
        'Запланированный запуск не может создавать новые задачи.',
      );
    }
  }

  Future<void> _armTimer() async {
    _timer?.cancel();
    _timer = null;
    if (!_started || !_foreground || _disposed) {
      return;
    }
    late final List<AutomationTask> all;
    try {
      all = await tasks.listTasks();
    } on AutomationException {
      return;
    }
    DateTime? earliest;
    for (final task in all) {
      final due = task.nextDueAt;
      if (!task.isActive || due == null) {
        continue;
      }
      if (earliest == null || due.isBefore(earliest)) {
        earliest = due;
      }
    }
    if (earliest == null) {
      return;
    }
    var delay = earliest.difference(clock.nowUtc());
    if (delay < const Duration(milliseconds: 50)) {
      delay = const Duration(milliseconds: 50);
    }
    _timer = clock.schedule(delay, () {
      _timer = null;
      unawaited(tick());
    });
  }

  String? _clipResult(String? text) {
    if (text == null) {
      return null;
    }
    final max = limits.run.maxResultCharacters;
    if (text.length <= max) {
      return text;
    }
    return '${text.substring(0, max - 1)}…';
  }

  List<AutomationToolTraceEntry>? _clipTrace(
    Iterable<AutomationToolTraceEntry>? trace,
  ) {
    if (trace == null) {
      return null;
    }
    final entries = trace.toList(growable: false);
    if (entries.length <= limits.maxTraceEntries) {
      return entries;
    }
    final kept = entries.take(limits.maxTraceEntries - 1).toList()
      ..add(
        AutomationToolTraceEntry(
          name: 'trace',
          status: AutomationToolTraceStatus.failed,
          detail:
              'Трасса усечена: ещё ${entries.length - limits.maxTraceEntries + 1} '
              'вызовов.',
        ),
      );
    return kept;
  }

  void _emitEvent(AutomationServiceEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void _emitTask(AutomationTask task) {
    _emitEvent(AutomationTaskChangedEvent(task));
  }

  void _emitError(AutomationTaskId? taskId, AutomationError error) {
    _emitEvent(
      AutomationServiceErrorEvent(
        taskId: taskId,
        kind: error.kind,
        message: error.message,
      ),
    );
  }
}

final class _MissedPeriods {
  const _MissedPeriods({
    required this.count,
    required this.from,
    required this.truncated,
  });

  final int count;
  final DateTime from;
  final bool truncated;
}

enum _CancellationReason { background, timeout, deleted }

final class _ActiveRunCancellation implements AutomationResultCancellation {
  final Completer<void> _cancelled = Completer<void>();
  var _isCancelled = false;
  _CancellationReason? reason;

  @override
  bool get isCancelled => _isCancelled;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  @override
  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _cancelled.complete();
  }
}

final class _ActiveRun {
  _ActiveRun({
    required this.run,
    required this.cancellation,
    required this.done,
  });

  final AutomationRun run;
  final _ActiveRunCancellation cancellation;
  final Completer<AutomationRun> done;
  var timeout = false;

  _CancellationReason? get reason => cancellation.reason;

  void cancel({required _CancellationReason reason}) {
    timeout = reason == _CancellationReason.timeout;
    cancellation.reason = reason;
    cancellation.cancel();
  }
}

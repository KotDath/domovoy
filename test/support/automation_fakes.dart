import 'dart:async';

import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/core/llm/llm.dart';

/// Deterministic wall clock and timer queue for scheduler tests.
///
/// Timers fire when [advance]/[setNow] moves time past their due instant, in
/// due order; a callback that arms a new timer is queued for the next due
/// instant. Nothing ever fires in real time.
final class FakeAutomationClock implements AutomationClock {
  FakeAutomationClock(DateTime start) : _now = start.toUtc();

  DateTime _now;
  final List<_FakeAutomationTimer> _timers = <_FakeAutomationTimer>[];

  DateTime get now => _now;

  int get activeTimerCount => _timers.where((timer) => !timer.cancelled).length;

  @override
  DateTime nowUtc() => _now;

  @override
  AutomationTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeAutomationTimer(
      due: _now.add(delay),
      callback: callback,
    );
    _timers.add(timer);
    return timer;
  }

  /// Advances the clock and fires every timer that became due.
  void advance(Duration duration) => setNow(_now.add(duration));

  /// Moves the clock to [instant] and fires every timer that became due.
  void setNow(DateTime instant) {
    _now = instant.toUtc();
    var fired = true;
    while (fired) {
      fired = false;
      final due =
          _timers
              .where((timer) => !timer.cancelled && !timer.due.isAfter(_now))
              .toList()
            ..sort((a, b) => a.due.compareTo(b.due));
      for (final timer in due) {
        if (timer.cancelled) {
          continue;
        }
        timer.cancelled = true;
        timer.callback();
        fired = true;
      }
      _timers.removeWhere((timer) => timer.cancelled);
    }
  }
}

final class _FakeAutomationTimer implements AutomationTimer {
  _FakeAutomationTimer({required this.due, required this.callback});

  final DateTime due;
  final void Function() callback;
  var cancelled = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;
}

/// One offset transition of a [FakeZone].
final class FakeZoneTransition {
  const FakeZoneTransition({required this.atUtc, required this.offsetAfter});

  final DateTime atUtc;
  final Duration offsetAfter;
}

/// Deterministic IANA-like zone with explicit offset transitions.
final class FakeZone {
  FakeZone({
    required this.id,
    required this.standardOffset,
    List<FakeZoneTransition> transitions = const <FakeZoneTransition>[],
  }) : transitions = List<FakeZoneTransition>.unmodifiable(
         transitions.toList()..sort((a, b) => a.atUtc.compareTo(b.atUtc)),
       );

  final String id;
  final Duration standardOffset;
  final List<FakeZoneTransition> transitions;

  Duration offsetAt(DateTime utc) {
    var offset = standardOffset;
    for (final transition in transitions) {
      if (!transition.atUtc.isAfter(utc)) {
        offset = transition.offsetAfter;
      }
    }
    return offset;
  }

  Set<Duration> offsetsAround(DateTime utc) => <Duration>{
    offsetAt(utc.subtract(const Duration(days: 1))),
    offsetAt(utc),
    offsetAt(utc.add(const Duration(days: 1))),
  };
}

/// [AutomationTimeZones] over [FakeZone]s with the same DST semantics as the
/// production adapter: gaps return no instants, folds return two sorted ones.
final class FakeAutomationTimeZones implements AutomationTimeZones {
  FakeAutomationTimeZones(Iterable<FakeZone> zones)
    : _zones = <String, FakeZone>{for (final zone in zones) zone.id: zone};

  final Map<String, FakeZone> _zones;

  @override
  bool isKnownZone(String zoneId) => _zones.containsKey(zoneId.trim());

  @override
  WallClockTime localTime(String zoneId, DateTime utc) {
    final zone = _requireZone(zoneId);
    final local = utc.toUtc().add(zone.offsetAt(utc.toUtc()));
    return WallClockTime(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
  }

  @override
  List<DateTime> resolveLocal(String zoneId, WallClockTime local) {
    final zone = _requireZone(zoneId);
    final approximate = local.asDateTimeFields;
    final instants = <DateTime>[];
    for (final offset in zone.offsetsAround(approximate)) {
      final candidate = approximate.subtract(offset);
      final localAgain = candidate.add(zone.offsetAt(candidate));
      if (localAgain.year == local.year &&
          localAgain.month == local.month &&
          localAgain.day == local.day &&
          localAgain.hour == local.hour &&
          localAgain.minute == local.minute) {
        final utc = candidate.toUtc();
        if (!instants.any((existing) => existing.isAtSameMomentAs(utc))) {
          instants.add(utc);
        }
      }
    }
    instants.sort();
    return List<DateTime>.unmodifiable(instants);
  }

  FakeZone _requireZone(String zoneId) {
    final zone = _zones[zoneId.trim()];
    if (zone == null) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Неизвестный часовой пояс "$zoneId".',
      );
    }
    return zone;
  }
}

/// In-memory [AutomationRepository] with the same revision and idempotency
/// rules as the JSONL store.
final class InMemoryAutomationRepository implements AutomationRepository {
  final Map<String, AutomationTask> _tasks = <String, AutomationTask>{};
  final Map<String, AutomationRun> _runs = <String, AutomationRun>{};
  final List<String> writes = <String>[];

  /// When set, every mutating call throws this error.
  AutomationError? failWrites;

  Iterable<AutomationTask> get tasks => _tasks.values;

  Iterable<AutomationRun> get runs => _runs.values;

  @override
  Future<List<AutomationTask>> listTasks({bool includeDeleted = false}) async {
    final result =
        _tasks.values
            .where((task) => includeDeleted || task.state.isAlive)
            .toList()
          ..sort((a, b) {
            final byCreated = a.createdAt.compareTo(b.createdAt);
            return byCreated != 0
                ? byCreated
                : a.taskId.value.compareTo(b.taskId.value);
          });
    return List<AutomationTask>.unmodifiable(result);
  }

  @override
  Future<AutomationTask?> findTask(AutomationTaskId id) async =>
      _tasks[id.value];

  @override
  Future<AutomationTask> createTask(AutomationTask task) async {
    _maybeFail();
    if (_tasks.containsKey(task.taskId.value)) {
      throwAutomation(
        AutomationErrorKind.conflict,
        'Задача ${task.taskId.value} уже существует.',
      );
    }
    _tasks[task.taskId.value] = task;
    writes.add('task:${task.taskId.value}:${task.revision}');
    return task;
  }

  @override
  Future<AutomationTask> saveTask(
    AutomationTask task, {
    required int expectedRevision,
  }) async {
    _maybeFail();
    final current = _tasks[task.taskId.value];
    if (current == null) {
      throwAutomation(
        AutomationErrorKind.notFound,
        'Задача ${task.taskId.value} не найдена.',
      );
    }
    if (current.revision != expectedRevision) {
      throwAutomation(
        AutomationErrorKind.revisionMismatch,
        'Ревизия задачи изменилась: ожидалась $expectedRevision, сейчас '
        '${current.revision}.',
      );
    }
    if (task.revision != expectedRevision + 1) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Новая ревизия задачи должна быть ${expectedRevision + 1}.',
      );
    }
    _tasks[task.taskId.value] = task;
    writes.add('task:${task.taskId.value}:${task.revision}');
    return task;
  }

  @override
  Future<List<AutomationRun>> listRuns({
    AutomationTaskId? taskId,
    int limit = 200,
    bool includeDeletedTasks = true,
  }) async {
    var result = _runs.values.toList();
    if (taskId != null) {
      result = result.where((run) => run.taskId == taskId).toList();
    }
    result.sort((a, b) {
      final bySchedule = b.scheduledAt.compareTo(a.scheduledAt);
      return bySchedule != 0
          ? bySchedule
          : b.runId.value.compareTo(a.runId.value);
    });
    if (result.length > limit) {
      result = result.sublist(0, limit);
    }
    return List<AutomationRun>.unmodifiable(result);
  }

  @override
  Future<AutomationRun?> findRun(AutomationRunId id) async => _runs[id.value];

  @override
  Future<AutomationRun?> findPeriodRun(
    AutomationTaskId taskId,
    DateTime scheduledAt,
  ) async {
    for (final run in _runs.values) {
      if (run.trigger == AutomationRunTrigger.manual) {
        continue;
      }
      if (run.taskId == taskId &&
          run.scheduledAt.isAtSameMomentAs(scheduledAt)) {
        return run;
      }
    }
    return null;
  }

  @override
  Future<List<AutomationRun>> listRunningRuns() async =>
      List<AutomationRun>.unmodifiable(
        _runs.values.where((run) => run.status == AutomationRunStatus.running),
      );

  @override
  Future<AutomationRun> appendRun(
    AutomationRun run, {
    required int expectedRevision,
  }) async {
    _maybeFail();
    final current = _runs[run.runId.value];
    if (current == null) {
      if (expectedRevision != 0 || run.revision != 0) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'Новый запуск должен начинаться с ревизии 0.',
        );
      }
      if (run.trigger != AutomationRunTrigger.manual) {
        final duplicate = await findPeriodRun(run.taskId, run.scheduledAt);
        if (duplicate != null) {
          throwAutomation(
            AutomationErrorKind.conflict,
            'Период ${run.scheduledAt.toIso8601String()} уже имеет запуск.',
          );
        }
      }
    } else {
      if (current.revision != expectedRevision) {
        throwAutomation(
          AutomationErrorKind.revisionMismatch,
          'Ревизия запуска изменилась: ожидалась $expectedRevision, сейчас '
          '${current.revision}.',
        );
      }
      if (run.revision != expectedRevision + 1) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'Новая ревизия запуска должна быть ${expectedRevision + 1}.',
        );
      }
    }
    _runs[run.runId.value] = run;
    writes.add('run:${run.runId.value}:${run.revision}');
    return run;
  }

  void _maybeFail() {
    final failure = failWrites;
    if (failure != null) {
      throw AutomationException(failure);
    }
  }
}

/// Wraps [InMemoryAutomationRepository] and can hold selected operations
/// behind a gate, so tests can interleave service calls deterministically.
///
/// Usage: `gate('appendRun')`, start the operation, wait until
/// `callsFor('appendRun') == 1`, run the competing operation, then
/// `release('appendRun')`.
final class GatedAutomationRepository implements AutomationRepository {
  GatedAutomationRepository(this.inner);

  final InMemoryAutomationRepository inner;
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};
  final Map<String, int> _calls = <String, int>{};

  /// Holds every following [operation] call until [release].
  void gate(String operation) {
    _gates[operation] = Completer<void>();
  }

  void release(String operation) {
    final gate = _gates.remove(operation);
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  int callsFor(String operation) => _calls[operation] ?? 0;

  Future<void> _hold(String operation) async {
    _calls[operation] = callsFor(operation) + 1;
    final gate = _gates[operation];
    if (gate != null) {
      await gate.future;
    }
  }

  @override
  Future<List<AutomationTask>> listTasks({bool includeDeleted = false}) async {
    await _hold('listTasks');
    return inner.listTasks(includeDeleted: includeDeleted);
  }

  @override
  Future<AutomationTask?> findTask(AutomationTaskId id) async {
    await _hold('findTask');
    return inner.findTask(id);
  }

  @override
  Future<AutomationTask> createTask(AutomationTask task) async {
    await _hold('createTask');
    return inner.createTask(task);
  }

  @override
  Future<AutomationTask> saveTask(
    AutomationTask task, {
    required int expectedRevision,
  }) async {
    await _hold('saveTask');
    return inner.saveTask(task, expectedRevision: expectedRevision);
  }

  @override
  Future<List<AutomationRun>> listRuns({
    AutomationTaskId? taskId,
    int limit = 200,
    bool includeDeletedTasks = true,
  }) async {
    await _hold('listRuns');
    return inner.listRuns(
      taskId: taskId,
      limit: limit,
      includeDeletedTasks: includeDeletedTasks,
    );
  }

  @override
  Future<AutomationRun?> findRun(AutomationRunId id) async {
    await _hold('findRun');
    return inner.findRun(id);
  }

  @override
  Future<AutomationRun?> findPeriodRun(
    AutomationTaskId taskId,
    DateTime scheduledAt,
  ) async {
    await _hold('findPeriodRun');
    return inner.findPeriodRun(taskId, scheduledAt);
  }

  @override
  Future<List<AutomationRun>> listRunningRuns() async {
    await _hold('listRunningRuns');
    return inner.listRunningRuns();
  }

  @override
  Future<AutomationRun> appendRun(
    AutomationRun run, {
    required int expectedRevision,
  }) async {
    await _hold('appendRun');
    return inner.appendRun(run, expectedRevision: expectedRevision);
  }
}

/// Scripted executor with recorded requests and controllable outcomes.
final class ScriptedAutomationExecutor implements AutomationRunExecutor {
  ScriptedAutomationExecutor({this.availabilityHandler, this.handler});

  Future<AutomationRunAvailability> Function(AutomationTask task)?
  availabilityHandler;
  Future<AutomationRunOutcome> Function(
    AutomationRunRequest request,
    AutomationResultCancellation cancellation,
  )?
  handler;
  final List<AutomationRunRequest> requests = <AutomationRunRequest>[];
  final List<AutomationTask> availabilityChecks = <AutomationTask>[];

  @override
  Future<AutomationRunAvailability> availability(AutomationTask task) async {
    availabilityChecks.add(task);
    final custom = availabilityHandler;
    if (custom != null) {
      return custom(task);
    }
    return const AutomationRunAvailability.available();
  }

  @override
  Future<AutomationRunOutcome> execute(
    AutomationRunRequest request, {
    required AutomationResultCancellation cancellation,
  }) async {
    requests.add(request);
    final custom = handler;
    if (custom != null) {
      return custom(request, cancellation);
    }
    return AutomationRunOutcome(
      status: AutomationRunStatus.succeeded,
      resultText: 'Сводка задачи «${request.taskName}» готова.',
      modelTurns: 1,
      toolCalls: 0,
    );
  }
}

/// Builds a task draft with test defaults.
AutomationTaskDraft automationDraft({
  String name = 'Тестовая задача',
  String prompt = 'Собери сводку.',
  AutomationSchedule? schedule,
  String modelProvider = 'deepseek',
  String modelId = 'deepseek-chat',
  List<String> allowedToolIds = const <String>[],
  AutomationDelivery delivery = const AutomationDelivery.tasks(),
  AutomationTaskOrigin origin = AutomationTaskOrigin.human,
}) {
  return AutomationTaskDraft(
    name: name,
    prompt: prompt,
    schedule:
        schedule ??
        AutomationSchedule.cron(
          expression: '*/5 * * * *',
          timeZoneId: 'Europe/Moscow',
        ),
    model: automationModel(provider: modelProvider, modelId: modelId),
    allowedToolIds: allowedToolIds,
    delivery: delivery,
    origin: origin,
  );
}

ModelRef automationModel({
  String provider = 'deepseek',
  String modelId = 'deepseek-chat',
}) => ModelRef(providerId: ProviderId(provider), modelId: ModelId(modelId));

/// Time zone database with the zones used across the scheduler tests.
FakeAutomationTimeZones automationTestZones() =>
    FakeAutomationTimeZones(<FakeZone>[
      FakeZone(id: 'UTC', standardOffset: Duration.zero),
      FakeZone(id: 'Europe/Moscow', standardOffset: const Duration(hours: 3)),
      // New York-like zone: EST (UTC-5) with a spring gap and an autumn fold.
      FakeZone(
        id: 'America/New_York',
        standardOffset: const Duration(hours: -5),
        transitions: <FakeZoneTransition>[
          FakeZoneTransition(
            atUtc: DateTime.utc(2026, 3, 8, 7),
            offsetAfter: const Duration(hours: -4),
          ),
          FakeZoneTransition(
            atUtc: DateTime.utc(2026, 11, 1, 6),
            offsetAfter: const Duration(hours: -5),
          ),
        ],
      ),
    ]);

/// Deterministic identity generator.
final class SequentialAutomationIdGenerator implements AutomationIdGenerator {
  SequentialAutomationIdGenerator({int taskStart = 0, int runStart = 0})
    : _taskCounter = taskStart,
      _runCounter = runStart;

  var _taskCounter = 0;
  var _runCounter = 0;

  @override
  AutomationTaskId nextTaskId() {
    _taskCounter += 1;
    return AutomationTaskId(
      'atm_${_taskCounter.toRadixString(16).padLeft(32, '0')}',
    );
  }

  @override
  AutomationRunId nextRunId() {
    _runCounter += 1;
    return AutomationRunId(
      'ran_${_runCounter.toRadixString(16).padLeft(32, '0')}',
    );
  }
}

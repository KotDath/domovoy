import 'dart:convert';
import 'dart:typed_data';

import 'dart:async';

import '../../core/automation/automation.dart';
import '../agents/jsonl/jsonl_replay.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';
import 'automation_envelope.dart';
import 'automation_replay.dart';

/// Versioned JSONL repository of automation tasks and run history.
///
/// One task lives in its own stream keyed `task-<taskId>`; one run lives in its
/// own stream keyed `run-<runId>`. Every append validates the revision chain, so
/// two writers cannot silently overwrite each other, and every stream replays
/// from scratch on the first read after a restart. The `(taskId, scheduledAt)`
/// identity is enforced here as well as in the scheduler, so a duplicate fire
/// is impossible even if two callers race.
final class JsonlAutomationStore implements AutomationRepository {
  JsonlAutomationStore({
    required this.storage,
    AutomationLimits limits = const AutomationLimits(),
    this.envelopeCodec = const JsonlAutomationEnvelopeCodec(),
  }) : limits = limits.validate() {
    replay = JsonlAutomationReplay(
      envelopeCodec: envelopeCodec,
      limits: JsonlStorageLimits(
        maxEntryBytes:
            (limits.maxTaskBytes > limits.maxRunBytes
                ? limits.maxTaskBytes
                : limits.maxRunBytes) +
            AutomationLimits.envelopeHeadroomBytes,
        maxStreamBytes: limits.maxStreamBytes,
      ),
    );
  }

  static String taskKeyFor(AutomationTaskId id) => 'task-${id.value}';

  static String runKeyFor(AutomationRunId id) => 'run-${id.value}';

  final JsonlStreamStorage storage;
  final AutomationLimits limits;
  final JsonlAutomationEnvelopeCodec envelopeCodec;
  late final JsonlAutomationReplay replay;

  final Map<String, AutomationTask> _tasks = <String, AutomationTask>{};
  final Map<String, AutomationRun> _runs = <String, AutomationRun>{};
  final Map<String, int> _taskSequences = <String, int>{};
  final Map<String, int> _runSequences = <String, int>{};
  final Map<String, List<int>> _taskBytes = <String, List<int>>{};
  final Map<String, List<int>> _runBytes = <String, List<int>>{};
  var _loaded = false;
  final _StoreCoordinator _coordinator = _StoreCoordinator();

  Future<T> _serialized<T>(Future<T> Function() action) =>
      _coordinator.run(action);

  @override
  Future<List<AutomationTask>> listTasks({bool includeDeleted = false}) =>
      _serialized(() async {
        await _ensureLoaded();
        final tasks =
            _tasks.values
                .where((task) => includeDeleted || task.state.isAlive)
                .toList(growable: false)
              ..sort(_compareTasks);
        return List<AutomationTask>.unmodifiable(tasks);
      });

  @override
  Future<AutomationTask?> findTask(AutomationTaskId id) =>
      _serialized(() async {
        await _ensureLoaded();
        return _tasks[id.value];
      });

  @override
  Future<AutomationTask> createTask(AutomationTask task) =>
      _serialized(() async {
        await _ensureLoaded();
        if (_tasks.containsKey(task.taskId.value)) {
          throwAutomation(
            AutomationErrorKind.conflict,
            'Задача ${task.taskId.value} уже существует.',
          );
        }
        if (task.revision != 0) {
          throwAutomation(
            AutomationErrorKind.invalidInput,
            'Новая задача должна начинаться с ревизии 0.',
          );
        }
        final payload = _encodeTask(task);
        await _appendTask(
          task,
          payload: payload,
          sequence: 0,
          expectedRevision: 0,
        );
        return task;
      });

  @override
  Future<AutomationTask> saveTask(
    AutomationTask task, {
    required int expectedRevision,
  }) => _serialized(() async {
    await _ensureLoaded();
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
        'Новая ревизия задачи должна быть ${expectedRevision + 1}, получено '
        '${task.revision}.',
      );
    }
    final payload = _encodeTask(task);
    await _appendTask(
      task,
      payload: payload,
      sequence: (_taskSequences[task.taskId.value] ?? 0) + 1,
      expectedRevision: expectedRevision,
    );
    return task;
  });

  @override
  Future<List<AutomationRun>> listRuns({
    AutomationTaskId? taskId,
    int limit = 200,
    bool includeDeletedTasks = true,
  }) => _serialized(() async {
    await _ensureLoaded();
    if (limit <= 0) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'limit должен быть положительным.',
      );
    }
    var runs = _runs.values.toList(growable: false);
    if (taskId != null) {
      runs = runs.where((run) => run.taskId == taskId).toList(growable: false);
    }
    runs.sort(_compareRuns);
    if (runs.length > limit) {
      runs = runs.sublist(0, limit);
    }
    return List<AutomationRun>.unmodifiable(runs);
  });

  @override
  Future<AutomationRun?> findRun(AutomationRunId id) => _serialized(() async {
    await _ensureLoaded();
    return _runs[id.value];
  });

  @override
  Future<AutomationRun?> findRunBySchedule(
    AutomationTaskId taskId,
    DateTime scheduledAt,
  ) => _serialized(() async {
    await _ensureLoaded();
    for (final run in _runs.values) {
      if (run.taskId == taskId &&
          run.scheduledAt.isAtSameMomentAs(scheduledAt)) {
        return run;
      }
    }
    return null;
  });

  @override
  Future<List<AutomationRun>> listRunningRuns() => _serialized(() async {
    await _ensureLoaded();
    final runs =
        _runs.values
            .where((run) => run.status == AutomationRunStatus.running)
            .toList(growable: false)
          ..sort(_compareRuns);
    return List<AutomationRun>.unmodifiable(runs);
  });

  @override
  Future<AutomationRun> appendRun(
    AutomationRun run, {
    required int expectedRevision,
  }) => _serialized(() async {
    await _ensureLoaded();
    final current = _runs[run.runId.value];
    if (current == null) {
      if (expectedRevision != 0 || run.revision != 0) {
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'Новый запуск должен начинаться с ревизии 0.',
        );
      }
      final duplicate = _findRunByScheduleUnsafe(run.taskId, run.scheduledAt);
      if (duplicate != null) {
        throwAutomation(
          AutomationErrorKind.conflict,
          'Период ${run.scheduledAt.toIso8601String()} задачи '
          '${run.taskId.value} уже имеет запуск ${duplicate.runId.value}.',
        );
      }
      final payload = _encodeRun(run);
      await _appendRun(run, payload: payload, sequence: 0, expectedRevision: 0);
      return run;
    }
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
        'Новая ревизия запуска должна быть ${expectedRevision + 1}, получено '
        '${run.revision}.',
      );
    }
    final nextSequence = (_runSequences[run.runId.value] ?? 0) + 1;
    if (nextSequence >= JsonlAutomationReplay.maxRunRecords) {
      throwAutomation(
        AutomationErrorKind.conflict,
        'История запуска уже содержит предельное число записей.',
      );
    }
    final payload = _encodeRun(run);
    await _appendRun(
      run,
      payload: payload,
      sequence: nextSequence,
      expectedRevision: expectedRevision,
    );
    return run;
  });

  Future<void> _ensureLoaded() async {
    if (_loaded) {
      return;
    }
    final List<String> keys;
    try {
      keys = await storage.listKeys();
    } on Object {
      throwAutomation(
        AutomationErrorKind.persistence,
        'Список потоков автоматизации недоступен.',
      );
    }
    for (final key in keys.toList()..sort()) {
      if (key.startsWith('task-')) {
        await _loadTask(key);
      } else if (key.startsWith('run-')) {
        await _loadRun(key);
      } else {
        throwAutomation(
          AutomationErrorKind.corruption,
          'Хранилище автоматизации содержит неизвестный поток "$key".',
        );
      }
    }
    _loaded = true;
  }

  Future<void> _loadTask(String key) async {
    final rawId = key.substring('task-'.length);
    final taskId = AutomationTaskId.tryParse(rawId);
    if (taskId == null) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Ключ потока "$key" не является идентификатором задачи.',
      );
    }
    final result = await _replay(
      kind: JsonlAutomationStreamKind.task,
      streamId: taskId.value,
      key: key,
    );
    final AutomationTask task;
    try {
      task = AutomationTask.fromJson(result.payload);
    } on AutomationException {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Запись задачи ${taskId.value} не воспроизводится.',
      );
    }
    if (task.taskId != taskId || task.revision != result.revision) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Запись задачи ${taskId.value} не совпадает с потоком.',
      );
    }
    _tasks[taskId.value] = task;
    _taskSequences[taskId.value] = result.sequence;
    _taskBytes[taskId.value] = await _repairIfNeeded(
      key: key,
      result: result,
      cached: _taskBytes,
      streamId: taskId.value,
    );
  }

  Future<void> _loadRun(String key) async {
    final rawId = key.substring('run-'.length);
    final runId = AutomationRunId.tryParse(rawId);
    if (runId == null) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Ключ потока "$key" не является идентификатором запуска.',
      );
    }
    final result = await _replay(
      kind: JsonlAutomationStreamKind.run,
      streamId: runId.value,
      key: key,
    );
    final AutomationRun run;
    try {
      run = AutomationRun.fromJson(result.payload);
    } on AutomationException {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Запись запуска ${runId.value} не воспроизводится.',
      );
    }
    if (run.runId != runId || run.revision != result.revision) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Запись запуска ${runId.value} не совпадает с потоком.',
      );
    }
    _runs[runId.value] = run;
    _runSequences[runId.value] = result.sequence;
    _runBytes[runId.value] = await _repairIfNeeded(
      key: key,
      result: result,
      cached: _runBytes,
      streamId: runId.value,
    );
  }

  /// Returns the valid prefix of a stream, publishing it back when a truncated
  /// tail was found so the next append continues a clean sequence.
  Future<List<int>> _repairIfNeeded({
    required String key,
    required JsonlAutomationReplayResult result,
    required Map<String, List<int>> cached,
    required String streamId,
  }) async {
    final prefix = List<int>.from(result.validPrefix);
    if (result.needsRepair) {
      await _publish(key, prefix);
    }
    cached[streamId] = prefix;
    return prefix;
  }

  Future<JsonlAutomationReplayResult> _replay({
    required JsonlAutomationStreamKind kind,
    required String streamId,
    required String key,
  }) async {
    final Stream<List<int>>? chunks;
    try {
      chunks = await storage.read(key);
    } on Object {
      throwAutomation(
        AutomationErrorKind.persistence,
        'Поток "$key" не читается.',
      );
    }
    if (chunks == null) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Поток "$key" отсутствует, хотя объявлен в списке.',
      );
    }
    try {
      return await replay.replay(
        kind: kind,
        streamId: streamId,
        chunks: chunks,
      );
    } on Object {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Поток "$key" повреждён и не был прочитан частично.',
      );
    }
  }

  Future<void> _appendTask(
    AutomationTask task, {
    required Map<String, Object?> payload,
    required int sequence,
    required int expectedRevision,
  }) async {
    final bytes = _encodeEnvelope(
      JsonlAutomationEnvelope(
        streamKind: JsonlAutomationStreamKind.task,
        streamId: task.taskId.value,
        sequence: sequence,
        operation: JsonlAutomationOperation.taskUpsert,
        expectedRevision: expectedRevision,
        entryRevision: task.revision,
        payload: payload,
      ),
    );
    final size = utf8.encode(jsonEncode(payload)).length;
    if (size > limits.maxTaskBytes) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Запись задачи занимает $size байт и превышает лимит '
        '${limits.maxTaskBytes}.',
      );
    }
    final combined = _combine(
      _taskBytes[task.taskId.value],
      bytes,
      key: taskKeyFor(task.taskId),
    );
    await _publish(taskKeyFor(task.taskId), combined);
    _tasks[task.taskId.value] = task;
    _taskSequences[task.taskId.value] = sequence;
    _taskBytes[task.taskId.value] = combined;
  }

  Future<void> _appendRun(
    AutomationRun run, {
    required Map<String, Object?> payload,
    required int sequence,
    required int expectedRevision,
  }) async {
    final bytes = _encodeEnvelope(
      JsonlAutomationEnvelope(
        streamKind: JsonlAutomationStreamKind.run,
        streamId: run.runId.value,
        sequence: sequence,
        operation: JsonlAutomationOperation.runRecord,
        expectedRevision: expectedRevision,
        entryRevision: run.revision,
        payload: payload,
      ),
    );
    final size = utf8.encode(jsonEncode(payload)).length;
    if (size > limits.maxRunBytes) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Запись запуска занимает $size байт и превышает лимит '
        '${limits.maxRunBytes}.',
      );
    }
    final combined = _combine(
      _runBytes[run.runId.value],
      bytes,
      key: runKeyFor(run.runId),
    );
    await _publish(runKeyFor(run.runId), combined);
    _runs[run.runId.value] = run;
    _runSequences[run.runId.value] = sequence;
    _runBytes[run.runId.value] = combined;
  }

  /// Appends one complete envelope line to the cached stream bytes.
  List<int> _combine(
    List<int>? existing,
    List<int> entry, {
    required String key,
  }) {
    final combined = <int>[...?existing, ...entry];
    if (combined.length > limits.maxStreamBytes) {
      throwAutomation(
        AutomationErrorKind.limits,
        'Поток "$key" достиг лимита ${limits.maxStreamBytes} байт; новые '
        'записи отклонены.',
      );
    }
    return combined;
  }

  Map<String, Object?> _encodeTask(AutomationTask task) {
    try {
      return task.validateAgainst(limits).toJson();
    } on AutomationException catch (error) {
      throwAutomation(error.error.kind, error.error.message);
    }
  }

  Map<String, Object?> _encodeRun(AutomationRun run) {
    try {
      return run.validateAgainst(limits).toJson();
    } on AutomationException catch (error) {
      throwAutomation(error.error.kind, error.error.message);
    }
  }

  Uint8List _encodeEnvelope(JsonlAutomationEnvelope envelope) {
    final bytes = Uint8List.fromList(
      utf8.encode(envelopeCodec.encodeLine(envelope)),
    );
    if (bytes.length > limits.maxStreamBytes) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Запись автоматизации не помещается в лимит потока.',
      );
    }
    return bytes;
  }

  Future<void> _publish(String key, List<int> contents) async {
    try {
      await storage.publish(key, List<int>.unmodifiable(contents));
    } on Object {
      throwAutomation(
        AutomationErrorKind.persistence,
        'Поток "$key" не удалось опубликовать.',
      );
    }
    try {
      await storage.cleanup(key);
    } on Object {
      // Cleanup is best effort after the active generation is selected.
    }
  }

  AutomationRun? _findRunByScheduleUnsafe(
    AutomationTaskId taskId,
    DateTime scheduledAt,
  ) {
    for (final run in _runs.values) {
      if (run.taskId == taskId &&
          run.scheduledAt.isAtSameMomentAs(scheduledAt)) {
        return run;
      }
    }
    return null;
  }

  static int _compareTasks(AutomationTask a, AutomationTask b) {
    final byCreated = a.createdAt.compareTo(b.createdAt);
    if (byCreated != 0) {
      return byCreated;
    }
    return a.taskId.value.compareTo(b.taskId.value);
  }

  static int _compareRuns(AutomationRun a, AutomationRun b) {
    final bySchedule = b.scheduledAt.compareTo(a.scheduledAt);
    if (bySchedule != 0) {
      return bySchedule;
    }
    return b.runId.value.compareTo(a.runId.value);
  }
}

final class _StoreCoordinator {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final predecessor = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        released.complete();
      }
    }();
  }
}

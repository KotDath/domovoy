import 'dart:async';
import 'dart:convert';

import '../../../core/tasks/tasks.dart';
import '../../agents/jsonl/jsonl_stream_storage.dart';

final class TaskJsonlKeyCodec {
  const TaskJsonlKeyCodec();

  static const taskPrefix = 'task-v1_';
  static const taskPolicyPrefix = 'task-policy-v1_';
  static const projectPolicyPrefix = 'project-policy-v1_';

  String task(TaskId id) => '$taskPrefix${_encode(id.value)}';
  String taskPolicy(TaskId id) => '$taskPolicyPrefix${_encode(id.value)}';
  String projectPolicy(String id) => '$projectPolicyPrefix${_encode(id)}';

  TaskId? tryTask(String key) {
    if (!key.startsWith(taskPrefix)) return null;
    try {
      return TaskId.parse(_decode(key.substring(taskPrefix.length)));
    } on Object {
      return null;
    }
  }

  String _encode(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  String _decode(String value) {
    final padding = '=' * ((4 - value.length % 4) % 4);
    return utf8.decode(base64Url.decode('$value$padding'));
  }
}

final class JsonlTaskStore implements TaskRepository, TaskInvariantRepository {
  JsonlTaskStore({
    required this.storage,
    this.keys = const TaskJsonlKeyCodec(),
  });

  static const _taskType = 'domovoy.task_snapshot';
  static const _policyType = 'domovoy.task_invariant_policy';
  static const _version = 1;
  static const _maximumStreamBytes = 8 * 1024 * 1024;

  final JsonlStreamStorage storage;
  final TaskJsonlKeyCodec keys;
  Future<void> _tail = Future<void>.value();

  @override
  Future<TaskSnapshot?> load(TaskId id) =>
      _serial(() async => (await _readTask(id)).snapshot);

  @override
  Future<TaskSnapshot?> activeForSession(String sessionId) => _serial(() async {
    final candidates = <TaskSnapshot>[];
    for (final key in await _safeListKeys()) {
      final id = keys.tryTask(key);
      if (id == null) continue;
      final snapshot = (await _readTask(id)).snapshot;
      if (snapshot != null &&
          snapshot.sessionId == sessionId &&
          !snapshot.cancelled &&
          snapshot.phase != TaskPhase.done) {
        candidates.add(snapshot);
      }
    }
    candidates.sort(
      (left, right) => right.updatedAtMicros.compareTo(left.updatedAtMicros),
    );
    if (candidates.length > 1) {
      _corrupt('Several active tasks belong to one chat session.');
    }
    return candidates.firstOrNull;
  });

  @override
  Future<void> save(TaskSnapshot snapshot, {required int expectedRevision}) =>
      _serial(() async {
        snapshot.validate();
        final replay = await _readTask(snapshot.id);
        final existing = replay.snapshot;
        if (existing == null) {
          if (expectedRevision != 0 || snapshot.revision != 0) _conflict();
          final active = await _activeForSessionExcluding(
            snapshot.sessionId,
            snapshot.id,
          );
          if (active != null) {
            _conflict('В этом чате уже есть активная задача.');
          }
        } else if (existing.revision != expectedRevision ||
            snapshot.revision != expectedRevision + 1) {
          _conflict();
        }
        final line = _encode(<String, Object?>{
          'type': _taskType,
          'version': _version,
          'taskId': snapshot.id.value,
          'sessionId': snapshot.sessionId,
          'sequence': replay.nextSequence,
          'expectedRevision': expectedRevision,
          'snapshotRevision': snapshot.revision,
          'snapshot': snapshot.toJson(),
        });
        await _publish(keys.task(snapshot.id), <int>[
          ...replay.validPrefix,
          ...line,
        ]);
      });

  @override
  Future<TaskInvariantPolicy?> forTask(TaskId taskId) =>
      _serial(() async => (await _readPolicy(keys.taskPolicy(taskId))).policy);

  @override
  Future<TaskInvariantPolicy?> forProject(String projectId) => _serial(
    () async => (await _readPolicy(keys.projectPolicy(projectId))).policy,
  );

  @override
  Future<void> saveTaskPolicy(
    TaskInvariantPolicy policy, {
    required int expectedRevision,
  }) {
    if (policy.scope != TaskInvariantScope.task) {
      return Future<void>.error(
        ArgumentError('Task policy must use task scope.'),
      );
    }
    return _savePolicy(
      keys.taskPolicy(TaskId.parse(policy.ownerId)),
      policy,
      expectedRevision,
    );
  }

  @override
  Future<void> saveProjectPolicy(
    TaskInvariantPolicy policy, {
    required int expectedRevision,
  }) {
    if (policy.scope != TaskInvariantScope.project) {
      return Future<void>.error(
        ArgumentError('Project policy must use project scope.'),
      );
    }
    return _savePolicy(
      keys.projectPolicy(policy.ownerId),
      policy,
      expectedRevision,
    );
  }

  Future<void> _savePolicy(
    String key,
    TaskInvariantPolicy policy,
    int expectedRevision,
  ) => _serial(() async {
    final replay = await _readPolicy(key);
    final existing = replay.policy;
    if (existing == null) {
      if (expectedRevision != 0 || policy.revision != 0) _conflict();
    } else if (existing.ownerId != policy.ownerId ||
        existing.scope != policy.scope ||
        existing.revision != expectedRevision ||
        policy.revision != expectedRevision + 1) {
      _conflict();
    }
    final line = _encode(<String, Object?>{
      'type': _policyType,
      'version': _version,
      'ownerId': policy.ownerId,
      'scope': policy.scope.name,
      'sequence': replay.nextSequence,
      'expectedRevision': expectedRevision,
      'policyRevision': policy.revision,
      'policy': policy.toJson(),
    });
    await _publish(key, <int>[...replay.validPrefix, ...line]);
  });

  Future<TaskSnapshot?> _activeForSessionExcluding(
    String sessionId,
    TaskId excluded,
  ) async {
    for (final key in await _safeListKeys()) {
      final id = keys.tryTask(key);
      if (id == null || id == excluded) continue;
      final candidate = (await _readTask(id)).snapshot;
      if (candidate != null &&
          candidate.sessionId == sessionId &&
          !candidate.cancelled &&
          candidate.phase != TaskPhase.done) {
        return candidate;
      }
    }
    return null;
  }

  Future<_TaskReplay> _readTask(TaskId id) async {
    final decoded = await _readLines(keys.task(id));
    TaskSnapshot? current;
    var sequence = -1;
    for (final map in decoded.lines) {
      if (map['type'] != _taskType ||
          map['version'] != _version ||
          map['taskId'] != id.value ||
          map['sequence'] is! int ||
          map['expectedRevision'] is! int ||
          map['snapshotRevision'] is! int ||
          map['snapshot'] is! Map) {
        _corrupt();
      }
      final nextSequence = map['sequence']! as int;
      final expected = map['expectedRevision']! as int;
      final revision = map['snapshotRevision']! as int;
      if (nextSequence != sequence + 1 ||
          (current == null
              ? expected != 0 || revision != 0
              : expected != current.revision || revision != expected + 1)) {
        _corrupt();
      }
      final TaskSnapshot snapshot;
      try {
        snapshot = TaskSnapshot.fromJson(
          (map['snapshot']! as Map<Object?, Object?>).cast<String, Object?>(),
        );
      } on Object {
        _corrupt('Снимок задачи содержит недопустимое состояние.');
      }
      if (snapshot.id != id ||
          snapshot.sessionId != map['sessionId'] ||
          snapshot.revision != revision) {
        _corrupt();
      }
      sequence = nextSequence;
      current = snapshot;
    }
    return _TaskReplay(
      snapshot: current,
      nextSequence: sequence + 1,
      validPrefix: decoded.validPrefix,
    );
  }

  Future<_PolicyReplay> _readPolicy(String key) async {
    final decoded = await _readLines(key);
    TaskInvariantPolicy? current;
    var sequence = -1;
    for (final map in decoded.lines) {
      if (map['type'] != _policyType ||
          map['version'] != _version ||
          map['sequence'] is! int ||
          map['expectedRevision'] is! int ||
          map['policyRevision'] is! int ||
          map['policy'] is! Map) {
        _corrupt();
      }
      final nextSequence = map['sequence']! as int;
      final expected = map['expectedRevision']! as int;
      final revision = map['policyRevision']! as int;
      if (nextSequence != sequence + 1 ||
          (current == null
              ? expected != 0 || revision != 0
              : expected != current.revision || revision != expected + 1)) {
        _corrupt();
      }
      final TaskInvariantPolicy policy;
      try {
        policy = TaskInvariantPolicy.fromJson(
          (map['policy']! as Map<Object?, Object?>).cast<String, Object?>(),
        );
      } on Object {
        _corrupt('Политика инвариантов повреждена.');
      }
      if (policy.ownerId != map['ownerId'] ||
          policy.scope.name != map['scope'] ||
          policy.revision != revision) {
        _corrupt();
      }
      sequence = nextSequence;
      current = policy;
    }
    return _PolicyReplay(
      policy: current,
      nextSequence: sequence + 1,
      validPrefix: decoded.validPrefix,
    );
  }

  Future<_DecodedTaskLines> _readLines(String key) async {
    try {
      final stream = await storage.read(key);
      if (stream == null) return const _DecodedTaskLines();
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
        if (bytes.length > _maximumStreamBytes) _corrupt();
      }
      final text = utf8.decode(bytes);
      final lastNewline = text.lastIndexOf('\n');
      if (lastNewline < 0) return const _DecodedTaskLines();
      final prefix = text.substring(0, lastNewline + 1);
      final lines = <Map<String, Object?>>[];
      for (final raw in prefix.split('\n')) {
        if (raw.isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) _corrupt();
        lines.add(decoded.cast<String, Object?>());
      }
      return _DecodedTaskLines(lines: lines, validPrefix: utf8.encode(prefix));
    } on TaskRepositoryException {
      rethrow;
    } on FormatException {
      _corrupt();
    } on Object {
      throw const TaskRepositoryException(
        TaskRepositoryErrorKind.unavailable,
        'Хранилище задач временно недоступно.',
      );
    }
  }

  List<int> _encode(Map<String, Object?> value) =>
      utf8.encode('${jsonEncode(value)}\n');

  Future<List<String>> _safeListKeys() async {
    try {
      return await storage.listKeys();
    } on Object {
      throw const TaskRepositoryException(
        TaskRepositoryErrorKind.unavailable,
        'Не удалось прочитать каталог задач.',
      );
    }
  }

  Future<void> _publish(String key, List<int> bytes) async {
    if (bytes.length > _maximumStreamBytes) _corrupt();
    try {
      await storage.publish(key, bytes);
      await storage.cleanup(key);
    } on Object {
      throw const TaskRepositoryException(
        TaskRepositoryErrorKind.unavailable,
        'Не удалось сохранить задачу.',
      );
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
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

  Never _conflict([String message = 'Состояние задачи изменилось.']) =>
      throw TaskRepositoryException(TaskRepositoryErrorKind.conflict, message);

  Never _corrupt([String message = 'История задачи повреждена.']) =>
      throw TaskRepositoryException(TaskRepositoryErrorKind.corrupt, message);
}

final class _DecodedTaskLines {
  const _DecodedTaskLines({
    this.lines = const <Map<String, Object?>>[],
    this.validPrefix = const <int>[],
  });

  final List<Map<String, Object?>> lines;
  final List<int> validPrefix;
}

final class _TaskReplay {
  const _TaskReplay({
    this.snapshot,
    this.nextSequence = 0,
    this.validPrefix = const <int>[],
  });

  final TaskSnapshot? snapshot;
  final int nextSequence;
  final List<int> validPrefix;
}

final class _PolicyReplay {
  const _PolicyReplay({
    this.policy,
    this.nextSequence = 0,
    this.validPrefix = const <int>[],
  });

  final TaskInvariantPolicy? policy;
  final int nextSequence;
  final List<int> validPrefix;
}

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
  Future<TaskSnapshot?> activeForSession(String sessionId) =>
      _serial(() => _findActiveForSession(sessionId));

  @override
  Future<TaskSnapshot?> recoverActiveForSession(
    String sessionId, {
    required int occurredAtMicros,
  }) => _serial(() async {
    final current = await _findActiveForSession(sessionId);
    if (current == null || !_hasInFlightNode(current)) return current;
    final result = const TaskReducer().reduce(
      current,
      TaskTransition(
        kind: TaskTransitionKind.interrupted,
        expectedRevision: current.revision,
        occurredAtMicros: occurredAtMicros,
      ),
    );
    if (!result.isAccepted) {
      _corrupt('Не удалось восстановить незавершённую задачу.');
    }
    await _save(result.snapshot!, expectedRevision: current.revision);
    return result.snapshot;
  });

  Future<TaskSnapshot?> _findActiveForSession(String sessionId) async {
    final candidates = <TaskSnapshot>[];
    for (final key in await _safeListKeys()) {
      final id = keys.tryTask(key);
      if (id == null) continue;
      final snapshot = await _taskForSession(id, sessionId);
      if (snapshot != null && _isActive(snapshot)) {
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
  }

  @override
  Future<void> save(TaskSnapshot snapshot, {required int expectedRevision}) =>
      _serial(() => _save(snapshot, expectedRevision: expectedRevision));

  Future<void> _save(
    TaskSnapshot snapshot, {
    required int expectedRevision,
  }) async {
    try {
      snapshot.validate();
    } on Object {
      _corrupt('Нельзя сохранить недопустимое состояние задачи.');
    }
    final replay = await _readTask(snapshot.id);
    final existing = replay.snapshot;
    if (existing == null) {
      if (expectedRevision != 0 || snapshot.revision != 0) _conflict();
    } else {
      if (existing.sessionId != snapshot.sessionId ||
          existing.projectId != snapshot.projectId) {
        _conflict('Идентичность задачи не может изменяться.');
      }
      if (existing.revision != expectedRevision ||
          snapshot.revision != expectedRevision + 1) {
        _conflict();
      }
    }
    if (_isActive(snapshot)) {
      final active = await _activeForSessionExcluding(
        snapshot.sessionId,
        snapshot.id,
      );
      if (active != null) {
        _conflict('В этом чате уже есть активная задача.');
      }
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
  }

  @override
  Future<TaskInvariantPolicy?> forTask(TaskId taskId) => _serial(
    () async => (await _readPolicy(
      keys.taskPolicy(taskId),
      expectedOwnerId: taskId.value,
      expectedScope: TaskInvariantScope.task,
    )).policy,
  );

  @override
  Future<TaskInvariantPolicy?> forProject(String projectId) => _serial(
    () async => (await _readPolicy(
      keys.projectPolicy(projectId),
      expectedOwnerId: projectId,
      expectedScope: TaskInvariantScope.project,
    )).policy,
  );

  @override
  Future<void> saveTaskPolicy(
    TaskInvariantPolicy policy, {
    required int expectedRevision,
  }) async {
    if (policy.scope != TaskInvariantScope.task) {
      throw ArgumentError('Task policy must use task scope.');
    }
    await _savePolicy(
      keys.taskPolicy(TaskId.parse(policy.ownerId)),
      policy,
      expectedRevision,
    );
  }

  @override
  Future<void> saveProjectPolicy(
    TaskInvariantPolicy policy, {
    required int expectedRevision,
  }) async {
    if (policy.scope != TaskInvariantScope.project) {
      throw ArgumentError('Project policy must use project scope.');
    }
    await _savePolicy(
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
    final replay = await _readPolicy(
      key,
      expectedOwnerId: policy.ownerId,
      expectedScope: policy.scope,
    );
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
      final candidate = await _taskForSession(id, sessionId);
      if (candidate != null && _isActive(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  Future<TaskSnapshot?> _taskForSession(TaskId id, String sessionId) async {
    final hint = await _taskSessionHint(id);
    if (hint != null && hint != sessionId) return null;

    // A missing hint is not evidence that the stream belongs to another chat:
    // its first record may be corrupt or torn. Replay it so corruption fails
    // closed instead of silently bypassing recovery and the one-active-task
    // guard. Empty/disappeared streams remain harmless.
    final snapshot = (await _readTask(id)).snapshot;
    if (snapshot == null || snapshot.sessionId != sessionId) return null;
    return snapshot;
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
          (current != null &&
              (snapshot.sessionId != current.sessionId ||
                  snapshot.projectId != current.projectId)) ||
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

  Future<_PolicyReplay> _readPolicy(
    String key, {
    required String expectedOwnerId,
    required TaskInvariantScope expectedScope,
  }) async {
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
          policy.ownerId != expectedOwnerId ||
          policy.scope != expectedScope ||
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
      if (bytes.isEmpty) return const _DecodedTaskLines();
      final lastNewline = bytes.lastIndexOf(0x0a);
      if (lastNewline < 0) _corrupt();
      final prefixBytes = bytes.sublist(0, lastNewline + 1);
      final prefix = utf8.decode(prefixBytes);
      final lines = <Map<String, Object?>>[];
      for (final raw in prefix.split('\n')) {
        if (raw.isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) _corrupt();
        lines.add(decoded.cast<String, Object?>());
      }
      return _DecodedTaskLines(lines: lines, validPrefix: prefixBytes);
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
    } on Object {
      throw const TaskRepositoryException(
        TaskRepositoryErrorKind.unavailable,
        'Не удалось сохранить задачу.',
      );
    }
    try {
      await storage.cleanup(key);
    } on Object {
      // Publication already committed the new generation; cleanup is optional.
    }
  }

  Future<String?> _taskSessionHint(TaskId id) async {
    final List<int> bytes;
    try {
      final stream = await storage.read(keys.task(id));
      if (stream == null) return null;
      final collected = <int>[];
      await for (final chunk in stream) {
        collected.addAll(chunk);
        if (collected.length > _maximumStreamBytes) _corrupt();
      }
      bytes = collected;
    } on TaskRepositoryException {
      rethrow;
    } on Object {
      throw const TaskRepositoryException(
        TaskRepositoryErrorKind.unavailable,
        'Хранилище задач временно недоступно.',
      );
    }
    try {
      final newline = bytes.indexOf(0x0a);
      if (newline < 0) return null;
      final decoded = jsonDecode(utf8.decode(bytes.sublist(0, newline)));
      if (decoded is! Map) return null;
      final map = decoded.cast<String, Object?>();
      if (map['type'] != _taskType ||
          map['version'] != _version ||
          map['taskId'] != id.value ||
          map['sessionId'] is! String) {
        return null;
      }
      return map['sessionId']! as String;
    } on Object {
      return null;
    }
  }

  bool _isActive(TaskSnapshot snapshot) =>
      !snapshot.cancelled && snapshot.phase != TaskPhase.done;

  bool _hasInFlightNode(TaskSnapshot snapshot) => snapshot.nodes.any(
    (node) =>
        node.status == TaskNodeStatus.running ||
        node.status == TaskNodeStatus.verifying ||
        node.status == TaskNodeStatus.repairing,
  );

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

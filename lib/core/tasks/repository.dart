import 'ids.dart';
import 'invariants.dart';
import 'model.dart';

abstract interface class TaskRepository {
  Future<TaskSnapshot?> load(TaskId id);

  Future<TaskSnapshot?> activeForSession(String sessionId);

  /// Recovers the active workflow after a process restart.
  ///
  /// Unlike [activeForSession], this deliberately turns an in-flight model
  /// invocation into an interrupted, paused checkpoint and persists it.
  Future<TaskSnapshot?> recoverActiveForSession(
    String sessionId, {
    required int occurredAtMicros,
  });

  Future<void> save(TaskSnapshot snapshot, {required int expectedRevision});
}

abstract interface class TaskInvariantRepository {
  Future<TaskInvariantPolicy?> forTask(TaskId taskId);

  Future<TaskInvariantPolicy?> forProject(String projectId);

  Future<void> saveTaskPolicy(
    TaskInvariantPolicy policy, {
    required int expectedRevision,
  });

  Future<void> saveProjectPolicy(
    TaskInvariantPolicy policy, {
    required int expectedRevision,
  });
}

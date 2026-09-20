import 'ids.dart';
import 'invariants.dart';
import 'model.dart';

abstract interface class TaskRepository {
  Future<TaskSnapshot?> load(TaskId id);

  Future<TaskSnapshot?> activeForSession(String sessionId);

  Future<void> save(TaskSnapshot snapshot, {required int expectedRevision});
}

abstract interface class TaskInvariantRepository {
  Future<List<TaskInvariantRule>> forTask(TaskId taskId);

  Future<List<TaskInvariantRule>> forProject(String projectId);

  Future<void> replaceTaskRules(TaskId taskId, List<TaskInvariantRule> rules);

  Future<void> replaceProjectRules(
    String projectId,
    List<TaskInvariantRule> rules,
  );
}

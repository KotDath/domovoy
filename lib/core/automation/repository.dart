import 'ids.dart';
import 'run.dart';
import 'task.dart';

/// Persistence contract of task definitions.
abstract interface class AutomationTaskRepository {
  /// All tasks in stable `createdAt`/identity order.
  ///
  /// Deleted tasks are tombstones and are excluded unless [includeDeleted].
  Future<List<AutomationTask>> listTasks({bool includeDeleted = false});

  Future<AutomationTask?> findTask(AutomationTaskId id);

  /// Creates revision 0 of [task]; a second create for the same id conflicts.
  Future<AutomationTask> createTask(AutomationTask task);

  /// Appends [task] as the next revision, requiring the stored revision to be
  /// [expectedRevision]; a concurrent writer fails with `revisionMismatch`.
  Future<AutomationTask> saveTask(
    AutomationTask task, {
    required int expectedRevision,
  });
}

/// Persistence contract of run history.
abstract interface class AutomationRunRepository {
  /// Runs newest first, optionally limited to one task.
  Future<List<AutomationRun>> listRuns({
    AutomationTaskId? taskId,
    int limit = 200,
    bool includeDeletedTasks = true,
  });

  Future<AutomationRun?> findRun(AutomationRunId id);

  /// Period run of [taskId] whose `scheduledAt` equals [scheduledAt], if any.
  ///
  /// This is the `(taskId, scheduledAt)` idempotency lookup. Only scheduled,
  /// catch-up and skipped runs occupy a period; manual runs are keyed by
  /// `runId` alone and are ignored here, so run-now never consumes or
  /// suppresses a planned period.
  Future<AutomationRun?> findPeriodRun(
    AutomationTaskId taskId,
    DateTime scheduledAt,
  );

  /// Runs left in `running` state by a process that exited.
  Future<List<AutomationRun>> listRunningRuns();

  /// Appends [run] as the next revision of its stream.
  ///
  /// A new **period** run ([AutomationRun.trigger] not
  /// [AutomationRunTrigger.manual]) conflicts with an existing period run for
  /// the same `(taskId, scheduledAt)`; manual runs only conflict on a repeated
  /// `runId`.
  Future<AutomationRun> appendRun(
    AutomationRun run, {
    required int expectedRevision,
  });
}

/// Full persistence boundary used by the scheduler.
abstract interface class AutomationRepository
    implements AutomationTaskRepository, AutomationRunRepository {}

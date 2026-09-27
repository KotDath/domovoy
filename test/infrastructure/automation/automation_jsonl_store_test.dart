import 'dart:convert';

import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/infrastructure/automation/automation_jsonl_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';
import '../../support/memory_jsonl_storage.dart';

void main() {
  late FakeMemoryJsonlStorage storage;

  setUp(() {
    storage = FakeMemoryJsonlStorage();
  });

  JsonlAutomationStore buildStore({AutomationLimits? limits}) =>
      JsonlAutomationStore(
        storage: storage,
        limits: limits ?? const AutomationLimits(),
      );

  AutomationTask task({
    String id = 'atm_00000000000000000000000000000001',
    AutomationTaskState state = AutomationTaskState.active,
    int revision = 0,
    DateTime? nextDueAt,
    DateTime? createdAt,
  }) {
    return AutomationTask(
      taskId: id,
      name: 'Задача $id',
      prompt: 'Собери сводку.',
      schedule: AutomationSchedule.cron(
        expression: '*/5 * * * *',
        timeZoneId: 'Europe/Moscow',
      ),
      model: automationModel(),
      state: state,
      origin: AutomationTaskOrigin.human,
      nextDueAt:
          state == AutomationTaskState.active ||
              state == AutomationTaskState.proposed
          ? (nextDueAt ?? DateTime.utc(2026, 1, 1, 12, 5))
          : null,
      revision: revision,
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1, 12),
      updatedAt: DateTime.utc(2026, 1, 1, 12),
    );
  }

  AutomationRun run({
    String id = 'ran_00000000000000000000000000000001',
    String taskId = 'atm_00000000000000000000000000000001',
    AutomationRunStatus status = AutomationRunStatus.running,
    DateTime? scheduledAt,
    int revision = 0,
    AutomationRunTrigger trigger = AutomationRunTrigger.scheduled,
  }) {
    final at = scheduledAt ?? DateTime.utc(2026, 1, 1, 12, 5);
    return AutomationRun(
      runId: id,
      taskId: taskId,
      taskRevision: 0,
      trigger: trigger,
      status: status,
      scheduledAt: at,
      startedAt: DateTime.utc(2026, 1, 1, 12, 5, 1),
      finishedAt: status == AutomationRunStatus.running
          ? null
          : DateTime.utc(2026, 1, 1, 12, 5, 30),
      model: automationModel(),
      revision: revision,
    );
  }

  group('tasks', () {
    test('creates, reads and lists in creation order', () async {
      final store = buildStore();
      final first = await store.createTask(task());
      await store.createTask(
        task(
          id: 'atm_00000000000000000000000000000002',
          createdAt: DateTime.utc(2026, 1, 1, 13),
        ),
      );
      final all = await store.listTasks();
      expect(all, hasLength(2));
      expect(all.first.taskId, first.taskId);
      expect((await store.findTask(first.taskId))!.revision, 0);
      expect(await store.findTask(AutomationTaskId('atm_${'0' * 32}')), isNull);
    });

    test('rejects a duplicate create and a wrong new revision', () async {
      final store = buildStore();
      await store.createTask(task());
      await expectLater(
        store.createTask(task()),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.conflict,
          ),
        ),
      );
      await expectLater(
        store.saveTask(task(revision: 2), expectedRevision: 0),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.invalidInput,
          ),
        ),
      );
    });

    test('checks the stored revision before appending', () async {
      final store = buildStore();
      await store.createTask(task());
      await store.saveTask(task(revision: 1), expectedRevision: 0);
      await expectLater(
        store.saveTask(task(revision: 2), expectedRevision: 0),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.revisionMismatch,
          ),
        ),
      );
      final saved = await store.saveTask(
        task(revision: 2),
        expectedRevision: 1,
      );
      expect(saved.revision, 2);
    });

    test('keeps a tombstone out of the default list', () async {
      final store = buildStore();
      await store.createTask(task());
      await store.saveTask(
        task(state: AutomationTaskState.deleted, revision: 1),
        expectedRevision: 0,
      );
      expect(await store.listTasks(), isEmpty);
      expect(await store.listTasks(includeDeleted: true), hasLength(1));
    });

    test('replays after a restart', () async {
      final first = buildStore();
      await first.createTask(task());
      await first.saveTask(task(revision: 1), expectedRevision: 0);

      final second = buildStore();
      final replayed = await second.findTask(
        AutomationTaskId('atm_00000000000000000000000000000001'),
      );
      expect(replayed!.revision, 1);
      expect(replayed.state, AutomationTaskState.active);
    });

    test('fails closed on a damaged stream', () async {
      final store = buildStore();
      await store.createTask(task());
      storage.replaceText('task-atm_00000000000000000000000000000001', '{oops');
      final second = buildStore();
      await expectLater(
        second.listTasks(),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.corruption,
          ),
        ),
      );
    });

    test('fails closed on an unknown stream key', () async {
      storage.replaceText('mystery-stream', '{}\n');
      await expectLater(
        buildStore().listTasks(),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.corruption,
          ),
        ),
      );
    });

    test('rejects a tampered revision chain', () async {
      final store = buildStore();
      await store.createTask(task());
      await store.saveTask(task(revision: 1), expectedRevision: 0);
      const key = 'task-atm_00000000000000000000000000000001';
      final chunks = await storage.read(key);
      final text = utf8.decode(
        (await chunks!.toList()).expand((c) => c).toList(),
      );
      final tampered = text.replaceFirst(
        '"expectedRevision":0,"entryRevision":1',
        '"expectedRevision":5,"entryRevision":1',
      );
      expect(tampered, isNot(text));
      storage.replaceText(key, tampered);
      await expectLater(
        buildStore().listTasks(),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.corruption,
          ),
        ),
      );
    });

    test('tolerates and repairs a truncated tail', () async {
      final store = buildStore();
      await store.createTask(task());
      storage.appendText(
        'task-atm_00000000000000000000000000000001',
        '{"type":"domovoy.automation_operation","version":1,"stream',
      );
      final second = buildStore();
      final replayed = await second.findTask(
        AutomationTaskId('atm_00000000000000000000000000000001'),
      );
      expect(replayed, isNotNull);
      final saved = await second.saveTask(
        task(revision: 1),
        expectedRevision: 0,
      );
      expect(saved.revision, 1);
      // The repaired stream replays again without the fragment.
      final third = buildStore();
      expect((await third.findTask(replayed!.taskId))!.revision, 1);
    });

    test('maps storage failures to persistence', () async {
      storage.failList = true;
      await expectLater(
        buildStore().listTasks(),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.persistence,
          ),
        ),
      );
    });

    test('rejects a record larger than the task byte limit', () async {
      final store = buildStore(
        limits: const AutomationLimits(maxTaskBytes: 512),
      );
      await expectLater(
        store.createTask(
          AutomationTask(
            taskId: 'atm_00000000000000000000000000000001',
            name: 'Большая задача',
            prompt: 'x' * 2000,
            schedule: AutomationSchedule.cron(
              expression: '*/5 * * * *',
              timeZoneId: 'Europe/Moscow',
            ),
            model: automationModel(),
            state: AutomationTaskState.active,
            origin: AutomationTaskOrigin.human,
            nextDueAt: DateTime.utc(2026, 1, 1, 12, 5),
            createdAt: DateTime.utc(2026, 1, 1, 12),
            updatedAt: DateTime.utc(2026, 1, 1, 12),
          ),
        ),
        throwsA(isA<AutomationException>()),
      );
    });
  });

  group('runs', () {
    test('appends a running record and a terminal record', () async {
      final store = buildStore();
      await store.createTask(task());
      await store.appendRun(run(), expectedRevision: 0);
      final terminal = run(status: AutomationRunStatus.succeeded, revision: 1);
      await store.appendRun(terminal, expectedRevision: 0);
      final stored = await store.findRun(
        AutomationRunId('ran_00000000000000000000000000000001'),
      );
      expect(stored!.status, AutomationRunStatus.succeeded);
      expect(stored.revision, 1);
    });

    test('rejects a second terminal record and revision gaps', () async {
      final store = buildStore();
      await store.createTask(task());
      await store.appendRun(run(), expectedRevision: 0);
      await store.appendRun(
        run(status: AutomationRunStatus.succeeded, revision: 1),
        expectedRevision: 0,
      );
      await expectLater(
        store.appendRun(
          run(status: AutomationRunStatus.failed, revision: 2),
          expectedRevision: 0,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.revisionMismatch,
          ),
        ),
      );
    });

    test('enforces (taskId, scheduledAt) idempotency in the store', () async {
      final store = buildStore();
      await store.createTask(task());
      await store.appendRun(run(), expectedRevision: 0);
      await expectLater(
        store.appendRun(
          run(id: 'ran_00000000000000000000000000000002'),
          expectedRevision: 0,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.conflict,
          ),
        ),
      );
      // A different period for the same task is fine.
      await store.appendRun(
        run(
          id: 'ran_00000000000000000000000000000003',
          scheduledAt: DateTime.utc(2026, 1, 1, 12, 10),
        ),
        expectedRevision: 0,
      );
    });

    test(
      'a manual run does not occupy or consume a scheduled period',
      () async {
        final store = buildStore();
        final taskId = AutomationTaskId('atm_00000000000000000000000000000001');
        await store.createTask(task());
        await store.appendRun(
          run(
            id: 'ran_00000000000000000000000000000001',
            trigger: AutomationRunTrigger.manual,
          ),
          expectedRevision: 0,
        );
        // The period key stays free for the scheduled run at the same instant.
        expect(
          await store.findPeriodRun(taskId, DateTime.utc(2026, 1, 1, 12, 5)),
          isNull,
        );
        await store.appendRun(
          run(
            id: 'ran_00000000000000000000000000000002',
            trigger: AutomationRunTrigger.scheduled,
          ),
          expectedRevision: 0,
        );
        expect(
          (await store.findPeriodRun(
            taskId,
            DateTime.utc(2026, 1, 1, 12, 5),
          ))!.runId.value,
          'ran_00000000000000000000000000000002',
        );
        // A second *period* run for the same instant conflicts...
        await expectLater(
          store.appendRun(
            run(
              id: 'ran_00000000000000000000000000000003',
              trigger: AutomationRunTrigger.catchUp,
            ),
            expectedRevision: 0,
          ),
          throwsA(
            isA<AutomationException>().having(
              (error) => error.error.kind,
              'kind',
              AutomationErrorKind.conflict,
            ),
          ),
        );
        // ...while another manual run at the same unchanged instant is fine.
        await store.appendRun(
          run(
            id: 'ran_00000000000000000000000000000004',
            trigger: AutomationRunTrigger.manual,
          ),
          expectedRevision: 0,
        );
        final all = await store.listRuns(taskId: taskId);
        expect(all, hasLength(3));
      },
    );

    test('replay keeps period idempotency across a restart', () async {
      final first = buildStore();
      final taskId = AutomationTaskId('atm_00000000000000000000000000000001');
      await first.createTask(task());
      await first.appendRun(
        run(
          id: 'ran_00000000000000000000000000000001',
          trigger: AutomationRunTrigger.scheduled,
        ),
        expectedRevision: 0,
      );
      await first.appendRun(
        run(
          id: 'ran_00000000000000000000000000000002',
          trigger: AutomationRunTrigger.manual,
        ),
        expectedRevision: 0,
      );

      final second = buildStore();
      expect(
        (await second.findPeriodRun(
          taskId,
          DateTime.utc(2026, 1, 1, 12, 5),
        ))!.runId.value,
        'ran_00000000000000000000000000000001',
      );
      // The replayed period is still consumed after a restart.
      await expectLater(
        second.appendRun(
          run(
            id: 'ran_00000000000000000000000000000003',
            trigger: AutomationRunTrigger.catchUp,
          ),
          expectedRevision: 0,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.conflict,
          ),
        ),
      );
      // A manual run at the same instant is never blocked by the period.
      await second.appendRun(
        run(
          id: 'ran_00000000000000000000000000000004',
          trigger: AutomationRunTrigger.manual,
        ),
        expectedRevision: 0,
      );
    });

    test('lists runs newest first and finds by schedule', () async {
      final store = buildStore();
      await store.createTask(task());
      await store.appendRun(
        run(
          id: 'ran_00000000000000000000000000000001',
          scheduledAt: DateTime.utc(2026, 1, 1, 12, 5),
        ),
        expectedRevision: 0,
      );
      await store.appendRun(
        run(
          id: 'ran_00000000000000000000000000000002',
          scheduledAt: DateTime.utc(2026, 1, 1, 12, 10),
        ),
        expectedRevision: 0,
      );
      final listed = await store.listRuns(
        taskId: AutomationTaskId('atm_00000000000000000000000000000001'),
      );
      expect(listed, hasLength(2));
      expect(listed.first.scheduledAt, DateTime.utc(2026, 1, 1, 12, 10));
      final found = await store.findPeriodRun(
        AutomationTaskId('atm_00000000000000000000000000000001'),
        DateTime.utc(2026, 1, 1, 12, 5),
      );
      expect(found!.runId.value, 'ran_00000000000000000000000000000001');
      expect(await store.listRunningRuns(), hasLength(2));
    });

    test('replays run history after a restart', () async {
      final first = buildStore();
      await first.createTask(task());
      await first.appendRun(run(), expectedRevision: 0);
      await first.appendRun(
        run(status: AutomationRunStatus.failed, revision: 1),
        expectedRevision: 0,
      );
      final second = buildStore();
      final stored = await second.findRun(
        AutomationRunId('ran_00000000000000000000000000000001'),
      );
      expect(stored!.status, AutomationRunStatus.failed);
      expect(await second.listRunningRuns(), isEmpty);
    });

    test('a fourth run record is rejected', () async {
      final store = buildStore();
      await store.createTask(task());
      await store.appendRun(run(), expectedRevision: 0);
      await store.appendRun(
        run(status: AutomationRunStatus.succeeded, revision: 1),
        expectedRevision: 0,
      );
      await store.appendRun(
        run(status: AutomationRunStatus.succeeded, revision: 2),
        expectedRevision: 1,
      );
      await expectLater(
        store.appendRun(
          run(status: AutomationRunStatus.succeeded, revision: 3),
          expectedRevision: 2,
        ),
        throwsA(isA<AutomationException>()),
      );
    });
  });
}

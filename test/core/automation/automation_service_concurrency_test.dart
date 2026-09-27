import 'dart:async';

import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

/// Deterministic interleaving tests for the scheduler start boundary.
///
/// The gated repository holds selected store operations so a test can run a
/// competing call while the first one is suspended mid-start.
void main() {
  ({
    AutomationService service,
    GatedAutomationRepository repository,
    FakeAutomationClock clock,
    ScriptedAutomationExecutor executor,
  })
  build({DateTime? now}) {
    final repository = GatedAutomationRepository(
      InMemoryAutomationRepository(),
    );
    final clock = FakeAutomationClock(now ?? DateTime.utc(2026, 1, 1, 12));
    final executor = ScriptedAutomationExecutor();
    final service = AutomationService(
      tasks: repository,
      runs: repository,
      executor: executor,
      timeZones: automationTestZones(),
      clock: clock,
      ids: SequentialAutomationIdGenerator(),
    );
    return (
      service: service,
      repository: repository,
      clock: clock,
      executor: executor,
    );
  }

  Future<void> pump([int rounds = 12]) async {
    for (var index = 0; index < rounds; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('parallel manual calls start at most one run', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.repository.gate('appendRun');

    final first = harness.service.runTaskNow(task.taskId);
    await pump();
    expect(harness.repository.callsFor('appendRun'), 1);

    // The second call arrives while the first is still starting.
    await expectLater(
      harness.service.runTaskNow(task.taskId),
      throwsA(
        isA<AutomationException>().having(
          (error) => error.error.kind,
          'kind',
          AutomationErrorKind.noOverlap,
        ),
      ),
    );

    harness.repository.release('appendRun');
    final handle = await first;
    await handle.done;
    await harness.service.waitForIdle();

    final runs = await harness.repository.listRuns(taskId: task.taskId);
    expect(runs, hasLength(1));
    expect(runs.single.trigger, AutomationRunTrigger.manual);
    expect(harness.executor.requests, hasLength(1));
    await harness.service.dispose();
  });

  test('a manual start and a due tick never both launch', () async {
    final execution = Completer<void>();
    final harness = build();
    harness.executor.handler = (request, cancellation) async {
      await execution.future;
      return AutomationRunOutcome(
        status: AutomationRunStatus.succeeded,
        resultText: 'готово',
      );
    };
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.repository.gate('appendRun');
    harness.clock.advance(const Duration(minutes: 5));

    // The manual call reserves the task synchronously before the timer tick
    // resumes; the tick must defer, not record a skip for a start that has not
    // committed yet.
    final manual = harness.service.runTaskNow(task.taskId);
    final tick = harness.service.tick();
    await pump();
    expect(harness.repository.callsFor('appendRun'), 1);

    harness.repository.release('appendRun');
    final handle = await manual;
    await tick;
    // The manual run is now executing; the still-due period is recorded as
    // skipped (no queue, no second execution).
    await harness.service.tick();
    expect(harness.executor.requests, hasLength(1));

    execution.complete();
    await handle.done;
    await harness.service.waitForIdle();

    final runs = await harness.repository.listRuns(taskId: task.taskId);
    final executed = runs
        .where((run) => run.status == AutomationRunStatus.succeeded)
        .toList();
    final skipped = runs
        .where((run) => run.status == AutomationRunStatus.skipped)
        .toList();
    expect(executed, hasLength(1));
    expect(executed.single.trigger, AutomationRunTrigger.manual);
    expect(skipped, hasLength(1));
    expect(skipped.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 5));
    expect(skipped.single.error!.kind, AutomationRunErrorKind.noOverlap);
    // Exactly one agent execution, and it was the manual one.
    expect(harness.executor.requests, hasLength(1));
    expect(
      harness.executor.requests.single.trigger,
      AutomationRunTrigger.manual,
    );
    // The plan advanced past the skipped period.
    final stored = await harness.repository.findTask(task.taskId);
    expect(stored!.nextDueAt, DateTime.utc(2026, 1, 1, 12, 10));
    await harness.service.dispose();
  });

  test(
    'a failed manual start does not let a due tick consume the period',
    () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      // The manual call reserves the task, then blocks on the task read.
      harness.repository.gate('findTask');
      final manual = harness.service.runTaskNow(
        task.taskId,
        expectedRevision: task.revision + 1,
      );
      await pump();
      expect(harness.repository.callsFor('findTask'), greaterThanOrEqualTo(1));

      // The due tick saw only a pending reservation: it must not mark the period
      // skipped.
      harness.repository.release('findTask');
      await expectLater(
        manual,
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.revisionMismatch,
          ),
        ),
      );
      expect(harness.executor.requests, isEmpty);
      expect(harness.repository.inner.runs, isEmpty);

      // The period was never consumed: the retry tick fires it exactly once.
      harness.clock.advance(const Duration(milliseconds: 60));
      await harness.service.tick();
      await harness.service.waitForIdle();
      final runs = await harness.repository.listRuns(taskId: task.taskId);
      expect(runs, hasLength(1));
      expect(runs.single.trigger, AutomationRunTrigger.scheduled);
      expect(runs.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 5));
      expect(harness.executor.requests, hasLength(1));
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.nextDueAt, DateTime.utc(2026, 1, 1, 12, 10));
      await harness.service.dispose();
    },
  );

  test('pause during a gated append closes the committed run', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.clock.advance(const Duration(minutes: 5));
    harness.repository.gate('appendRun');

    final tick = harness.service.tick();
    await pump();
    expect(harness.repository.callsFor('appendRun'), 1);
    await harness.service.setPaused(task.taskId, true);
    harness.repository.release('appendRun');
    await tick;
    await harness.service.waitForIdle();

    expect(harness.executor.requests, isEmpty);
    final runs = await harness.repository.listRuns(taskId: task.taskId);
    expect(runs, hasLength(1));
    expect(runs.single.status, AutomationRunStatus.interrupted);
    expect(runs.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 5));
    final stored = await harness.repository.findTask(task.taskId);
    expect(stored!.state, AutomationTaskState.paused);
    expect(stored.nextDueAt, isNull);

    // Resume skips the interrupted period and never replays it.
    final resumed = await harness.service.setPaused(task.taskId, false);
    expect(resumed.nextDueAt, DateTime.utc(2026, 1, 1, 12, 10));
    harness.clock.advance(const Duration(milliseconds: 60));
    await harness.service.tick();
    await harness.service.waitForIdle();
    expect(harness.executor.requests, isEmpty);
    await harness.service.dispose();
  });

  test('delete during a gated append closes the committed run', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.clock.advance(const Duration(minutes: 5));
    harness.repository.gate('appendRun');

    final tick = harness.service.tick();
    await pump();
    expect(harness.repository.callsFor('appendRun'), 1);
    final deleted = await harness.service.deleteTask(task.taskId);
    expect(deleted.state, AutomationTaskState.deleted);
    harness.repository.release('appendRun');
    await tick;
    await harness.service.waitForIdle();

    expect(harness.executor.requests, isEmpty);
    final runs = await harness.repository.listRuns(taskId: task.taskId);
    expect(runs, hasLength(1));
    expect(runs.single.status, AutomationRunStatus.interrupted);
    final stored = await harness.repository.findTask(task.taskId);
    expect(stored!.state, AutomationTaskState.deleted);
    expect(stored.nextDueAt, isNull);
    await harness.service.dispose();
  });

  test('edit during a gated append closes the committed run', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.clock.advance(const Duration(minutes: 5));
    harness.repository.gate('appendRun');

    final tick = harness.service.tick();
    await pump();
    expect(harness.repository.callsFor('appendRun'), 1);
    final updated = await harness.service.updateTask(
      task.taskId,
      automationDraft(
        name: 'Новая версия',
        schedule: AutomationSchedule.cron(
          expression: '0 9 * * *',
          timeZoneId: 'Europe/Moscow',
        ),
      ),
    );
    harness.repository.release('appendRun');
    await tick;
    await harness.service.waitForIdle();

    expect(harness.executor.requests, isEmpty);
    final runs = await harness.repository.listRuns(taskId: task.taskId);
    expect(runs, hasLength(1));
    expect(runs.single.status, AutomationRunStatus.interrupted);
    final stored = await harness.repository.findTask(task.taskId);
    expect(stored!.revision, updated.revision);
    expect(stored.nextDueAt, DateTime.utc(2026, 1, 2, 6));
    // The old period is consumed, not replayed on the next tick.
    await harness.service.tick();
    await harness.service.waitForIdle();
    expect(harness.executor.requests, isEmpty);
    await harness.service.dispose();
  });

  test('delete during a gated manual append closes the record', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.repository.gate('appendRun');

    final manual = harness.service.runTaskNow(task.taskId);
    await pump();
    expect(harness.repository.callsFor('appendRun'), 1);
    await harness.service.deleteTask(task.taskId);
    harness.repository.release('appendRun');
    await expectLater(manual, throwsA(isA<AutomationException>()));
    await harness.service.waitForIdle();

    expect(harness.executor.requests, isEmpty);
    final runs = await harness.repository.listRuns(taskId: task.taskId);
    expect(runs, hasLength(1));
    expect(runs.single.status, AutomationRunStatus.interrupted);
    expect(runs.single.trigger, AutomationRunTrigger.manual);
    await harness.service.dispose();
  });

  test(
    'an aborted manual start reports the committed interrupted record',
    () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      final cancellation = CancellationSource();
      harness.repository.gate('appendRun');

      final manual = harness.service.runTaskNow(
        task.taskId,
        cancellation: cancellation.token,
      );
      await pump();
      expect(harness.repository.callsFor('appendRun'), 1);
      cancellation.cancel();
      harness.repository.release('appendRun');

      final handle = await manual;
      expect(handle.status, AutomationRunStatus.interrupted);
      final terminal = await handle.done;
      expect(terminal.status, AutomationRunStatus.interrupted);
      expect(terminal.error!.kind, AutomationRunErrorKind.interrupted);
      expect(harness.executor.requests, isEmpty);
      expect(harness.repository.inner.runs, hasLength(1));
      await harness.service.dispose();
    },
  );

  test('an aborted manual start before the commit creates no record', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    final cancellation = CancellationSource();
    harness.repository.gate('findTask');

    final manual = harness.service.runTaskNow(
      task.taskId,
      cancellation: cancellation.token,
    );
    await pump();
    expect(harness.repository.callsFor('findTask'), greaterThanOrEqualTo(1));
    cancellation.cancel();
    harness.repository.release('findTask');

    await expectLater(
      manual,
      throwsA(
        isA<AutomationException>().having(
          (error) => error.error.kind,
          'kind',
          AutomationErrorKind.cancelled,
        ),
      ),
    );
    expect(harness.repository.inner.runs, isEmpty);
    expect(harness.executor.requests, isEmpty);
    await harness.service.dispose();
  });

  test('pause during a due tick prevents the run', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.clock.advance(const Duration(minutes: 5));
    harness.repository.gate('findPeriodRun');

    final tick = harness.service.tick();
    await pump();
    expect(harness.repository.callsFor('findPeriodRun'), 1);

    final paused = await harness.service.setPaused(task.taskId, true);
    expect(paused.state, AutomationTaskState.paused);

    harness.repository.release('findPeriodRun');
    await tick;
    await harness.service.waitForIdle();

    expect(harness.repository.inner.runs, isEmpty);
    expect(harness.executor.requests, isEmpty);
    final stored = await harness.repository.findTask(task.taskId);
    expect(stored!.state, AutomationTaskState.paused);
    expect(stored.nextDueAt, isNull);
    await harness.service.dispose();
  });

  test('delete during a due tick prevents the run', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.clock.advance(const Duration(minutes: 5));
    harness.repository.gate('findPeriodRun');

    final tick = harness.service.tick();
    await pump();
    expect(harness.repository.callsFor('findPeriodRun'), 1);

    final deleted = await harness.service.deleteTask(task.taskId);
    expect(deleted.state, AutomationTaskState.deleted);

    harness.repository.release('findPeriodRun');
    await tick;
    await harness.service.waitForIdle();

    expect(harness.repository.inner.runs, isEmpty);
    expect(harness.executor.requests, isEmpty);
    await harness.service.dispose();
  });

  test(
    'background during a due tick prevents the run, resume catches up',
    () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      harness.repository.gate('findPeriodRun');

      final tick = harness.service.tick();
      await pump();
      expect(harness.repository.callsFor('findPeriodRun'), 1);

      harness.service.setForeground(false);
      harness.repository.release('findPeriodRun');
      await tick;
      await harness.service.waitForIdle();

      expect(harness.repository.inner.runs, isEmpty);
      expect(harness.executor.requests, isEmpty);
      // The period stays for the foreground catch-up.
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.nextDueAt, DateTime.utc(2026, 1, 1, 12, 5));

      harness.service.setForeground(true);
      await harness.service.tick();
      await harness.service.waitForIdle();
      final runs = await harness.repository.listRuns(taskId: task.taskId);
      expect(runs, hasLength(1));
      expect(runs.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 5));
      expect(harness.executor.requests, hasLength(1));
      await harness.service.dispose();
    },
  );

  test('stop during a due tick prevents the run until restart', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.clock.advance(const Duration(minutes: 5));
    harness.repository.gate('findPeriodRun');

    final tick = harness.service.tick();
    await pump();
    expect(harness.repository.callsFor('findPeriodRun'), 1);

    await harness.service.stop();
    harness.repository.release('findPeriodRun');
    await tick;
    await harness.service.waitForIdle();
    expect(harness.repository.inner.runs, isEmpty);
    expect(harness.executor.requests, isEmpty);

    await harness.service.start();
    await harness.service.waitForIdle();
    final runs = await harness.repository.listRuns(taskId: task.taskId);
    expect(runs, hasLength(1));
    expect(harness.executor.requests, hasLength(1));
    await harness.service.dispose();
  });

  test('manual runs fail visibly while backgrounded or stopped', () async {
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());

    harness.service.setForeground(false);
    await expectLater(
      harness.service.runTaskNow(task.taskId),
      throwsA(
        isA<AutomationException>().having(
          (error) => error.error.kind,
          'kind',
          AutomationErrorKind.cancelled,
        ),
      ),
    );

    harness.service.setForeground(true);
    await harness.service.stop();
    await expectLater(
      harness.service.runTaskNow(task.taskId),
      throwsA(
        isA<AutomationException>().having(
          (error) => error.error.kind,
          'kind',
          AutomationErrorKind.cancelled,
        ),
      ),
    );
    expect(harness.repository.inner.runs, isEmpty);
    expect(harness.executor.requests, isEmpty);
    await harness.service.dispose();
  });

  group('deleteTask cancellation ordering', () {
    test('an aborted delete does not cancel an active run', () async {
      final execution = Completer<void>();
      AutomationResultCancellation? runCancellation;
      final harness = build();
      harness.executor.handler = (request, cancellation) async {
        runCancellation = cancellation;
        await execution.future;
        return AutomationRunOutcome(
          status: AutomationRunStatus.succeeded,
          resultText: 'ok',
        );
      };
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      final handle = await harness.service.runTaskNow(task.taskId);
      await pump();
      expect(runCancellation, isNotNull);

      final cancellation = CancellationSource()..cancel();
      await expectLater(
        harness.service.deleteTask(
          task.taskId,
          cancellation: cancellation.token,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.cancelled,
          ),
        ),
      );
      // The run keeps executing: the tombstone was never committed.
      expect(runCancellation!.isCancelled, isFalse);
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.state, AutomationTaskState.active);
      expect(
        (await harness.repository.listRuns(taskId: task.taskId)).single.status,
        AutomationRunStatus.running,
      );

      execution.complete();
      final run = await handle.done;
      expect(run.status, AutomationRunStatus.succeeded);
      await harness.service.dispose();
    });

    test('a revision-mismatch delete does not cancel an active run', () async {
      final execution = Completer<void>();
      AutomationResultCancellation? runCancellation;
      final harness = build();
      harness.executor.handler = (request, cancellation) async {
        runCancellation = cancellation;
        await execution.future;
        return AutomationRunOutcome(
          status: AutomationRunStatus.succeeded,
          resultText: 'ok',
        );
      };
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      final handle = await harness.service.runTaskNow(task.taskId);
      await pump();
      expect(runCancellation, isNotNull);

      await expectLater(
        harness.service.deleteTask(
          task.taskId,
          expectedRevision: task.revision + 1,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.revisionMismatch,
          ),
        ),
      );
      expect(runCancellation!.isCancelled, isFalse);
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.state, AutomationTaskState.active);

      execution.complete();
      final run = await handle.done;
      expect(run.status, AutomationRunStatus.succeeded);
      await harness.service.dispose();
    });

    test(
      'a successful delete cancels the active run after the commit',
      () async {
        final execution = Completer<void>();
        AutomationResultCancellation? runCancellation;
        final harness = build();
        harness.executor.handler = (request, cancellation) async {
          runCancellation = cancellation;
          await execution.future;
          return AutomationRunOutcome(
            status: AutomationRunStatus.succeeded,
            resultText: 'ok',
          );
        };
        await harness.service.start();
        final task = await harness.service.createTask(automationDraft());
        final handle = await harness.service.runTaskNow(task.taskId);
        await pump();
        expect(runCancellation, isNotNull);

        final deleted = await harness.service.deleteTask(task.taskId);
        expect(deleted.state, AutomationTaskState.deleted);
        expect(runCancellation!.isCancelled, isTrue);

        execution.complete();
        final run = await handle.done;
        expect(run.status, AutomationRunStatus.interrupted);
        expect(run.error!.kind, AutomationRunErrorKind.interrupted);
        await harness.service.dispose();
      },
    );

    test(
      'a delete aborted during the write returns the tombstone and cancels the run',
      () async {
        final execution = Completer<void>();
        AutomationResultCancellation? runCancellation;
        final harness = build();
        harness.executor.handler = (request, cancellation) async {
          runCancellation = cancellation;
          await execution.future;
          return AutomationRunOutcome(
            status: AutomationRunStatus.succeeded,
            resultText: 'ok',
          );
        };
        await harness.service.start();
        final task = await harness.service.createTask(automationDraft());
        final handle = await harness.service.runTaskNow(task.taskId);
        await pump();
        expect(runCancellation, isNotNull);

        final cancellation = CancellationSource();
        harness.repository.gate('saveTask');
        final deleting = harness.service.deleteTask(
          task.taskId,
          cancellation: cancellation.token,
        );
        await pump();
        expect(harness.repository.callsFor('saveTask'), 1);
        cancellation.cancel();
        harness.repository.release('saveTask');

        // The committed tombstone is the truth, not a fabricated cancellation.
        final deleted = await deleting;
        expect(deleted.state, AutomationTaskState.deleted);
        expect(runCancellation!.isCancelled, isTrue);

        execution.complete();
        final run = await handle.done;
        expect(run.status, AutomationRunStatus.interrupted);
        await harness.service.dispose();
      },
    );
  });
}

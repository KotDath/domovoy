import 'package:domovoy/core/automation/automation.dart';
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
    final harness = build();
    await harness.service.start();
    final task = await harness.service.createTask(automationDraft());
    harness.clock.advance(const Duration(minutes: 5));
    harness.repository.gate('appendRun');

    final manual = harness.service.runTaskNow(task.taskId);
    final tick = harness.service.tick();
    await pump();
    // Both the manual start and the tick's skipped-period record are held at
    // the store boundary; the tick must not launch a second execution.
    expect(harness.repository.callsFor('appendRun'), 2);

    harness.repository.release('appendRun');
    final handle = await manual;
    await handle.done;
    await tick;
    await harness.service.waitForIdle();

    final runs = await harness.repository.listRuns(taskId: task.taskId);
    expect(runs, hasLength(2));
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
}

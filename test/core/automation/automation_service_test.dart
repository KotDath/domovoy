import 'dart:async';

import 'package:domovoy/core/automation/automation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

void main() {
  const moscowCron = '*/5 * * * *';

  ({
    AutomationService service,
    InMemoryAutomationRepository repository,
    FakeAutomationClock clock,
    ScriptedAutomationExecutor executor,
  })
  build({
    AutomationResultDelivery? delivery,
    AutomationLimits limits = const AutomationLimits(),
    DateTime? now,
  }) {
    final repository = InMemoryAutomationRepository();
    final clock = FakeAutomationClock(now ?? DateTime.utc(2026, 1, 1, 12));
    final executor = ScriptedAutomationExecutor();
    final service = AutomationService(
      tasks: repository,
      runs: repository,
      executor: executor,
      timeZones: automationTestZones(),
      clock: clock,
      limits: limits,
      delivery: delivery,
      ids: SequentialAutomationIdGenerator(),
    );
    return (
      service: service,
      repository: repository,
      clock: clock,
      executor: executor,
    );
  }

  group('task lifecycle', () {
    test('human creation activates and arms the next */5 instant', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());

      expect(task.state, AutomationTaskState.active);
      expect(task.origin, AutomationTaskOrigin.human);
      expect(task.nextDueAt, DateTime.utc(2026, 1, 1, 12, 5));
      expect(harness.clock.activeTimerCount, 1);
      await harness.service.dispose();
    });

    test('agent creation is a proposal until a human confirms', () async {
      final harness = build();
      await harness.service.start();
      final proposed = await harness.service.createTask(
        automationDraft(),
        origin: AutomationCallOrigin.agentTool,
      );
      expect(proposed.state, AutomationTaskState.proposed);
      expect(proposed.origin, AutomationTaskOrigin.agent);

      // A proposal is not armed and cannot be run by an agent tool.
      await expectLater(
        harness.service.runTaskNow(
          proposed.taskId,
          origin: AutomationCallOrigin.agentTool,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.denied,
          ),
        ),
      );

      final confirmed = await harness.service.confirmTask(proposed.taskId);
      expect(confirmed.state, AutomationTaskState.active);
      expect(confirmed.revision, proposed.revision + 1);
      expect(confirmed.nextDueAt, isNotNull);
      await harness.service.dispose();
    });

    test(
      'pause clears the plan and resume never replays paused periods',
      () async {
        final harness = build();
        await harness.service.start();
        final task = await harness.service.createTask(automationDraft());
        final paused = await harness.service.setPaused(task.taskId, true);
        expect(paused.state, AutomationTaskState.paused);
        expect(paused.nextDueAt, isNull);
        expect(harness.clock.activeTimerCount, 0);

        harness.clock.advance(const Duration(minutes: 30));
        await harness.service.tick();
        expect(harness.repository.runs, isEmpty);

        final resumed = await harness.service.setPaused(task.taskId, false);
        expect(resumed.state, AutomationTaskState.active);
        expect(resumed.nextDueAt, DateTime.utc(2026, 1, 1, 12, 35));
        await harness.service.dispose();
      },
    );

    test('revision checks protect pause and confirmation', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      await harness.service.setPaused(task.taskId, true);
      await expectLater(
        harness.service.setPaused(
          task.taskId,
          false,
          expectedRevision: task.revision,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.revisionMismatch,
          ),
        ),
      );
      await harness.service.dispose();
    });

    test('delete leaves a tombstone and cancels the plan', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      final deleted = await harness.service.deleteTask(task.taskId);
      expect(deleted.state, AutomationTaskState.deleted);
      expect(deleted.nextDueAt, isNull);
      expect(await harness.service.findTask(task.taskId), isNull);
      final all = await harness.repository.listTasks(includeDeleted: true);
      expect(all.single.state, AutomationTaskState.deleted);
      await harness.service.dispose();
    });

    test(
      'a one-shot task completes after its fire even if the run fails',
      () async {
        final harness = build();
        harness.executor.handler = (request, cancellation) async {
          return AutomationRunOutcome(
            status: AutomationRunStatus.failed,
            error: AutomationRunError(
              kind: AutomationRunErrorKind.provider,
              message: 'Провайдер недоступен',
            ),
          );
        };
        await harness.service.start();
        final task = await harness.service.createTask(
          automationDraft(
            schedule: AutomationSchedule.oneShot(
              DateTime.utc(2026, 1, 1, 12, 5),
            ),
          ),
        );
        expect(task.state, AutomationTaskState.active);
        harness.clock.advance(const Duration(minutes: 5));
        await harness.service.tick();
        await harness.service.waitForIdle();

        final stored = await harness.repository.findTask(task.taskId);
        expect(stored!.state, AutomationTaskState.completed);
        expect(stored.nextDueAt, isNull);
        final runs = await harness.repository.listRuns(taskId: task.taskId);
        expect(runs.single.status, AutomationRunStatus.failed);
        expect(runs.single.trigger, AutomationRunTrigger.scheduled);
        await harness.service.dispose();
      },
    );

    test('a one-shot in the past is rejected', () async {
      final harness = build();
      await harness.service.start();
      await expectLater(
        harness.service.createTask(
          automationDraft(
            schedule: AutomationSchedule.oneShot(
              DateTime.utc(2026, 1, 1, 11, 59),
            ),
          ),
        ),
        throwsA(isA<AutomationException>()),
      );
      await harness.service.dispose();
    });
  });

  group('*/5 fake clock', () {
    test('fires at the stored instant and advances the plan', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());

      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      await harness.service.waitForIdle();

      final runs = await harness.repository.listRuns(taskId: task.taskId);
      expect(runs, hasLength(1));
      expect(runs.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 5));
      expect(runs.single.status, AutomationRunStatus.succeeded);
      expect(runs.single.resultText, contains('готова'));
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.nextDueAt, DateTime.utc(2026, 1, 1, 12, 10));

      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      await harness.service.waitForIdle();
      final all = await harness.repository.listRuns(taskId: task.taskId);
      expect(all, hasLength(2));
      expect(all.first.scheduledAt, DateTime.utc(2026, 1, 1, 12, 10));
      await harness.service.dispose();
    });

    test('repeated ticks for the same period never duplicate a run', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      await harness.service.tick();
      await harness.service.tick();
      await harness.service.waitForIdle();
      final runs = await harness.repository.listRuns(taskId: task.taskId);
      expect(runs, hasLength(1));
      await harness.service.dispose();
    });

    test('concurrent ticks coalesce into one execution', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      final first = harness.service.tick();
      final second = harness.service.tick();
      await Future.wait(<Future<void>>[first, second]);
      await harness.service.waitForIdle();
      final runs = await harness.repository.listRuns(taskId: task.taskId);
      expect(runs, hasLength(1));
      await harness.service.dispose();
    });

    test('run-now does not shift the planned moment', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      final planned = task.nextDueAt;

      final handle = await harness.service.runTaskNow(task.taskId);
      expect(handle.trigger, AutomationRunTrigger.manual);
      await handle.done;

      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.nextDueAt, planned);
      final runs = await harness.repository.listRuns(taskId: task.taskId);
      expect(runs.single.trigger, AutomationRunTrigger.manual);
      expect(runs.single.status, AutomationRunStatus.succeeded);
      await harness.service.dispose();
    });

    test('manual run of a paused or completed task is allowed', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      await harness.service.setPaused(task.taskId, true);
      final handle = await harness.service.runTaskNow(task.taskId);
      await handle.done;
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.state, AutomationTaskState.paused);
      expect(stored.nextDueAt, isNull);
      await harness.service.dispose();
    });
  });

  group('catch-up and crash recovery', () {
    test('one catch-up aggregates older missed periods as skipped', () async {
      final repository = InMemoryAutomationRepository();
      final clock = FakeAutomationClock(DateTime.utc(2026, 1, 1, 12));
      final firstExecutor = ScriptedAutomationExecutor();
      final first = AutomationService(
        tasks: repository,
        runs: repository,
        executor: firstExecutor,
        timeZones: automationTestZones(),
        clock: clock,
        ids: SequentialAutomationIdGenerator(),
      );
      await first.start();
      final task = await first.createTask(automationDraft());
      // The application is closed for 17 minutes without any tick.
      clock.advance(const Duration(minutes: 17));
      await first.stop();

      final secondExecutor = ScriptedAutomationExecutor();
      final second = AutomationService(
        tasks: repository,
        runs: repository,
        executor: secondExecutor,
        timeZones: automationTestZones(),
        clock: clock,
        ids: SequentialAutomationIdGenerator(taskStart: 10, runStart: 10),
      );
      await second.start();
      await second.waitForIdle();

      final runs = await repository.listRuns(taskId: task.taskId);
      expect(runs, hasLength(1));
      final run = runs.single;
      expect(run.trigger, AutomationRunTrigger.catchUp);
      expect(run.scheduledAt, DateTime.utc(2026, 1, 1, 12, 15));
      expect(run.aggregatedSkippedCount, 2);
      expect(run.skippedFrom, DateTime.utc(2026, 1, 1, 12, 5));
      final stored = await repository.findTask(task.taskId);
      expect(stored!.nextDueAt, DateTime.utc(2026, 1, 1, 12, 20));
      await second.dispose();
    });

    test(
      'a crash leaves running runs interrupted and is not replayed',
      () async {
        final repository = InMemoryAutomationRepository();
        final clock = FakeAutomationClock(DateTime.utc(2026, 1, 1, 12));
        // Seed the state a crashed process leaves behind: a `running` record for
        // 12:05 and an already advanced nextDueAt of 12:10.
        final task = AutomationTask(
          taskId: 'atm_00000000000000000000000000000001',
          name: 'Сводка',
          prompt: 'Собери сводку.',
          schedule: AutomationSchedule.cron(
            expression: moscowCron,
            timeZoneId: 'Europe/Moscow',
          ),
          model: automationModel(),
          state: AutomationTaskState.active,
          origin: AutomationTaskOrigin.human,
          nextDueAt: DateTime.utc(2026, 1, 1, 12, 10),
          revision: 1,
          createdAt: DateTime.utc(2026, 1, 1, 11, 59),
          updatedAt: DateTime.utc(2026, 1, 1, 12, 5),
        );
        await repository.createTask(
          task.copyWith(
            revision: 0,
            nextDueAt: DateTime.utc(2026, 1, 1, 12, 5),
          ),
        );
        await repository.saveTask(task, expectedRevision: 0);
        await repository.appendRun(
          AutomationRun(
            runId: 'ran_00000000000000000000000000000001',
            taskId: task.taskId.value,
            taskRevision: 1,
            trigger: AutomationRunTrigger.scheduled,
            status: AutomationRunStatus.running,
            scheduledAt: DateTime.utc(2026, 1, 1, 12, 5),
            startedAt: DateTime.utc(2026, 1, 1, 12, 5),
            model: automationModel(),
          ),
          expectedRevision: 0,
        );

        clock.advance(const Duration(minutes: 12));
        final restartedExecutor = ScriptedAutomationExecutor();
        final restarted = AutomationService(
          tasks: repository,
          runs: repository,
          executor: restartedExecutor,
          timeZones: automationTestZones(),
          clock: clock,
          ids: SequentialAutomationIdGenerator(taskStart: 10, runStart: 10),
        );
        await restarted.start();
        await restarted.waitForIdle();

        final runs = await repository.listRuns(taskId: task.taskId);
        expect(runs, hasLength(2));
        final interrupted = runs
            .where((run) => run.status == AutomationRunStatus.interrupted)
            .toList();
        expect(interrupted, hasLength(1));
        expect(interrupted.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 5));
        expect(
          interrupted.single.error!.kind,
          AutomationRunErrorKind.interrupted,
        );
        // The interrupted period is not replayed; the fresh period 12:10 runs.
        final fresh = runs
            .where((run) => run.status == AutomationRunStatus.succeeded)
            .toList();
        expect(fresh, hasLength(1));
        expect(fresh.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 10));
        expect(restartedExecutor.requests, hasLength(1));
        expect(
          restartedExecutor.requests.single.scheduledAt,
          DateTime.utc(2026, 1, 1, 12, 10),
        );
        await restarted.dispose();
      },
    );

    test('missed count is capped and marked truncated', () async {
      final repository = InMemoryAutomationRepository();
      final clock = FakeAutomationClock(DateTime.utc(2026, 1, 1, 12));
      final service = AutomationService(
        tasks: repository,
        runs: repository,
        executor: ScriptedAutomationExecutor(),
        timeZones: automationTestZones(),
        clock: clock,
        limits: const AutomationLimits(maxAggregatedSkipped: 2),
        ids: SequentialAutomationIdGenerator(),
      );
      await service.start();
      final task = await service.createTask(automationDraft());
      clock.advance(const Duration(minutes: 20));
      await service.tick();
      await service.waitForIdle();
      final run = (await repository.listRuns(taskId: task.taskId)).single;
      expect(run.trigger, AutomationRunTrigger.catchUp);
      expect(run.aggregatedSkippedCount, 2);
      expect(run.skippedTruncated, isTrue);
      await service.dispose();
    });
  });

  group('overlap and foreground', () {
    test('a due period while the previous run is active is skipped', () async {
      final gate = Completer<void>();
      final harness = build();
      harness.executor.handler = (request, cancellation) async {
        await gate.future;
        return AutomationRunOutcome(
          status: AutomationRunStatus.succeeded,
          resultText: 'готово',
        );
      };
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      expect(harness.service.isScheduledRunActive, isTrue);

      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      final runs = await harness.repository.listRuns(taskId: task.taskId);
      final skipped = runs
          .where((run) => run.status == AutomationRunStatus.skipped)
          .toList();
      expect(skipped, hasLength(1));
      expect(skipped.single.error!.kind, AutomationRunErrorKind.noOverlap);
      expect(skipped.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 10));

      // A manual start is refused while the task is busy.
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

      gate.complete();
      await harness.service.waitForIdle();
      expect(harness.service.isScheduledRunActive, isFalse);
      await harness.service.dispose();
    });

    test('background stops timers and interrupts the active run', () async {
      final gate = Completer<void>();
      final harness = build();
      harness.executor.handler = (request, cancellation) async {
        await gate.future;
        return AutomationRunOutcome(
          status: AutomationRunStatus.succeeded,
          resultText: 'поздно',
        );
      };
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      // The plan timer and the run deadline timer are armed.
      expect(harness.clock.activeTimerCount, 2);

      harness.service.setForeground(false);
      gate.complete();
      await harness.service.waitForIdle();
      expect(harness.clock.activeTimerCount, 0);
      final runs = await harness.repository.listRuns(taskId: task.taskId);
      expect(runs.single.status, AutomationRunStatus.interrupted);
      expect(runs.single.error!.message, contains('в фон'));
      // An interrupted run is never delivered anywhere.
      expect(runs.single.delivery, isNull);

      // In the background nothing new fires.
      harness.clock.advance(const Duration(minutes: 10));
      await harness.service.tick();
      expect(
        (await harness.repository.listRuns(taskId: task.taskId)),
        hasLength(1),
      );

      harness.service.setForeground(true);
      await harness.service.tick();
      await harness.service.waitForIdle();
      final afterResume = await harness.repository.listRuns(
        taskId: task.taskId,
      );
      expect(afterResume, hasLength(2));
      expect(afterResume.first.trigger, AutomationRunTrigger.catchUp);
      await harness.service.dispose();
    });

    test('time limit stops a hanging run and reports it visibly', () async {
      final harness = build(
        limits: const AutomationLimits(
          run: AutomationRunLimits(maxDuration: Duration(minutes: 5)),
        ),
      );
      harness.executor.handler = (request, cancellation) async {
        await cancellation.whenCancelled;
        return AutomationRunOutcome(
          status: AutomationRunStatus.interrupted,
          resultText: 'частичный текст',
        );
      };
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.waitForIdle();
      final run = (await harness.repository.listRuns(
        taskId: task.taskId,
      )).single;
      expect(run.status, AutomationRunStatus.failed);
      expect(run.error!.kind, AutomationRunErrorKind.timeout);
      expect(run.resultText, 'частичный текст');
      await harness.service.dispose();
    });
  });

  group('failures and delivery', () {
    test('an unavailable model fails before any model call', () async {
      final harness = build();
      harness.executor.availabilityHandler = (task) async =>
          const AutomationRunAvailability.unavailable(
            AutomationRunErrorKind.modelUnavailable,
            'Модель недоступна',
          );
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      await harness.service.waitForIdle();
      final run = (await harness.repository.listRuns(
        taskId: task.taskId,
      )).single;
      expect(run.status, AutomationRunStatus.failed);
      expect(run.error!.kind, AutomationRunErrorKind.modelUnavailable);
      expect(harness.executor.requests, isEmpty);
      await harness.service.dispose();
    });

    test('an executor failure becomes a visible failed run', () async {
      final harness = build();
      harness.executor.handler = (request, cancellation) async {
        throw StateError('boom');
      };
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      await harness.service.waitForIdle();
      final run = (await harness.repository.listRuns(
        taskId: task.taskId,
      )).single;
      expect(run.status, AutomationRunStatus.failed);
      expect(run.error!.kind, AutomationRunErrorKind.internal);
      await harness.service.dispose();
    });

    test('a chat delivery without a sink is recorded, not dropped', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(
        automationDraft(delivery: const AutomationDelivery.chat('chat-7')),
      );
      final handle = await harness.service.runTaskNow(task.taskId);
      final run = await handle.done;
      expect(run.status, AutomationRunStatus.succeeded);
      expect(run.delivery?.delivered, isFalse);
      expect(run.delivery?.error, contains('недоступна'));
      await harness.service.dispose();
    });

    test('a configured delivery sink is called with the pinned task', () async {
      final deliveries = <String>[];
      final harness = build(delivery: _RecordingDelivery(deliveries));
      await harness.service.start();
      final task = await harness.service.createTask(
        automationDraft(delivery: const AutomationDelivery.chat('chat-9')),
      );
      final handle = await harness.service.runTaskNow(task.taskId);
      final run = await handle.done;
      expect(run.delivery?.delivered, isTrue);
      expect(run.delivery?.reference, 'chat-message-1');
      expect(deliveries, <String>['chat-9']);
      await harness.service.dispose();
    });

    test('result text is clipped to the configured limit', () async {
      final harness = build(
        limits: const AutomationLimits(
          run: AutomationRunLimits(maxResultCharacters: 10),
        ),
      );
      harness.executor.handler = (request, cancellation) async =>
          AutomationRunOutcome(
            status: AutomationRunStatus.succeeded,
            resultText: 'x' * 100,
          );
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      final handle = await harness.service.runTaskNow(task.taskId);
      final run = await handle.done;
      expect(run.resultText, hasLength(10));
      expect(run.resultText, endsWith('…'));
      await harness.service.dispose();
    });

    test('store failures surface as visible service errors', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      harness.repository.failWrites = AutomationError(
        kind: AutomationErrorKind.persistence,
        message: 'Диск недоступен',
      );
      final events = <AutomationServiceEvent>[];
      final subscription = harness.service.events.listen(events.add);
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      await harness.service.waitForIdle();
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AutomationServiceErrorEvent>(), isNotEmpty);
      expect(harness.repository.runs, isEmpty);
      expect(
        (await harness.repository.findTask(task.taskId))!.nextDueAt,
        task.nextDueAt,
      );
      await subscription.cancel();
      await harness.service.dispose();
    });
  });

  group('period identity', () {
    test(
      'a manual run at the due instant does not consume the period',
      () async {
        final repository = GatedAutomationRepository(
          InMemoryAutomationRepository(),
        );
        final clock = FakeAutomationClock(DateTime.utc(2026, 1, 1, 12));
        final executor = ScriptedAutomationExecutor();
        final service = AutomationService(
          tasks: repository,
          runs: repository,
          executor: executor,
          timeZones: automationTestZones(),
          clock: clock,
          ids: SequentialAutomationIdGenerator(),
        );
        await service.start();
        final task = await service.createTask(automationDraft());
        // Hold the timer tick before it reserves the task, so the manual run can
        // happen at exactly the due instant and finish first.
        repository.gate('listTasks');
        clock.advance(const Duration(minutes: 5));

        final manual = await service.runTaskNow(task.taskId);
        await manual.done;
        expect(manual.scheduledAt, DateTime.utc(2026, 1, 1, 12, 5));

        repository.release('listTasks');
        await service.tick();
        await service.waitForIdle();

        final runs = await repository.listRuns(taskId: task.taskId);
        expect(runs, hasLength(2));
        final manualRuns = runs
            .where((run) => run.trigger == AutomationRunTrigger.manual)
            .toList();
        final scheduledRuns = runs
            .where((run) => run.trigger == AutomationRunTrigger.scheduled)
            .toList();
        expect(manualRuns, hasLength(1));
        expect(scheduledRuns, hasLength(1));
        expect(manualRuns.single.scheduledAt, DateTime.utc(2026, 1, 1, 12, 5));
        expect(
          scheduledRuns.single.scheduledAt,
          DateTime.utc(2026, 1, 1, 12, 5),
        );
        expect(manualRuns.single.runId, isNot(scheduledRuns.single.runId));
        expect(executor.requests, hasLength(2));
        final stored = await repository.findTask(task.taskId);
        expect(stored!.nextDueAt, DateTime.utc(2026, 1, 1, 12, 10));
        await service.dispose();
      },
    );

    test('two manual runs at the same instant stay distinct', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());

      final first = await harness.service.runTaskNow(task.taskId);
      await first.done;
      final second = await harness.service.runTaskNow(task.taskId);
      await second.done;

      expect(first.runId, isNot(second.runId));
      expect(first.scheduledAt, second.scheduledAt);
      final runs = await harness.repository.listRuns(taskId: task.taskId);
      expect(runs, hasLength(2));
      expect(
        runs.every((run) => run.trigger == AutomationRunTrigger.manual),
        isTrue,
      );
      expect(harness.executor.requests, hasLength(2));
      // The plan never moved.
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.nextDueAt, DateTime.utc(2026, 1, 1, 12, 5));
      await harness.service.dispose();
    });
  });

  group('privilege boundaries', () {
    test('a scheduled origin cannot create tasks or start runs', () async {
      final harness = build();
      await harness.service.start();
      await expectLater(
        harness.service.createTask(
          automationDraft(),
          origin: AutomationCallOrigin.scheduledRun,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.denied,
          ),
        ),
      );
      final task = await harness.service.createTask(automationDraft());
      await expectLater(
        harness.service.runTaskNow(
          task.taskId,
          origin: AutomationCallOrigin.scheduledRun,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.denied,
          ),
        ),
      );
      await harness.service.dispose();
    });

    test(
      'an agent tool cannot start another task during a scheduled run',
      () async {
        final gate = Completer<void>();
        final harness = build();
        harness.executor.handler = (request, cancellation) async {
          await gate.future;
          return AutomationRunOutcome(
            status: AutomationRunStatus.succeeded,
            resultText: 'ok',
          );
        };
        await harness.service.start();
        final firstTask = await harness.service.createTask(automationDraft());
        final otherTask = await harness.service.createTask(
          automationDraft(
            name: 'Другая задача',
            schedule: AutomationSchedule.oneShot(
              DateTime.utc(2026, 1, 1, 12, 30),
            ),
          ),
        );
        harness.clock.advance(const Duration(minutes: 5));
        await harness.service.tick();
        expect(harness.service.isScheduledRunActive, isTrue);
        await expectLater(
          harness.service.runTaskNow(
            otherTask.taskId,
            origin: AutomationCallOrigin.agentTool,
          ),
          throwsA(
            isA<AutomationException>().having(
              (error) => error.error.kind,
              'kind',
              AutomationErrorKind.denied,
            ),
          ),
        );
        gate.complete();
        await harness.service.waitForIdle();
        // After the scheduled run settled the tool path is available again.
        harness.clock.advance(const Duration(minutes: 1));
        final handle = await harness.service.runTaskNow(
          otherTask.taskId,
          origin: AutomationCallOrigin.agentTool,
        );
        await handle.done;
        expect(firstTask.taskId, isNot(otherTask.taskId));
        await harness.service.dispose();
      },
    );
  });

  group('events', () {
    test('task and run changes are emitted', () async {
      final harness = build();
      final events = <AutomationServiceEvent>[];
      final subscription = harness.service.events.listen(events.add);
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      final handle = await harness.service.runTaskNow(task.taskId);
      await handle.done;
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AutomationTaskChangedEvent>(), hasLength(1));
      final runEvents = events
          .whereType<AutomationRunChangedEvent>()
          .map((event) => event.run.status)
          .toList();
      expect(runEvents.first, AutomationRunStatus.running);
      expect(runEvents, contains(AutomationRunStatus.succeeded));
      await subscription.cancel();
      await harness.service.dispose();
    });
  });
}

final class _RecordingDelivery implements AutomationResultDelivery {
  _RecordingDelivery(this.deliveries);

  final List<String> deliveries;

  @override
  Future<AutomationDeliveryResult?> deliver({
    required AutomationDelivery target,
    required AutomationRun run,
  }) async {
    deliveries.add(target.chatId!);
    return const AutomationDeliveryResult(
      delivered: true,
      reference: 'chat-message-1',
    );
  }
}

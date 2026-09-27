import 'dart:async';

import 'package:domovoy/core/automation/automation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

void main() {
  ({
    AutomationService service,
    InMemoryAutomationRepository repository,
    FakeAutomationClock clock,
    ScriptedAutomationExecutor executor,
  })
  build({
    AutomationLimits limits = const AutomationLimits(),
    AutomationResultDelivery? delivery,
  }) {
    final repository = InMemoryAutomationRepository();
    final clock = FakeAutomationClock(DateTime.utc(2026, 1, 1, 12));
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

  group('updateTask', () {
    test('edits an active task and recomputes the next occurrence', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());
      expect(task.nextDueAt, DateTime.utc(2026, 1, 1, 12, 5));

      final updated = await harness.service.updateTask(
        task.taskId,
        automationDraft(
          name: 'Новое имя',
          prompt: 'Новый промпт.',
          schedule: AutomationSchedule.cron(
            expression: '0 9 * * *',
            timeZoneId: 'Europe/Moscow',
          ),
          allowedToolIds: const <String>['search'],
        ),
      );
      expect(updated.revision, task.revision + 1);
      expect(updated.name, 'Новое имя');
      expect(updated.prompt, 'Новый промпт.');
      expect(updated.allowedToolIds, <String>['search']);
      expect(updated.state, AutomationTaskState.active);
      // 09:00 Moscow on 2026-01-02 is 06:00Z.
      expect(updated.nextDueAt, DateTime.utc(2026, 1, 2, 6));
      expect(harness.clock.activeTimerCount, 1);

      final preview = harness.service.previewOccurrences(updated.schedule);
      expect(preview.first, DateTime.utc(2026, 1, 2, 6));
      expect(preview, hasLength(3));

      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.revision, task.revision + 1);
      expect(stored.prompt, 'Новый промпт.');
      await harness.service.dispose();
    });

    test('rejects a stale revision and leaves the task untouched', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(automationDraft());

      await expectLater(
        harness.service.updateTask(
          task.taskId,
          automationDraft(name: 'Гонка'),
          expectedRevision: task.revision + 5,
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.revisionMismatch,
          ),
        ),
      );
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.name, task.name);
      expect(stored.revision, task.revision);
      await harness.service.dispose();
    });

    test(
      'a paused task stays paused and arms the new schedule on resume',
      () async {
        final harness = build();
        await harness.service.start();
        final task = await harness.service.createTask(automationDraft());
        await harness.service.setPaused(task.taskId, true);

        final updated = await harness.service.updateTask(
          task.taskId,
          automationDraft(
            schedule: AutomationSchedule.cron(
              expression: '0 9 * * *',
              timeZoneId: 'Europe/Moscow',
            ),
          ),
        );
        expect(updated.state, AutomationTaskState.paused);
        expect(updated.nextDueAt, isNull);

        final resumed = await harness.service.setPaused(task.taskId, false);
        expect(resumed.state, AutomationTaskState.active);
        expect(resumed.nextDueAt, DateTime.utc(2026, 1, 2, 6));
        await harness.service.dispose();
      },
    );

    test('a proposal stays a proposal with a fresh preview', () async {
      final harness = build();
      await harness.service.start();
      final proposed = await harness.service.createTask(
        automationDraft(),
        origin: AutomationCallOrigin.agentTool,
      );
      expect(proposed.state, AutomationTaskState.proposed);

      final updated = await harness.service.updateTask(
        proposed.taskId,
        automationDraft(
          schedule: AutomationSchedule.cron(
            expression: '0 9 * * *',
            timeZoneId: 'Europe/Moscow',
          ),
        ),
      );
      expect(updated.state, AutomationTaskState.proposed);
      expect(updated.origin, AutomationTaskOrigin.agent);
      expect(updated.nextDueAt, DateTime.utc(2026, 1, 2, 6));
      await expectLater(
        harness.service.runTaskNow(proposed.taskId),
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

    test('a completed task stays completed after an edit', () async {
      final harness = build();
      await harness.service.start();
      final task = await harness.service.createTask(
        automationDraft(
          schedule: AutomationSchedule.oneShot(DateTime.utc(2026, 1, 1, 12, 5)),
        ),
      );
      harness.clock.advance(const Duration(minutes: 5));
      await harness.service.tick();
      await harness.service.waitForIdle();
      final completed = await harness.repository.findTask(task.taskId);
      expect(completed!.state, AutomationTaskState.completed);

      final updated = await harness.service.updateTask(
        task.taskId,
        automationDraft(
          schedule: AutomationSchedule.cron(
            expression: '0 9 * * *',
            timeZoneId: 'Europe/Moscow',
          ),
        ),
      );
      expect(updated.state, AutomationTaskState.completed);
      expect(updated.nextDueAt, isNull);
      await harness.service.dispose();
    });

    test('validates schedule, zone and limits before saving', () async {
      final harness = build(
        limits: const AutomationLimits(maxPromptCharacters: 32),
      );
      await harness.service.start();
      final task = await harness.service.createTask(
        automationDraft(prompt: 'Короткий промпт.'),
      );

      await expectLater(
        harness.service.updateTask(
          task.taskId,
          automationDraft(
            prompt: 'Короткий промпт.',
            schedule: AutomationSchedule.cron(
              expression: '0 0 30 2 *',
              timeZoneId: 'UTC',
            ),
          ),
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.invalidSchedule,
          ),
        ),
      );
      await expectLater(
        harness.service.updateTask(
          task.taskId,
          automationDraft(
            prompt: 'Короткий промпт.',
            schedule: AutomationSchedule.cron(
              expression: '*/5 * * * *',
              timeZoneId: 'Mars/Olympus',
            ),
          ),
        ),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.invalidSchedule,
          ),
        ),
      );
      await expectLater(
        harness.service.updateTask(
          task.taskId,
          automationDraft(prompt: 'x' * 64),
        ),
        throwsA(isA<AutomationException>()),
      );
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.prompt, 'Короткий промпт.');
      expect(stored.revision, task.revision);
      await harness.service.dispose();
    });

    test('an in-flight run keeps its starting snapshot and delivery', () async {
      final gate = Completer<void>();
      final deliveries = <String>[];
      final harness = build(delivery: _ChatDelivery(deliveries));
      harness.executor.handler = (request, cancellation) async {
        await gate.future;
        return AutomationRunOutcome(
          status: AutomationRunStatus.succeeded,
          resultText: 'Итог старого запуска.',
        );
      };
      await harness.service.start();
      final task = await harness.service.createTask(
        automationDraft(
          prompt: 'Старый промпт.',
          delivery: const AutomationDelivery.chat('chat-A'),
        ),
      );
      final handle = await harness.service.runTaskNow(task.taskId);
      await Future<void>.delayed(Duration.zero);
      expect(harness.executor.requests, hasLength(1));

      // The task is edited while its run is executing.
      final updated = await harness.service.updateTask(
        task.taskId,
        automationDraft(
          prompt: 'Новый промпт.',
          modelProvider: 'deepseek',
          modelId: 'deepseek-v4-pro',
          allowedToolIds: const <String>['search'],
          delivery: const AutomationDelivery.chat('chat-B'),
          schedule: AutomationSchedule.cron(
            expression: '0 9 * * *',
            timeZoneId: 'Europe/Moscow',
          ),
        ),
      );
      expect(updated.prompt, 'Новый промпт.');
      expect(updated.delivery.chatId, 'chat-B');
      expect(updated.revision, task.revision + 1);

      gate.complete();
      final run = await handle.done;
      expect(run.status, AutomationRunStatus.succeeded);
      // The executor worked from the snapshot taken at start.
      final snapshot = harness.executor.requests.single.task;
      expect(snapshot.prompt, 'Старый промпт.');
      expect(snapshot.model, task.model);
      expect(snapshot.allowedToolIds, isEmpty);
      expect(snapshot.delivery.chatId, 'chat-A');
      // The result is routed by the pinned target, not the edited task.
      expect(run.deliveryTarget?.chatId, 'chat-A');
      expect(deliveries, <String>['chat-A']);
      // The stored task keeps the new values for later runs.
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.delivery.chatId, 'chat-B');
      await harness.service.dispose();
    });
  });
}

final class _ChatDelivery implements AutomationResultDelivery {
  _ChatDelivery(this.deliveries);

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

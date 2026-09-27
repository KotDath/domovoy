import 'package:domovoy/core/automation/automation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  AutomationTask sampleTask({
    AutomationTaskState state = AutomationTaskState.active,
    DateTime? nextDueAt,
    int revision = 0,
    AutomationDelivery delivery = const AutomationDelivery.tasks(),
    List<String> allowedToolIds = const <String>['mcp_arxiv__search_papers'],
  }) {
    return AutomationTask(
      taskId: 'atm_00000000000000000000000000000001',
      name: 'Сводка arXiv',
      prompt: 'Собери свежие статьи.',
      schedule: AutomationSchedule.cron(
        expression: '*/5 * * * *',
        timeZoneId: 'Europe/Moscow',
      ),
      model: automationModel(),
      allowedToolIds: allowedToolIds,
      delivery: delivery,
      state: state,
      origin: AutomationTaskOrigin.human,
      nextDueAt: state == AutomationTaskState.paused
          ? null
          : (nextDueAt ?? DateTime.utc(2026, 1, 1, 12, 5)),
      revision: revision,
      createdAt: now,
      updatedAt: now,
    );
  }

  group('task model', () {
    test('round-trips through JSON', () {
      final task = sampleTask(
        revision: 3,
        delivery: const AutomationDelivery.chat('chat-42'),
      );
      final decoded = AutomationTask.fromJson(task.toJson());
      expect(decoded.taskId, task.taskId);
      expect(decoded.name, task.name);
      expect(decoded.prompt, task.prompt);
      expect(decoded.schedule, task.schedule);
      expect(decoded.model, task.model);
      expect(decoded.allowedToolIds, task.allowedToolIds);
      expect(decoded.delivery.kind, AutomationDeliveryKind.chat);
      expect(decoded.delivery.chatId, 'chat-42');
      expect(decoded.state, AutomationTaskState.active);
      expect(decoded.origin, AutomationTaskOrigin.human);
      expect(decoded.nextDueAt, task.nextDueAt);
      expect(decoded.revision, 3);
      expect(decoded.createdAt, task.createdAt);
    });

    test('requires nextDueAt only for scheduled and proposed states', () {
      expect(
        () => AutomationTask(
          taskId: 'atm_00000000000000000000000000000001',
          name: 'Активная',
          prompt: 'x',
          schedule: AutomationSchedule.oneShot(DateTime.utc(2026, 1, 2)),
          model: automationModel(),
          state: AutomationTaskState.active,
          origin: AutomationTaskOrigin.human,
          nextDueAt: null,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => AutomationTask(
          taskId: 'atm_00000000000000000000000000000001',
          name: 'Пауза',
          prompt: 'x',
          schedule: AutomationSchedule.oneShot(DateTime.utc(2026, 1, 2)),
          model: automationModel(),
          state: AutomationTaskState.paused,
          origin: AutomationTaskOrigin.human,
          nextDueAt: DateTime.utc(2026, 1, 2),
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => sampleTask(state: AutomationTaskState.paused),
        returnsNormally,
      );
      expect(
        () => sampleTask(
          state: AutomationTaskState.proposed,
          nextDueAt: DateTime.utc(2026, 1, 1, 12, 5),
        ),
        returnsNormally,
      );
    });

    test('copyWith keeps identity and revision unless asked', () {
      final task = sampleTask(revision: 2);
      final paused = task.nextRevision(
        state: AutomationTaskState.paused,
        nextDueAt: null,
        now: DateTime.utc(2026, 1, 1, 13),
      );
      expect(paused.taskId, task.taskId);
      expect(paused.revision, 3);
      expect(paused.state, AutomationTaskState.paused);
      expect(paused.nextDueAt, isNull);
      expect(paused.updatedAt, DateTime.utc(2026, 1, 1, 13));
      expect(paused.createdAt, task.createdAt);
      expect(paused.policyId, 'scheduled-task-${task.taskId.value}');
    });

    test('rejects unknown schema versions and bad tool ids', () {
      final json = sampleTask().toJson();
      expect(
        () => AutomationTask.fromJson(<String, Object?>{
          ...json,
          'schemaVersion': 2,
        }),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => AutomationTask.fromJson(<String, Object?>{
          ...json,
          'allowedToolIds': <Object?>['ok', ''],
        }),
        throwsA(isA<AutomationException>()),
      );
    });

    test('normalizes allowed tool ids and bounds the list', () {
      final task = sampleTask(allowedToolIds: const <String>[' a ', 'a', 'b']);
      expect(task.allowedToolIds, <String>['a', 'b']);
      expect(
        () => sampleTask(
          allowedToolIds: List<String>.generate(60, (index) => 'tool$index'),
        ),
        throwsA(isA<AutomationException>()),
      );
    });

    test('delivery round-trips both kinds', () {
      expect(
        AutomationDelivery.fromJson(const AutomationDelivery.tasks().toJson()),
        const AutomationDelivery.tasks(),
      );
      expect(
        AutomationDelivery.fromJson(
          const AutomationDelivery.chat('chat-1').toJson(),
        ).chatId,
        'chat-1',
      );
      expect(
        () => AutomationDelivery.fromJson(<String, Object?>{'kind': 'chat'}),
        throwsA(isA<AutomationException>()),
      );
    });
  });

  group('run model', () {
    AutomationRun runningRun() => AutomationRun(
      runId: 'ran_00000000000000000000000000000001',
      taskId: 'atm_00000000000000000000000000000001',
      taskRevision: 4,
      trigger: AutomationRunTrigger.scheduled,
      status: AutomationRunStatus.running,
      scheduledAt: DateTime.utc(2026, 1, 1, 12, 5),
      startedAt: DateTime.utc(2026, 1, 1, 12, 5, 1),
      model: automationModel(),
      allowedToolIds: const <String>['mcp_arxiv__search_papers'],
      deliveryTarget: const AutomationDelivery.chat('chat-1'),
    );

    test('round-trips a terminal run with trace and delivery', () {
      final run = runningRun().copyWith(
        status: AutomationRunStatus.succeeded,
        finishedAt: DateTime.utc(2026, 1, 1, 12, 6),
        resultText: 'Готово',
        modelTurns: 2,
        toolCalls: 1,
        trace: <AutomationToolTraceEntry>[
          AutomationToolTraceEntry(
            name: 'mcp_arxiv__search_papers',
            status: AutomationToolTraceStatus.succeeded,
          ),
        ],
        delivery: const AutomationDeliveryResult(
          delivered: true,
          reference: 'domovoy://automation/run/ran_1',
        ),
        revision: 1,
      );
      final decoded = AutomationRun.fromJson(run.toJson());
      expect(decoded.runId, run.runId);
      expect(decoded.status, AutomationRunStatus.succeeded);
      expect(decoded.trigger, AutomationRunTrigger.scheduled);
      expect(decoded.resultText, 'Готово');
      expect(decoded.modelTurns, 2);
      expect(decoded.toolCalls, 1);
      expect(decoded.trace.single.name, 'mcp_arxiv__search_papers');
      expect(decoded.delivery?.delivered, isTrue);
      expect(decoded.deliveryTarget?.chatId, 'chat-1');
      expect(decoded.revision, 1);
      expect(
        decoded.scheduleKeyValue,
        'atm_00000000000000000000000000000001@2026-01-01T12:05:00.000Z',
      );
    });

    test('round-trips the pinned delivery target', () {
      final run = runningRun();
      final decoded = AutomationRun.fromJson(run.toJson());
      expect(decoded.deliveryTarget?.kind, AutomationDeliveryKind.chat);
      expect(decoded.deliveryTarget?.chatId, 'chat-1');
      // A legacy record without the field stays readable.
      final legacy = Map<String, Object?>.from(run.toJson())
        ..remove('deliveryTarget');
      expect(AutomationRun.fromJson(legacy).deliveryTarget, isNull);
    });

    test('rejects inconsistent running and terminal states', () {
      expect(
        () => AutomationRun(
          runId: 'ran_00000000000000000000000000000002',
          taskId: 'atm_00000000000000000000000000000001',
          taskRevision: 0,
          trigger: AutomationRunTrigger.manual,
          status: AutomationRunStatus.running,
          scheduledAt: now,
          model: automationModel(),
        ),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => AutomationRun(
          runId: 'ran_00000000000000000000000000000003',
          taskId: 'atm_00000000000000000000000000000001',
          taskRevision: 0,
          trigger: AutomationRunTrigger.manual,
          status: AutomationRunStatus.failed,
          scheduledAt: now,
          model: automationModel(),
        ),
        throwsA(isA<AutomationException>()),
      );
    });

    test('sanitizes secret-looking error text', () {
      final error = AutomationRunError(
        kind: AutomationRunErrorKind.provider,
        message: 'Authorization: Bearer sk-abcdef123456',
      );
      expect(error.message, isNot(contains('sk-abcdef123456')));
    });

    test('bounds the trace through limits', () {
      final run = runningRun().copyWith(
        status: AutomationRunStatus.failed,
        finishedAt: now,
        error: AutomationRunError(
          kind: AutomationRunErrorKind.agent,
          message: 'Ошибка',
        ),
        trace: List<AutomationToolTraceEntry>.generate(
          5,
          (index) => AutomationToolTraceEntry(
            name: 'tool$index',
            status: AutomationToolTraceStatus.failed,
          ),
        ),
        revision: 1,
      );
      const limits = AutomationLimits(maxTraceEntries: 3);
      expect(
        () => run.validateAgainst(limits),
        throwsA(isA<AutomationException>()),
      );
    });
  });

  group('limits', () {
    test('rejects zero and negative values', () {
      expect(
        () => const AutomationLimits(maxTasks: 0).validate(),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => const AutomationRunLimits(maxDuration: Duration.zero).validate(),
        throwsA(isA<AutomationException>()),
      );
    });

    test('runtime budget is tighter than the hard deadline', () {
      const limits = AutomationRunLimits(maxDuration: Duration(minutes: 10));
      expect(limits.runtimeBudget, lessThan(limits.maxDuration));
      const short = AutomationRunLimits(maxDuration: Duration(seconds: 20));
      expect(short.runtimeBudget, short.maxDuration);
    });

    test('stream limit must fit a record plus the envelope headroom', () {
      expect(
        () => const AutomationLimits(
          maxTaskBytes: 1024,
          maxStreamBytes: 1024,
        ).validate(),
        throwsA(isA<AutomationException>()),
      );
    });
  });
}

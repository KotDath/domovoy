import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/features/tasks/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/automation_fakes.dart';

void main() {
  late InMemoryAutomationRepository repository;
  late FakeAutomationClock clock;
  late AutomationService service;
  late TaskEditorController editor;

  setUp(() async {
    repository = InMemoryAutomationRepository();
    clock = FakeAutomationClock(DateTime.utc(2026, 1, 1, 12));
    service = AutomationService(
      tasks: repository,
      runs: repository,
      executor: ScriptedAutomationExecutor(),
      timeZones: automationTestZones(),
      clock: clock,
      ids: SequentialAutomationIdGenerator(),
    );
    await service.start();
    editor = TaskEditorController(service: service);
  });

  tearDown(() async {
    editor.dispose();
    await service.dispose();
  });

  test('cron preview and missing model/tool validation before save', () async {
    editor.setName('Подборка');
    editor.setPrompt('Собери статьи и сводку.');
    editor.setCronExpression('*/5 * * * *');
    editor.setTimeZone('Europe/Moscow');
    expect(editor.state.occurrences, hasLength(3));
    expect(editor.state.occurrences.first, DateTime.utc(2026, 1, 1, 12, 5));
    expect((await editor.save()).isSuccess, isFalse);
    expect(editor.state.errors, contains(TaskEditorField.model));
    expect(editor.state.errors, contains(TaskEditorField.tools));
    expect(repository.tasks, isEmpty);

    editor.setModel(automationModel());
    editor.toggleTool('mcp_arxiv_search_papers', true);
    expect((await editor.save()).isSuccess, isTrue);
    expect(repository.tasks.single.schedule, isA<CronSchedule>());
  });

  test('invalid cron, unknown zone and past one-shot never save', () async {
    editor.setCronExpression('bad cron');
    expect(editor.validate(), contains(TaskEditorField.schedule));
    editor.setCronExpression('*/5 * * * *');
    editor.setTimeZone('Mars/Olympus');
    expect(editor.validate(), contains(TaskEditorField.schedule));
    editor.setTimeZone('UTC');
    editor.setOneShotLocal(DateTime(2020, 1, 1));
    expect(editor.validate(), contains(TaskEditorField.schedule));
    expect(repository.tasks, isEmpty);
  });

  test('pause and reopen show durable status, run and trace', () async {
    (service.executor as ScriptedAutomationExecutor).handler =
        (request, cancellation) async => AutomationRunOutcome(
          status: AutomationRunStatus.succeeded,
          resultText: 'Сводка задачи готова.',
          trace: [
            AutomationToolTraceEntry(
              name: 'arxiv.search_papers',
              status: AutomationToolTraceStatus.succeeded,
              detail: '1 статья',
            ),
          ],
          toolCalls: 1,
        );
    final task = await service.createTask(
      automationDraft(allowedToolIds: ['mcp_arxiv_search_papers']),
    );
    final tasks = TasksController(service: service);
    await tasks.initialize();
    expect(tasks.state.selectedTask?.taskId, task.taskId);
    expect((await tasks.setPaused(task.taskId, true)).isSuccess, isTrue);
    expect(tasks.state.selectedTask?.state, AutomationTaskState.paused);
    await tasks.setPaused(task.taskId, false);
    final handle = await service.runTaskNow(task.taskId);
    await handle.done;
    await tasks.refresh();
    expect(tasks.state.lastRun?.status, AutomationRunStatus.succeeded);
    tasks.dispose();
    final reopened = TasksController(service: service);
    await reopened.initialize();
    expect(reopened.state.runs, hasLength(1));
    expect(reopened.state.lastRun?.resultText, contains('Сводка задачи'));
    expect(reopened.state.lastRun?.trace.single.name, 'arxiv.search_papers');
    reopened.dispose();
  });
}

import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/features/tasks/tasks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

void main() {
  testWidgets('phone editor shows cron preview and validation errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = InMemoryAutomationRepository();
    final service = AutomationService(
      tasks: repository,
      runs: repository,
      executor: ScriptedAutomationExecutor(),
      timeZones: automationTestZones(),
      clock: FakeAutomationClock(DateTime.utc(2026, 1, 1, 12)),
      ids: SequentialAutomationIdGenerator(),
    );
    await service.start();
    final editor = TaskEditorController(service: service);
    await tester.pumpWidget(
      MaterialApp(home: TaskEditorPage(controller: editor)),
    );
    expect(find.textContaining('*/5 * * * *'), findsWidgets);
    expect(editor.state.occurrences, hasLength(3));
    await tester.scrollUntilVisible(
      find.text('Сохранить задачу'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Сохранить задачу'));
    await tester.pump();
    expect(find.textContaining('Выберите модель'), findsWidgets);
    expect(
      find.textContaining('Выберите хотя бы один инструмент'),
      findsWidgets,
    );
    expect(repository.tasks, isEmpty);
    editor.dispose();
    await service.dispose();
  });

  testWidgets('desktop task detail hides invalid retry and confirms delete', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = InMemoryAutomationRepository();
    final service = AutomationService(
      tasks: repository,
      runs: repository,
      executor: ScriptedAutomationExecutor(),
      timeZones: automationTestZones(),
      clock: FakeAutomationClock(DateTime.utc(2026, 1, 1, 12)),
      ids: SequentialAutomationIdGenerator(),
    );
    await service.start();
    final task = await service.createTask(
      automationDraft(delivery: const AutomationDelivery.chat('chat-one')),
    );
    await repository.appendRun(
      AutomationRun(
        runId: 'ran_0000000000000009',
        taskId: task.taskId.value,
        taskRevision: task.revision,
        trigger: AutomationRunTrigger.manual,
        status: AutomationRunStatus.skipped,
        scheduledAt: DateTime.utc(2026, 1, 1, 12),
        finishedAt: DateTime.utc(2026, 1, 1, 12),
        model: automationModel(),
        deliveryTarget: const AutomationDelivery.chat('chat-one'),
      ),
      expectedRevision: 0,
    );
    final controller = TasksController(service: service);
    final editor = TaskEditorController(service: service);
    await tester.pumpWidget(
      MaterialApp(
        home: TasksPage(controller: controller, editor: editor),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Повторить'), findsNothing);
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить задачу?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();
    expect(await service.listTasks(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    editor.dispose();
    await service.dispose();
  });
}

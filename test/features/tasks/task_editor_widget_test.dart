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
}

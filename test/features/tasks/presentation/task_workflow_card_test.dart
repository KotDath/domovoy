import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/tasks/tasks.dart';
import 'package:domovoy/features/tasks/application/tasks.dart';
import 'package:domovoy/features/tasks/presentation/task_workflow_card.dart';
import 'package:domovoy/infrastructure/tasks/tasks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_jsonl_storage.dart';
import '../../../support/task_gateway.dart';

void main() {
  testWidgets('shows plan gate and diagnostic rejection without mutation', (
    tester,
  ) async {
    final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
    final controller = TaskWorkflowController(
      repository: store,
      invariantRepository: store,
      gateway: FakeTaskAgentGateway(),
      clock: FakeAgentClock(startMicros: 1),
      ids: AgentIdFactory(prefix: 'card-task'),
    );
    await controller.start(sessionId: 'chat-1', goal: 'Проверить переходы');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TaskWorkflowCard(controller: controller),
          ),
        ),
      ),
    );

    expect(find.text('Задача · планирование'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-approve')), findsOneWidget);
    expect(find.textContaining('утверждение плана'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('task-diagnose-execution')));
    await tester.pump();

    expect(find.textContaining('PLAN_APPROVAL_REQUIRED'), findsOneWidget);
    expect(controller.state.snapshot?.phase, TaskPhase.planning);
    expect(controller.state.snapshot?.planApproved, isFalse);
  });

  testWidgets('edits task invariants outside the conversation', (tester) async {
    final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
    final controller = TaskWorkflowController(
      repository: store,
      invariantRepository: store,
      gateway: FakeTaskAgentGateway(),
    );
    await controller.start(sessionId: 'chat-1', goal: 'Собрать ответ');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TaskWorkflowCard(controller: controller),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('task-invariants')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('task-invariant-description')),
      'Только Flutter',
    );
    await tester.enterText(
      find.byKey(const ValueKey('task-invariant-terms')),
      'React',
    );
    await tester.tap(find.byKey(const ValueKey('task-invariant-add')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('task-invariant-save')));
    await tester.pumpAndSettle();

    final rules = await controller.loadTaskRules();
    expect(rules, hasLength(1));
    expect(rules.single.terms, <String>['React']);
  });

  testWidgets('replan action accepts a revised goal', (tester) async {
    final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
    final controller = TaskWorkflowController(
      repository: store,
      invariantRepository: store,
      gateway: FakeTaskAgentGateway(),
    );
    await controller.start(sessionId: 'chat-1', goal: 'Первая цель');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TaskWorkflowCard(controller: controller),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('task-replan')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('task-replan-goal')),
      'Уточнённая цель без React',
    );
    await tester.tap(find.byKey(const ValueKey('task-replan-submit')));
    await tester.pumpAndSettle();

    expect(controller.state.snapshot?.goal, 'Уточнённая цель без React');
    expect(controller.state.snapshot?.planApproved, isFalse);
  });

  testWidgets('shows the verified final result when the task is done', (
    tester,
  ) async {
    final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
    final controller = TaskWorkflowController(
      repository: store,
      invariantRepository: store,
      gateway: FakeTaskAgentGateway(),
      ids: AgentIdFactory(prefix: 'card-task'),
    );
    addTearDown(controller.dispose);
    await controller.start(sessionId: 'chat-1', goal: 'Собрать ответ');
    await controller.approvePlan();
    await controller.whenIdle;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TaskWorkflowCard(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Задача · готово'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-final-output')), findsOneWidget);
    expect(find.text('Готовый ответ'), findsOneWidget);
  });
}

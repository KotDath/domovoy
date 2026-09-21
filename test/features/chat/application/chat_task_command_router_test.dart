import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/features/chat/application/chat_task_command_router.dart';
import 'package:domovoy/features/chat/application/chat_workspace_state.dart';
import 'package:domovoy/features/tasks/application/tasks.dart';
import 'package:domovoy/infrastructure/tasks/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_jsonl_storage.dart';
import '../../../support/task_gateway.dart';

void main() {
  test(
    'routes task commands outside chat and captures the next goal',
    () async {
      final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
      final tasks = TaskWorkflowController(
        repository: store,
        invariantRepository: store,
        gateway: FakeTaskAgentGateway(),
        clock: FakeAgentClock(startMicros: 1),
        ids: AgentIdFactory(prefix: 'router-task'),
      );
      final fallbackInputs = <String>[];
      final router = ChatTaskCommandRouter(
        tasks: tasks,
        fallback: (input) async {
          fallbackInputs.add(input);
          return const ChatCommandResult.succeeded();
        },
      );
      addTearDown(router.dispose);
      await router.attach(sessionId: 'chat-1', projectId: 'project-1');

      expect((await router.send('/plan')).isSuccess, isTrue);
      expect(router.awaitingGoal, isTrue);
      expect(fallbackInputs, isEmpty);

      expect((await router.send('/task status')).isSuccess, isTrue);
      expect(router.awaitingGoal, isTrue);
      expect(router.notice, 'Активной задачи в этом чате нет.');

      expect((await router.send('Собери проверенный ответ')).isSuccess, isTrue);
      expect(router.awaitingGoal, isFalse);
      expect(tasks.state.snapshot?.goal, 'Собери проверенный ответ');
      expect(tasks.state.snapshot?.projectId, 'project-1');
      expect(tasks.state.snapshot?.planApproved, isFalse);
      expect(fallbackInputs, isEmpty);

      expect((await router.send('/task status')).isSuccess, isTrue);
      expect(router.notice, contains('планирование'));
      expect((await router.send('Обычное сообщение')).isSuccess, isTrue);
      expect(fallbackInputs, <String>['Обычное сообщение']);
    },
  );

  test('maps guarded task commands to a visible stable-code error', () async {
    final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
    final tasks = TaskWorkflowController(
      repository: store,
      invariantRepository: store,
      gateway: FakeTaskAgentGateway(),
    );
    final router = ChatTaskCommandRouter(
      tasks: tasks,
      fallback: (_) async => const ChatCommandResult.succeeded(),
    );
    addTearDown(router.dispose);
    await router.attach(sessionId: 'chat-1');

    final result = await router.send('/task pause');

    expect(result.status, ChatCommandStatus.failed);
    expect(result.error?.message, contains('INVALID_TRANSITION'));
    expect(router.notice, contains('INVALID_TRANSITION'));
  });

  test(
    '/plan refuses to capture another goal while a task is active',
    () async {
      final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
      final tasks = TaskWorkflowController(
        repository: store,
        invariantRepository: store,
        gateway: FakeTaskAgentGateway(),
      );
      final fallbackInputs = <String>[];
      final router = ChatTaskCommandRouter(
        tasks: tasks,
        fallback: (input) async {
          fallbackInputs.add(input);
          return const ChatCommandResult.succeeded();
        },
      );
      addTearDown(router.dispose);
      await router.attach(sessionId: 'chat-1');
      await router.send('/plan');
      await router.send('Первая цель');

      final result = await router.send('/plan');

      expect(result.status, ChatCommandStatus.failed);
      expect(result.error?.message, contains('INVALID_TRANSITION'));
      expect(router.notice, contains('INVALID_TRANSITION'));
      expect(router.awaitingGoal, isFalse);
      expect(fallbackInputs, isEmpty);
    },
  );

  test('clears only the stale plan-ready notice after approval', () async {
    final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
    final tasks = TaskWorkflowController(
      repository: store,
      invariantRepository: store,
      gateway: FakeTaskAgentGateway(),
    );
    final router = ChatTaskCommandRouter(
      tasks: tasks,
      fallback: (_) async => const ChatCommandResult.succeeded(),
    );
    addTearDown(router.dispose);
    await router.attach(sessionId: 'chat-1');
    await router.send('/plan');
    await router.send('Собрать ответ');

    expect(router.notice, 'План подготовлен для утверждения.');

    await tasks.approvePlan();

    expect(router.notice, isNull);
  });
}

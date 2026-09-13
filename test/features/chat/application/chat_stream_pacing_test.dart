import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/chat/application/chat_stream_pacing.dart';
import 'package:domovoy/features/chat/application/chat_timeline_projector.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/chat/application/chat_workspace_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';
import '../../../support/scripted_llm_provider.dart';

void main() {
  test('deltas reduce immediately while notifications coalesce', () async {
    final gate = Completer<void>();
    final provider = ScriptedLlmProvider(
      id: BuiltInLlmCatalog.deepSeek,
      wireFamily: LlmWireFamily.openaiChatCompletions,
      events: const <LlmEvent>[
        LlmReasoningDelta('a'),
        LlmReasoningDelta('b'),
        LlmTextDelta('c'),
        LlmTextDelta('d'),
      ],
      gate: gate,
    );
    final repository = InMemoryAgentSessionRepository();
    final runtime = testRuntime(provider: provider, repository: repository);
    final scheduler = _FakeScheduler();
    final controller = ChatWorkspaceController(
      runtime: runtime,
      definition: testDefinition(),
      catalog: repository,
      repository: repository,
      registry: runtime.registry,
      scheduler: scheduler,
    );
    await controller.initialize();
    await controller.createChat(id: AgentSessionId('paced'));
    final states = <ChatWorkspaceState>[];
    final subscription = controller.states.listen(states.add);

    final sending = controller.send('question');
    await _waitUntil(() => scheduler.pending == 1);
    final immediate = const ChatTimelineProjector().project(
      snapshot: controller.state.selectedSession!,
      liveRun: controller.state.liveRun,
    );
    expect(immediate.items.whereType<ChatReasoningItem>().single.text, 'ab');
    expect(immediate.items.whereType<ChatAssistantItem>().single.text, 'cd');
    final beforeTick = states.length;
    scheduler.fireNext();
    expect(states.length, beforeTick + 1);
    expect(scheduler.pending, 0);

    gate.complete();
    expect((await sending).status, ChatCommandStatus.succeeded);
    expect(controller.state.liveRun!.terminal, isA<AgentRunCompleted>());
    await subscription.cancel();
    await controller.dispose();
    await runtime.close();
  });

  test('terminal flushes trailing content and cancels pending tick', () async {
    final provider = ScriptedLlmProvider(
      id: BuiltInLlmCatalog.deepSeek,
      wireFamily: LlmWireFamily.openaiChatCompletions,
      events: const <LlmEvent>[LlmTextDelta('tail')],
    );
    final repository = InMemoryAgentSessionRepository();
    final runtime = testRuntime(provider: provider, repository: repository);
    final scheduler = _FakeScheduler();
    final controller = ChatWorkspaceController(
      runtime: runtime,
      definition: testDefinition(),
      catalog: repository,
      repository: repository,
      registry: runtime.registry,
      scheduler: scheduler,
    );
    await controller.initialize();
    await controller.createChat(id: AgentSessionId('terminal'));
    final emitted = <ChatWorkspaceState>[];
    final subscription = controller.states.listen(emitted.add);

    expect((await controller.send('question')).isSuccess, isTrue);
    expect(scheduler.pending, 0);
    final terminalState = emitted.lastWhere(
      (state) => state.liveRun?.terminal is AgentRunCompleted,
    );
    final projection = const ChatTimelineProjector().project(
      snapshot: terminalState.selectedSession!,
      liveRun: terminalState.liveRun,
    );
    expect(projection.items.whereType<ChatAssistantItem>().single.text, 'tail');

    await subscription.cancel();
    await controller.dispose();
    await runtime.close();
  });

  test('dispose cancels a pending paced notification', () async {
    final gate = Completer<void>();
    final provider = ScriptedLlmProvider(
      id: BuiltInLlmCatalog.deepSeek,
      wireFamily: LlmWireFamily.openaiChatCompletions,
      events: const <LlmEvent>[LlmTextDelta('partial')],
      gate: gate,
    );
    final repository = InMemoryAgentSessionRepository();
    final runtime = testRuntime(provider: provider, repository: repository);
    final scheduler = _FakeScheduler();
    final controller = ChatWorkspaceController(
      runtime: runtime,
      definition: testDefinition(),
      catalog: repository,
      repository: repository,
      registry: runtime.registry,
      scheduler: scheduler,
    );
    await controller.initialize();
    await controller.createChat(id: AgentSessionId('dispose'));
    final sending = controller.send('question');
    await _waitUntil(() => scheduler.pending == 1);

    await controller.dispose();
    expect(scheduler.pending, 0);
    expect((await sending).status, ChatCommandStatus.disposed);
    gate.complete();
    await runtime.close();
  });
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var index = 0; index < 100 && !condition(); index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

final class _FakeScheduler implements ChatStreamScheduler {
  final List<_FakeNotification> _notifications = <_FakeNotification>[];

  int get pending => _notifications.where((item) => !item.cancelled).length;

  @override
  ChatScheduledNotification schedule(Duration delay, void Function() callback) {
    final notification = _FakeNotification(callback);
    _notifications.add(notification);
    return notification;
  }

  void fireNext() {
    _notifications.firstWhere((item) => !item.cancelled).fire();
  }
}

final class _FakeNotification implements ChatScheduledNotification {
  _FakeNotification(this.callback);

  final void Function() callback;
  var cancelled = false;

  void fire() {
    if (cancelled) return;
    cancelled = true;
    callback();
  }

  @override
  void cancel() => cancelled = true;
}

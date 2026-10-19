import 'dart:async';
import 'dart:convert';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_agent_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/agent_harness.dart';
import '../../support/memory_jsonl_storage.dart';

void main() {
  test(
    'optional precondition keeps tools, buffers final, and rejection preserves tools/accounting without final draft in fresh replay',
    () async {
      final storage = FakeMemoryJsonlStorage();
      final sessions = JsonlAgentSessionStore(storage: storage);
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [
          toolTurn(
            name: 'read_context',
            callId: 'c',
            answer: 'Проверяю контекст',
            usage: LlmUsage(inputTokens: 1, outputTokens: 1),
          ),
          [
            const LlmReasoningDelta('WITHHELD_REASONING'),
            ...textTurn(
              'REJECTED_DRAFT',
              usage: LlmUsage(inputTokens: 10, outputTokens: 6),
            ),
          ],
        ],
      );
      final tools = AgentToolRegistry();
      tools.register(
        AgentTool(
          descriptor: LlmToolDescriptor(
            name: 'read_context',
            parameters: {'type': 'object', 'properties': {}},
          ),
          executor: ScriptedToolExecutor(
            (invocation, {required cancellation, required liveness}) async =>
                ToolExecutionResult.success({'observed': true}),
          ),
        ),
      );
      final runtime = testRuntime(
        provider: provider,
        tools: tools,
        repository: sessions,
      );
      addTearDown(runtime.close);
      final session = await runtime
          .agent(testDefinition(tools: [ToolId('read_context')]))
          .createSession(persistence: SessionPersistence.repository);
      var checks = 0;
      final events = await session
          .run(
            'question',
            options: AgentRunOptions(
              preparedContext: AgentPreparedContext(
                beforeFinalAnswer: (draft, token) async {
                  checks++;
                  expect(
                    draft.request.context.messages
                        .expand((m) => m.parts)
                        .whereType<LlmToolResultPart>(),
                    hasLength(1),
                  );
                  throwAgent(AgentErrorKind.protocol, 'precondition rejected');
                },
              ),
            ),
          )
          .events
          .toList();
      expect(checks, 1);
      expect(events.last, isA<AgentRunFailed>());
      expect(events.whereType<AgentToolFinished>().single.success, true);
      expect(events.whereType<AgentAnswerDelta>().map((e) => e.text), [
        'Проверяю контекст',
      ]);
      expect(events.whereType<AgentReasoningDelta>(), isEmpty);
      final fresh = (await JsonlAgentSessionStore(
        storage: storage,
      ).load(session.id))!;
      final text = jsonEncode(fresh.transcript.toJson());
      expect(text, contains('observed'));
      expect(text, isNot(contains('REJECTED_DRAFT')));
      expect(text, isNot(contains('WITHHELD_REASONING')));
      expect(fresh.usage.outputTokens, 7);
      expect(fresh.modelTurns, 2);
    },
  );

  test(
    'cancellation while precondition awaits never hangs or releases final, even if callback later returns',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [textTurn('WITHHELD')],
      );
      final runtime = testRuntime(provider: provider);
      addTearDown(runtime.close);
      final session = await runtime.agent(testDefinition()).createSession();
      final entered = Completer<void>();
      final release = Completer<void>();
      final run = session.run(
        'question',
        options: AgentRunOptions(
          preparedContext: AgentPreparedContext(
            beforeFinalAnswer: (draft, token) async {
              entered.complete();
              await release.future;
            },
          ),
        ),
      );
      final events = run.events.toList();
      await entered.future;
      await run.cancel().timeout(const Duration(seconds: 3));
      release.complete();
      final done = await events;
      expect(done.last, isA<AgentRunCancelled>());
      expect(done.whereType<AgentAnswerDelta>(), isEmpty);
      expect(
        session.snapshot.transcript.messages
            .expand((m) => m.parts)
            .whereType<LlmTextPart>()
            .map((p) => p.text),
        ['question'],
      );
      expect(provider.requests, hasLength(1));
    },
  );

  test(
    'without precondition ordinary streaming still exposes deltas before provider finishes',
    () async {
      final provider = _BlockedProvider();
      final runtime = testRuntime(provider: provider);
      addTearDown(runtime.close);
      final session = await runtime.agent(testDefinition()).createSession();
      final run = session.run('question');
      final emitted = Completer<void>();
      final events = <AgentRunEvent>[];
      final done = Completer<void>();
      run.events.listen((e) {
        events.add(e);
        if (e is AgentAnswerDelta && !emitted.isCompleted) emitted.complete();
      }, onDone: done.complete);
      await emitted.future;
      expect(events.whereType<AgentRunCompleted>(), isEmpty);
      provider.release.complete();
      await done.future;
      expect(events.last, isA<AgentRunCompleted>());
    },
  );
}

final class _BlockedProvider implements LlmProvider {
  final release = Completer<void>();
  @override
  ProviderId get id => BuiltInLlmCatalog.deepSeek;
  @override
  LlmWireFamily get wireFamily => LlmWireFamily.openaiChatCompletions;
  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    yield const LlmTextDelta('streamed');
    await release.future;
    yield const LlmCompleted(finishReason: LlmFinishReason.stop);
  }
}

import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

final class _PrivateContext implements AgentDynamicContextProvider {
  int calls = 0;
  @override
  Future<AgentDynamicContext?> provide(
    AgentDynamicContextRequest request,
  ) async {
    calls++;
    return AgentDynamicContext(systemPromptText: 'PRIVATE_PROFILE');
  }
}

AgentToolRegistry _tools() => AgentToolRegistry()
  ..register(
    AgentTool(
      descriptor: LlmToolDescriptor(
        name: 'lookup',
        parameters: {'type': 'object', 'properties': <String, Object?>{}},
      ),
      executor: ScriptedToolExecutor(
        (invocation, {required cancellation, required liveness}) async =>
            ToolExecutionResult.success(<String, Object?>{}),
      ),
    ),
  );

void main() {
  test(
    'observer persists exact prepared request before transport, context is ephemeral',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [textTurn('answer')],
      );
      final dynamic = _PrivateContext();
      final runtime = testRuntime(
        provider: provider,
        tools: _tools(),
        dynamicContextProvider: dynamic,
      );
      final session = await runtime
          .agent(testDefinition(tools: [ToolId('lookup')]))
          .createSession();
      final observed = <LlmRequestSnapshot>[];
      final run = session.run(
        'question',
        options: AgentRunOptions(
          preparedContext: AgentPreparedContext(
            systemPromptOverride: 'NEUTRAL',
            contribution: AgentDynamicContext(
              systemPromptText: 'EXACT_EVIDENCE',
            ),
            suppressDynamicContext: true,
            disableTools: true,
            beforeRequest: (request, _) async {
              expect(provider.requests, isEmpty);
              observed.add(request);
            },
          ),
        ),
      );
      final events = await run.events.toList();
      expect(events.last, isA<AgentRunCompleted>());
      expect(dynamic.calls, 0);
      expect(provider.requests.single.snapshot(), observed.single);
      expect(
        provider.requests.single.context.systemPrompt,
        'NEUTRAL\n\nEXACT_EVIDENCE',
      );
      expect(provider.requests.single.context.tools, isEmpty);
      expect(
        session.snapshot.transcript.messages
            .expand((m) => m.parts)
            .whereType<LlmTextPart>()
            .map((p) => p.text),
        ['question', 'answer'],
      );
      await runtime.close();
    },
  );

  test(
    'failed durable request trace and full-request budget prevent model invocation',
    () async {
      for (final failTrace in [false, true]) {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: [textTurn('unreachable')],
        );
        final runtime = testRuntime(provider: provider);
        final session = await runtime.agent(testDefinition()).createSession();
        final events = await session
            .run(
              'question',
              options: AgentRunOptions(
                preparedContext: AgentPreparedContext(
                  maxRequestBytes: failTrace ? null : 1,
                  beforeRequest: (_, _) async {
                    throw StateError('disk unavailable');
                  },
                ),
              ),
            )
            .events
            .toList();
        expect(events.last, isA<AgentRunFailed>());
        expect(provider.requests, isEmpty);
        expect(session.snapshot.transcript.messages, hasLength(1));
        await runtime.close();
      }
    },
  );

  test(
    'cancellation during durable observer discards late work before transport',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [textTurn('unreachable')],
      );
      final runtime = testRuntime(provider: provider);
      final entered = Completer<void>(), release = Completer<void>();
      final run = runtime
          .agent(testDefinition())
          .run(
            'question',
            options: AgentRunOptions(
              preparedContext: AgentPreparedContext(
                beforeRequest: (_, _) async {
                  entered.complete();
                  await release.future;
                },
              ),
            ),
          );
      final eventsFuture = run.events.toList();
      await entered.future;
      final cancel = run.cancel();
      release.complete();
      await cancel;
      expect((await eventsFuture).last, isA<AgentRunCancelled>());
      expect(provider.requests, isEmpty);
      await runtime.close();
    },
  );

  test(
    'forged tool call cannot execute or enter accepted transcript',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [toolTurn(name: 'lookup', callId: 'c1', arguments: '{}')],
      );
      final runtime = testRuntime(provider: provider, tools: _tools());
      final session = await runtime
          .agent(testDefinition(tools: [ToolId('lookup')]))
          .createSession();
      final events = await session
          .run(
            'question',
            options: AgentRunOptions(
              preparedContext: const AgentPreparedContext(disableTools: true),
            ),
          )
          .events
          .toList();
      expect(events.last, isA<AgentRunFailed>());
      expect(session.snapshot.toolAttempts, 0);
      expect(session.snapshot.transcript.messages, hasLength(1));
      await runtime.close();
    },
  );
}

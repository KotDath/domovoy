import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

final class _Gate implements AgentFinalAnswerGate {
  const _Gate(this.check);
  final Future<AgentFinalAnswerDecision> Function(AgentFinalAnswerDraft) check;
  @override
  Future<AgentFinalAnswerDecision> evaluate(
    AgentFinalAnswerDraft draft,
    CancellationToken cancellation,
  ) => check(draft);
}

LlmRequest _repair(AgentFinalAnswerDraft draft) => LlmRequest(
  model: draft.request.model,
  generation: draft.request.generation,
  context: LlmContext(
    systemPrompt: 'Repair only this answer.',
    messages: [
      LlmMessage(
        role: LlmMessageRole.user,
        parts: [LlmTextPart('isolated repair')],
      ),
    ],
  ),
);

List<String> _texts(AgentSession session) => session
    .snapshot
    .transcript
    .messages
    .expand((m) => m.parts)
    .whereType<LlmTextPart>()
    .map((p) => p.text)
    .toList();

void main() {
  test(
    'one isolated repair: only accepted replacement persists and both usages count',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [
          [
            const LlmTextDelta('FORGED_DRAFT'),
            LlmUsageUpdate(LlmUsage(inputTokens: 10, outputTokens: 4)),
            const LlmCompleted(finishReason: LlmFinishReason.length),
          ],
          textTurn(
            'VALID_JSON',
            usage: LlmUsage(inputTokens: 20, outputTokens: 6),
          ),
        ],
      );
      final repository = InMemoryAgentSessionRepository();
      final runtime = testRuntime(provider: provider, repository: repository);
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      final observed = <LlmRequestSnapshot>[];
      final events = await session
          .run(
            'question',
            options: AgentRunOptions(
              maxModelTurns: const QuotaOverride.value(2),
              finalAnswerGate: _Gate((draft) async {
                if (!draft.repairAttempt) {
                  expect(draft.text, 'FORGED_DRAFT');
                  expect(draft.finishReason, LlmFinishReason.length);
                  return AgentFinalAnswerRejected(
                    reason: 'false ID',
                    repairRequest: _repair(draft),
                  );
                }
                expect(draft.text, 'VALID_JSON');
                expect(draft.finishReason, LlmFinishReason.stop);
                return AgentFinalAnswerAccepted('Verified rendered answer');
              }),
              preparedContext: AgentPreparedContext(
                disableTools: true,
                beforeRequest: (request, _) async {
                  observed.add(request);
                },
              ),
            ),
          )
          .events
          .toList();
      expect(events.last, isA<AgentRunCompleted>());
      expect(
        (events.last as AgentRunCompleted).finishReason,
        LlmFinishReason.stop,
      );
      expect(events.whereType<AgentAnswerDelta>().map((e) => e.text), [
        'Verified rendered answer',
      ]);
      expect(events.whereType<AgentReasoningDelta>(), isEmpty);
      expect(_texts(session), ['question', 'Verified rendered answer']);
      expect(provider.requests, hasLength(2));
      expect(observed, hasLength(2));
      expect(provider.requests.last.context.messages, hasLength(1));
      expect(session.snapshot.modelTurns, 2);
      expect(session.snapshot.usage.inputTokens, 30);
      expect(session.snapshot.usage.outputTokens, 10);
      final ledger = session.snapshot.tokenAccounting.ledger;
      expect(ledger, hasLength(2));
      expect(ledger.first.entry.responseMessageId, isNull);
      expect(ledger.last.entry.responseMessageId, isNotNull);
      await session.close();
      final restored = await agent.restoreSession(session.id);
      expect(_texts(restored), ['question', 'Verified rendered answer']);
      await runtime.close();
    },
  );

  test(
    'two rejected drafts never stream or survive persisted history',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [textTurn('WRONG_ID'), textTurn('WRONG_QUOTE')],
      );
      final runtime = testRuntime(
        provider: provider,
        repository: InMemoryAgentSessionRepository(),
      );
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      final events = await session
          .run(
            'question',
            options: AgentRunOptions(
              finalAnswerGate: _Gate(
                (draft) async => AgentFinalAnswerRejected(
                  reason: 'invalid evidence',
                  repairRequest: _repair(draft),
                ),
              ),
            ),
          )
          .events
          .toList();
      expect(events.last, isA<AgentRunFailed>());
      expect(provider.requests, hasLength(2));
      expect(events.whereType<AgentAnswerDelta>(), isEmpty);
      expect(_texts(session), ['question']);
      expect(session.snapshot.tokenAccounting.ledger, hasLength(2));
      await session.close();
      expect(_texts(await agent.restoreSession(session.id)), ['question']);
      await runtime.close();
    },
  );

  test(
    'host abstention persists two messages with zero model invocations',
    () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: [textTurn('UNREACHABLE')],
      );
      final runtime = testRuntime(provider: provider);
      final session = await runtime.agent(testDefinition()).createSession();
      final events = await session
          .run(
            'unknown',
            options: AgentRunOptions(
              respondWithoutModel: AgentRespondWithoutModel(
                'Insufficient evidence; clarify the source.',
              ),
            ),
          )
          .events
          .toList();
      expect(events.last, isA<AgentRunCompleted>());
      expect(provider.requests, isEmpty);
      expect(session.snapshot.modelTurns, 0);
      expect(session.snapshot.tokenAccounting.ledger, isEmpty);
      expect(_texts(session), [
        'unknown',
        'Insufficient evidence; clarify the source.',
      ]);
      await runtime.close();
    },
  );

  test('cancellation while validating prevents late accepted draft', () async {
    final provider = QueueScriptedLlmProvider(
      id: BuiltInLlmCatalog.deepSeek,
      wireFamily: LlmWireFamily.openaiChatCompletions,
      turns: [textTurn('RAW')],
    );
    final runtime = testRuntime(provider: provider);
    final session = await runtime.agent(testDefinition()).createSession();
    final entered = Completer<void>(), release = Completer<void>();
    final run = session.run(
      'question',
      options: AgentRunOptions(
        finalAnswerGate: _Gate((draft) async {
          entered.complete();
          await release.future;
          return AgentFinalAnswerAccepted('LATE');
        }),
      ),
    );
    final events = run.events.toList();
    await entered.future;
    final cancelled = run.cancel();
    release.complete();
    await cancelled;
    expect((await events).last, isA<AgentRunCancelled>());
    expect(_texts(session), ['question']);
    await runtime.close();
  });
}

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/chat/application/chat_token_presenter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const presenter = ChatTokenPresenter();

  test(
    'presents complete dimensions, provenance, ratio, and retained bound',
    () {
      final usage = LlmUsage(
        input: LlmUsageMetric.providerReported(10),
        cacheRead: LlmUsageMetric.providerReported(20),
        cacheWrite: LlmUsageMetric.providerReported(2),
        output: LlmUsageMetric.providerReported(3),
        reasoning: LlmUsageMetric.providerReported(4),
        reportedInputTotal: LlmUsageMetric.providerReported(32),
        reportedOutputTotal: LlmUsageMetric.providerReported(7),
        reportedOverall: LlmUsageMetric.providerReported(39),
        parentSemantics: const LlmUsageParentSemantics(
          inputCacheRead: LlmUsageChildInclusion.included,
          inputCacheWrite: LlmUsageChildInclusion.included,
          outputReasoning: LlmUsageChildInclusion.included,
        ),
      );
      final responseId = AgentTranscriptMessageId('response');
      final state = AgentTokenAccountingState(
        generation: 1,
        contextRevision: 1,
        messageIds: <AgentTranscriptMessageId?>[
          AgentTranscriptMessageId('request'),
          responseId,
        ],
        legacyBaseline: LlmUsage(),
        entries: <AgentModelUsageEntry>[
          _assistantEntry(
            sequence: 1,
            attempt: 'complete',
            outcome: AgentModelInvocationOutcome.completed,
            usage: usage,
            responseId: responseId,
          ),
        ],
      );
      final accounting = const AgentTokenAccountingProjector().project(
        state: state,
        retainedContextMeasurement: AgentRetainedContextMeasurement(
          contextRevision: 1,
          estimatorId: 'test-estimator',
          estimatorVersion: 1,
          estimate: 31,
        ),
      );

      final projection = presenter.present(
        accounting: accounting,
        selectedModel: BuiltInLlmCatalog.deepSeekV4FlashModel,
      );

      final request = projection.primaryGroups.first;
      expect(_value(request, 'Ввод').display, '10');
      expect(_value(request, 'Вывод').display, '3');
      expect(_value(request, 'Рассуждение').display, '4');
      expect(_value(request, 'Чтение кэша').display, '20');
      expect(_value(request, 'Запись кэша').display, '2');
      expect(_value(request, 'Попадание в кэш').display, '62.5%');
      expect(_value(request, 'Всего').display, '39');
      expect(_value(request, 'Всего').provenanceLabel, 'сообщено провайдером');
      expect(projection.retainedContext.display, '32');
      expect(
        projection.retainedContext.provenanceLabel,
        'сообщено провайдером',
      );
      expect(projection.contextBound, 1048576);
      expect(projection.summaryLabel, contains('32 / 1048576'));
      expect(projection.supplementaryGroups, hasLength(3));
    },
  );

  test('failed latest request does not replace latest committed response', () {
    final responseId = AgentTranscriptMessageId('committed-response');
    final entries = <AgentModelUsageEntry>[
      _assistantEntry(
        sequence: 1,
        attempt: 'successful',
        outcome: AgentModelInvocationOutcome.completed,
        usage: LlmUsage(totalTokens: 8),
        responseId: responseId,
      ),
      _assistantEntry(
        sequence: 2,
        attempt: 'failed-latest',
        outcome: AgentModelInvocationOutcome.failed,
        usage: LlmUsage(),
      ),
    ];
    final state = AgentTokenAccountingState(
      generation: 1,
      contextRevision: 2,
      messageIds: <AgentTranscriptMessageId?>[
        AgentTranscriptMessageId('request'),
        responseId,
      ],
      legacyBaseline: LlmUsage(),
      entries: entries,
    );
    final accounting = const AgentTokenAccountingProjector().project(
      state: state,
      retainedContextMeasurement: AgentRetainedContextMeasurement(
        contextRevision: 2,
        estimatorId: 'test-estimator',
        estimatorVersion: 1,
        estimate: 19,
      ),
    );

    final first = presenter.present(
      accounting: accounting,
      selectedModel: BuiltInLlmCatalog.deepSeekV4FlashModel,
    );
    final second = presenter.present(
      accounting: accounting,
      selectedModel: BuiltInLlmCatalog.deepSeekV4FlashModel,
    );

    expect(first.primaryGroups[0].correlationLabel, contains('failed-latest'));
    expect(first.primaryGroups[2].correlationLabel, contains('successful'));
    expect(_value(first.primaryGroups[0], 'Всего').display, '—');
    expect(
      _value(first.primaryGroups[1], 'Всего').state,
      ChatTokenValueState.partial,
    );
    expect(_value(first.primaryGroups[1], 'Всего').display, '8+');
    expect(second.summaryLabel, first.summaryLabel);
    expect(second.primaryGroups.length, first.primaryGroups.length);
  });

  test(
    'legacy and unavailable values are labelled without fabricated zero',
    () {
      final state = AgentTokenAccountingState.legacy(
        transcriptMessageCount: 1,
        usage: LlmUsage(totalTokens: 12),
      );
      final accounting = const AgentTokenAccountingProjector().project(
        state: state,
      );

      final projection = presenter.present(
        accounting: accounting,
        selectedModel: BuiltInLlmCatalog.deepSeekV4FlashModel,
      );

      expect(projection.primaryGroups[0].note, contains('ещё не выполнялись'));
      expect(_value(projection.primaryGroups[0], 'Ввод').display, '—');
      expect(_value(projection.primaryGroups[0], 'Ввод').display, isNot('0'));
      expect(projection.primaryGroups[1].note, contains('legacy'));
      expect(_value(projection.primaryGroups[1], 'Всего').display, '12');
      expect(projection.retainedContext.display, '—');
      expect(projection.supplementaryGroups.last.values, isNotEmpty);
    },
  );
}

AgentModelUsageEntry _assistantEntry({
  required int sequence,
  required String attempt,
  required AgentModelInvocationOutcome outcome,
  required LlmUsage usage,
  AgentTranscriptMessageId? responseId,
}) => AgentModelUsageEntry.assistant(
  sequence: sequence,
  attemptId: ProviderAttemptId(attempt),
  model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
  outcome: outcome,
  usage: usage,
  contextRevision: sequence,
  runId: RunId('run-$attempt'),
  turnId: TurnId('turn-$attempt'),
  retryOrdinal: 0,
  requestMessageId: AgentTranscriptMessageId('request-$attempt'),
  responseMessageId: responseId,
);

ChatTokenValue _value(ChatTokenGroup group, String label) =>
    group.values.singleWhere((value) => value.label == label);

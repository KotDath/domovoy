import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  group('token accounting ledger', () {
    test('validates operation correlation and immutable ordering', () {
      final first = _assistantEntry(
        sequence: 1,
        attempt: 'attempt-1',
        response: 'response-1',
      );
      final compaction = _compactionEntry(sequence: 2, attempt: 'attempt-2');
      final state = AgentTokenAccountingState(
        generation: 1,
        contextRevision: 3,
        messageIds: <AgentTranscriptMessageId?>[
          AgentTranscriptMessageId('request-1'),
          AgentTranscriptMessageId('response-1'),
        ],
        legacyBaseline: LlmUsage(),
        entries: <AgentModelUsageEntry>[first, compaction],
      );

      expect(state.entries, <AgentModelUsageEntry>[first, compaction]);
      expect(() => state.entries.add(first), throwsUnsupportedError);
      expect(
        () => AgentTokenAccountingState(
          generation: 1,
          contextRevision: 3,
          messageIds: state.messageIds,
          legacyBaseline: LlmUsage(),
          entries: <AgentModelUsageEntry>[compaction, first],
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentTokenAccountingState(
          generation: 1,
          contextRevision: 3,
          messageIds: state.messageIds,
          legacyBaseline: LlmUsage(),
          entries: <AgentModelUsageEntry>[
            first,
            _compactionEntry(sequence: 2, attempt: 'attempt-1'),
          ],
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentModelUsageEntry.assistant(
          sequence: 1,
          attemptId: ProviderAttemptId('bad'),
          model: _modelA,
          outcome: AgentModelInvocationOutcome.failed,
          usage: LlmUsage(),
          contextRevision: 0,
          runId: RunId('run'),
          turnId: TurnId('turn'),
          retryOrdinal: 0,
          requestMessageId: AgentTranscriptMessageId('request'),
          responseMessageId: AgentTranscriptMessageId('response'),
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        AgentModelUsageEntry.assistant(
          sequence: 1,
          attemptId: ProviderAttemptId('completed-without-message'),
          model: _modelA,
          outcome: AgentModelInvocationOutcome.completed,
          usage: LlmUsage(),
          contextRevision: 0,
          runId: RunId('run'),
          turnId: TurnId('turn'),
          retryOrdinal: 0,
          requestMessageId: AgentTranscriptMessageId('request'),
        ).responseMessageId,
        isNull,
      );
      expect(() => ProviderAttemptId('  '), throwsA(isA<LlmException>()));
      expect(
        () => _compactionEntry(sequence: -1, attempt: 'negative-sequence'),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentModelUsageEntry.compaction(
          sequence: 1,
          attemptId: ProviderAttemptId('negative'),
          model: _modelA,
          outcome: AgentModelInvocationOutcome.completed,
          usage: LlmUsage(),
          contextRevision: 0,
          compactionOperationId: AgentCompactionOperationId('compact'),
          invocationOrdinal: -1,
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentModelUsageEntry.compaction(
          sequence: 1,
          attemptId: ProviderAttemptId('estimated'),
          model: _modelA,
          outcome: AgentModelInvocationOutcome.completed,
          usage: LlmUsage(input: LlmUsageMetric.estimated(1)),
          contextRevision: 0,
          compactionOperationId: AgentCompactionOperationId('compact'),
          invocationOrdinal: 0,
        ),
        throwsA(isA<LlmException>()),
      );

      final invalidOutcome = deepCopyJson(first.toJson())! as Map;
      invalidOutcome['outcome'] = 'invented';
      expect(
        () => AgentModelUsageEntry.fromJson(invalidOutcome),
        throwsA(isA<AgentException>()),
      );
      final missingRun = deepCopyJson(first.toJson())! as Map;
      missingRun.remove('runId');
      expect(
        () => AgentModelUsageEntry.fromJson(missingRun),
        throwsA(isA<AgentException>()),
      );
    });

    test('round-trips every stable identity and exact historical model', () {
      final state = AgentTokenAccountingState(
        generation: 4,
        contextRevision: 9,
        messageIds: <AgentTranscriptMessageId?>[
          AgentTranscriptMessageId('request-1'),
          AgentTranscriptMessageId('response-1'),
          null,
        ],
        legacyBaseline: LlmUsage(totalTokens: 2),
        entries: <AgentModelUsageEntry>[
          _assistantEntry(
            sequence: 1,
            attempt: 'attempt-1',
            response: 'response-1',
          ),
          _compactionEntry(sequence: 3, attempt: 'attempt-2', model: _modelB),
        ],
      );

      final restored = AgentTokenAccountingState.fromJson(state.toJson());
      expect(restored, state);
      expect(restored.entries.last.model, _modelB);
      expect(restored.entries.last.compactionOperationId?.value, 'compact-1');
      expect(restored.entries.first.turnId?.value, 'turn-1');
    });
  });

  group('transcript message identities', () {
    test('append snapshots are aligned, unique, and immutable', () {
      final original = AgentTranscript(
        messages: <LlmMessage>[_message(LlmMessageRole.user, 'question')],
        messageIds: <AgentTranscriptMessageId?>[
          AgentTranscriptMessageId('request-1'),
        ],
      );
      final appended = original.append(
        _message(LlmMessageRole.assistant, 'answer'),
        messageId: AgentTranscriptMessageId('response-1'),
      );

      expect(original.messages, hasLength(1));
      expect(appended.messageIds.map((id) => id?.value), <String?>[
        'request-1',
        'response-1',
      ]);
      expect(() => appended.messageIds.add(null), throwsUnsupportedError);
      expect(
        () => AgentTranscript(
          messages: appended.messages,
          messageIds: <AgentTranscriptMessageId?>[
            AgentTranscriptMessageId('same'),
            AgentTranscriptMessageId('same'),
          ],
        ),
        throwsArgumentError,
      );
    });

    test(
      'compaction drops removed ids, keeps retained ids, and adds summary id',
      () {
        final messages = <LlmMessage>[
          _message(LlmMessageRole.user, 'old question'),
          _message(LlmMessageRole.assistant, 'old answer'),
          _message(LlmMessageRole.user, 'recent question'),
          _message(LlmMessageRole.assistant, 'recent answer'),
        ];
        final request = LlmRequestSnapshot(
          model: _modelA,
          context: LlmContext(systemPrompt: 'system', messages: messages),
          generation: LlmGenerationConfig.defaults,
        );
        final context = AgentCompactionContext(
          operationId: AgentCompactionOperationId('compact'),
          sessionId: AgentSessionId('session'),
          reason: AgentCompactionReason.manual,
          selectedModel: BuiltInLlmCatalog.deepSeekV4FlashModel,
          request: request,
          protectedSeed: const <LlmMessage>[],
          generatedPrefix: const <LlmMessage>[],
          interactionGroups: partitionAgentInteractionGroups(
            messages: messages,
            startMessageIndex: 0,
          ),
          continuationEntries: const <LlmContinuationEntry>[],
          messageIds: <AgentTranscriptMessageId?>[
            AgentTranscriptMessageId('old-request'),
            AgentTranscriptMessageId('old-response'),
            AgentTranscriptMessageId('recent-request'),
            AgentTranscriptMessageId('recent-response'),
          ],
          priorState: null,
          currentEstimate: AgentContextEstimate(
            value: 40,
            estimatorId: const _MessageCountEstimator().id,
            estimatorVersion: 1,
          ),
          targetEstimate: null,
          cancellation: CancellationSource().token,
        );
        final prepared = prepareAgentCompaction(
          context: context,
          decision: AgentCompactionDecision.manual(),
          candidate: AgentCompactionCandidate(
            strategyId: 'summary',
            strategyVersion: 1,
            retainedSuffixBoundaryId:
                context.interactionGroups.last.suffixBoundaryId,
            generatedPrefix: <LlmMessage>[
              _message(LlmMessageRole.assistant, 'summary'),
            ],
            generatedPrefixMessageIds: <AgentTranscriptMessageId?>[
              AgentTranscriptMessageId('summary-1'),
            ],
          ),
          estimator: const _MessageCountEstimator(),
          updatedAtMicros: 1,
        );

        expect(prepared.messageIds.map((id) => id?.value), <String?>[
          'summary-1',
          'recent-request',
          'recent-response',
        ]);
      },
    );
  });

  group('record accounting codec', () {
    test('legacy absence becomes generation zero without attribution', () {
      final legacy = AgentSessionRecord(
        id: AgentSessionId('legacy'),
        revision: 2,
        definition: testDefinition(),
        transcript: AgentTranscript(
          messages: <LlmMessage>[_message(LlmMessageRole.user, 'legacy')],
        ),
        usage: LlmUsage(inputTokens: 4, outputTokens: 2, totalTokens: 6),
        modelTurns: 1,
        toolAttempts: 0,
        createdAtMicros: 1,
        updatedAtMicros: 2,
      );
      const codec = AgentSessionCodec();
      final encoded = codec.encode(legacy);
      final restored = codec.decode(encoded);
      final view = restored.projectTokenAccounting();

      expect(encoded, isNot(contains('tokenAccounting')));
      expect(restored.accountingGeneration, 0);
      expect(restored.tokenAccounting.entries, isEmpty);
      expect(restored.tokenAccounting.legacyBaseline, legacy.usage);
      expect(view.currentRequest, isNull);
      expect(view.latestResponse, isNull);
      expect(view.byModel, isEmpty);
      expect(view.session.overall.value, 6);
      final updated = restored.copyWith(usage: LlmUsage(totalTokens: 7));
      expect(updated.accountingGeneration, 0);
      expect(updated.tokenAccounting.legacyBaseline.totalTokens, 7);
    });

    test('new block round-trips and rejects disagreement and duplicates', () {
      final transcript = AgentTranscript(
        messages: <LlmMessage>[
          _message(LlmMessageRole.user, 'question'),
          _message(LlmMessageRole.assistant, 'answer'),
        ],
        messageIds: <AgentTranscriptMessageId?>[
          AgentTranscriptMessageId('request-1'),
          AgentTranscriptMessageId('response-1'),
        ],
      );
      final accounting = AgentTokenAccountingState(
        generation: 1,
        contextRevision: 2,
        messageIds: transcript.messageIds,
        legacyBaseline: LlmUsage(),
        entries: <AgentModelUsageEntry>[
          _assistantEntry(
            sequence: 1,
            attempt: 'attempt-1',
            response: 'response-1',
          ),
        ],
      );
      final record = AgentSessionRecord(
        id: AgentSessionId('new'),
        revision: 1,
        definition: testDefinition(),
        transcript: transcript,
        usage: accounting.compatibilityUsage,
        modelTurns: 1,
        toolAttempts: 0,
        createdAtMicros: 1,
        updatedAtMicros: 2,
        tokenAccounting: accounting,
      );
      const codec = AgentSessionCodec();
      expect(codec.decode(codec.encode(record)), record);

      final disagreement = deepCopyJson(codec.encode(record))! as Map;
      disagreement['usage'] = LlmUsage(totalTokens: 999).toJson();
      expect(() => codec.decode(disagreement), throwsA(isA<AgentException>()));

      final duplicate = deepCopyJson(codec.encode(record))! as Map;
      final block = duplicate['tokenAccounting']! as Map;
      final entries = block['entries']! as List;
      entries.add(deepCopyJson(entries.single));
      expect(() => codec.decode(duplicate), throwsA(isA<AgentException>()));

      final misaligned = deepCopyJson(codec.encode(record))! as Map;
      final misalignedBlock = misaligned['tokenAccounting']! as Map;
      (misalignedBlock['messageIds']! as List).removeLast();
      expect(() => codec.decode(misaligned), throwsA(isA<AgentException>()));

      final malformedModel = deepCopyJson(codec.encode(record))! as Map;
      final malformedEntry =
          ((malformedModel['tokenAccounting']! as Map)['entries']! as List)
                  .single
              as Map;
      final model = malformedEntry['model']! as Map;
      final providerId = model['providerId']! as Map;
      providerId['value'] = ' ';
      expect(() => codec.decode(malformedModel), throwsA(anything));

      expect(
        () => AgentSessionRecord(
          id: AgentSessionId('bad-role'),
          revision: 1,
          definition: testDefinition(),
          transcript: AgentTranscript(
            messages: <LlmMessage>[
              _message(LlmMessageRole.user, 'question'),
              _message(LlmMessageRole.user, 'not an assistant response'),
            ],
            messageIds: transcript.messageIds,
          ),
          usage: accounting.compatibilityUsage,
          modelTurns: 1,
          toolAttempts: 0,
          createdAtMicros: 1,
          updatedAtMicros: 2,
          tokenAccounting: accounting,
        ),
        throwsA(isA<AgentException>()),
      );
    });
  });

  group('token accounting projections', () {
    test(
      'separates views, marks incomplete totals, and groups exact models',
      () {
        final completed = _assistantEntry(
          sequence: 1,
          attempt: 'completed',
          response: 'old-response',
          usage: _completeUsage(request: 10, response: 5),
          contextRevision: 1,
        );
        final failed = _assistantEntry(
          sequence: 2,
          attempt: 'failed',
          outcome: AgentModelInvocationOutcome.failed,
          usage: LlmUsage(input: LlmUsageMetric.providerReported(4)),
          contextRevision: 2,
        );
        final compaction = _compactionEntry(
          sequence: 3,
          attempt: 'compaction',
          model: _modelB,
          usage: _completeUsage(request: 2, response: 1),
        );
        final state = AgentTokenAccountingState(
          generation: 1,
          contextRevision: 3,
          messageIds: <AgentTranscriptMessageId?>[
            AgentTranscriptMessageId('request-1'),
          ],
          legacyBaseline: LlmUsage(totalTokens: 2),
          entries: <AgentModelUsageEntry>[completed, failed, compaction],
        );
        final view = const AgentTokenAccountingProjector().project(
          state: state,
          retainedContextMeasurement: AgentRetainedContextMeasurement(
            contextRevision: 3,
            estimatorId: 'fixture-estimator',
            estimatorVersion: 2,
            estimate: 77,
          ),
        );

        expect(view.currentRequest?.attemptId.value, 'failed');
        expect(view.currentRequest?.input?.value, 4);
        expect(view.latestResponse?.attemptId.value, 'completed');
        expect(view.latestResponse?.responseGenerated?.value, 5);
        expect(view.latestResponse?.responseMessageRetained, isFalse);
        expect(view.retainedContext.value, 77);
        expect(
          view.retainedContext.provenance,
          LlmUsageMetricProvenance.estimated,
        );
        expect(view.retainedContext.sourceId, 'fixture-estimator');
        expect(view.assistantConversation.overall.knownSubtotal, 15);
        expect(
          view.assistantConversation.overall.completeness,
          LlmUsageCompleteness.partial,
        );
        expect(view.compaction.overall.value, 3);
        expect(view.session.overall.knownSubtotal, 20);
        expect(view.session.overall.value, isNull);
        expect(view.byModel.keys.toList(), <ModelRef>[_modelA, _modelB]);
        expect(view.byModel[_modelB]?.compaction.overall.value, 3);
        expect(view.byModel[_modelB]?.assistant.overall.value, 0);
        expect(view.compaction.cacheHitRatio?.value, 0);
        expect(
          () => view.ledger.add(view.ledger.first),
          throwsUnsupportedError,
        );
        expect(
          () => view.byModel[_modelA] = view.byModel[_modelA]!,
          throwsUnsupportedError,
        );
      },
    );

    test(
      'prefers active request and only reuses provider input at same revision',
      () {
        final state = AgentTokenAccountingState(
          generation: 1,
          contextRevision: 4,
          messageIds: <AgentTranscriptMessageId?>[
            AgentTranscriptMessageId('request-active'),
          ],
          legacyBaseline: LlmUsage(),
          entries: const <AgentModelUsageEntry>[],
        );
        final active = AgentActiveModelUsage(
          attemptId: ProviderAttemptId('active'),
          model: _modelA,
          runId: RunId('run'),
          turnId: TurnId('turn'),
          retryOrdinal: 0,
          requestMessageId: AgentTranscriptMessageId('request-active'),
          contextRevision: 4,
          usage: _completeUsage(request: 12, response: 0),
        );
        final view = const AgentTokenAccountingProjector().project(
          state: state,
          activeAssistant: active,
          retainedContextMeasurement: AgentRetainedContextMeasurement(
            contextRevision: 4,
            estimatorId: 'unused',
            estimatorVersion: 1,
            estimate: 99,
          ),
        );

        expect(view.currentRequest?.active, isTrue);
        expect(view.retainedContext.value, 12);
        expect(
          view.retainedContext.provenance,
          LlmUsageMetricProvenance.providerReported,
        );
        expect(view.retainedContext.providerAttemptId, active.attemptId);
        expect(view.assistantConversation.overall.value, 12);
        expect(view.session.overall.value, 12);
        expect(view.compatibilityUsage.totalTokens, 12);
        expect(view.byModel, isEmpty);
      },
    );

    test('keeps estimator failure unavailable with sanitized metadata', () {
      final state = AgentTokenAccountingState(
        generation: 1,
        contextRevision: 5,
        messageIds: const <AgentTranscriptMessageId?>[],
        legacyBaseline: LlmUsage(),
        entries: const <AgentModelUsageEntry>[],
      );
      final view = const AgentTokenAccountingProjector().project(
        state: state,
        retainedContextMeasurement: AgentRetainedContextMeasurement(
          contextRevision: 5,
          estimatorId: 'configured-estimator',
          estimatorVersion: 7,
        ),
      );

      expect(view.retainedContext.value, isNull);
      expect(view.retainedContext.provenance, isNull);
      expect(view.retainedContext.sourceId, 'configured-estimator');
      expect(view.retainedContext.sourceVersion, 7);
    });
  });
}

final ModelRef _modelA = BuiltInLlmCatalog.deepSeekV4FlashModel.ref;
final ModelRef _modelB = ModelRef(
  providerId: ProviderId('historical-provider'),
  modelId: ModelId('historical-model'),
);

AgentModelUsageEntry _assistantEntry({
  required int sequence,
  required String attempt,
  String? response,
  AgentModelInvocationOutcome outcome = AgentModelInvocationOutcome.completed,
  LlmUsage? usage,
  int contextRevision = 1,
}) => AgentModelUsageEntry.assistant(
  sequence: sequence,
  attemptId: ProviderAttemptId(attempt),
  model: _modelA,
  outcome: outcome,
  usage: usage ?? _completeUsage(request: 10, response: 5),
  contextRevision: contextRevision,
  runId: RunId('run-1'),
  turnId: TurnId('turn-1'),
  retryOrdinal: sequence - 1,
  requestMessageId: AgentTranscriptMessageId('request-1'),
  responseMessageId: response == null
      ? null
      : AgentTranscriptMessageId(response),
);

AgentModelUsageEntry _compactionEntry({
  required int sequence,
  required String attempt,
  ModelRef? model,
  LlmUsage? usage,
}) => AgentModelUsageEntry.compaction(
  sequence: sequence,
  attemptId: ProviderAttemptId(attempt),
  model: model ?? _modelA,
  outcome: AgentModelInvocationOutcome.completed,
  usage: usage ?? _completeUsage(request: 2, response: 1),
  contextRevision: 1,
  compactionOperationId: AgentCompactionOperationId('compact-1'),
  invocationOrdinal: sequence - 1,
  runId: RunId('run-1'),
);

LlmUsage _completeUsage({required int request, required int response}) =>
    LlmUsage(
      input: LlmUsageMetric.providerReported(request),
      cacheRead: LlmUsageMetric.providerReported(0),
      cacheWrite: LlmUsageMetric.providerReported(0),
      output: LlmUsageMetric.providerReported(response),
      reasoning: LlmUsageMetric.providerReported(0),
      reportedInputTotal: LlmUsageMetric.providerReported(request),
      reportedOutputTotal: LlmUsageMetric.providerReported(response),
      reportedOverall: LlmUsageMetric.providerReported(request + response),
    );

LlmMessage _message(LlmMessageRole role, String text) =>
    LlmMessage(role: role, parts: <LlmContentPart>[LlmTextPart(text)]);

final class _MessageCountEstimator implements AgentContextEstimator {
  const _MessageCountEstimator();

  @override
  String get id => 'message-count';

  @override
  int get version => 1;

  @override
  AgentContextEstimate estimate(AgentContextEstimateInput input) =>
      AgentContextEstimate(
        value: input.request.context.messages.length * 10,
        estimatorId: id,
        estimatorVersion: 1,
      );
}

import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  group('model switch fit policy', () {
    test('resolves target output reserve, headroom, threshold, and target', () {
      final policy = OpenCodeAgentModelSwitchFitPolicy(
        outputReserve: 1000,
        headroom: 500,
        postCompactionRatio: 0.5,
      );
      final model = LlmModel(
        providerId: ProviderId('fit-provider'),
        id: ModelId('fit-model'),
        name: 'Fit model',
        wireFamily: LlmWireFamily.openaiChatCompletions,
        capabilities: ModelCapabilities(
          supportsTextInput: true,
          reasoning: ModelReasoningCapability.optional,
          supportsTools: true,
        ),
        contextBound: 10000,
        outputBound: 2000,
      );

      final fit = policy.evaluate(
        AgentModelSwitchFitInput(model: model, maxOutputTokens: null),
      );

      expect(fit.outputReserve, 1000);
      expect(fit.headroom, 500);
      expect(fit.fitThreshold, 8500);
      expect(fit.compactionTarget, 4250);
      expect(
        () => policy.evaluate(
          AgentModelSwitchFitInput(model: model, maxOutputTokens: 2001),
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => OpenCodeAgentModelSwitchFitPolicy(headroom: 0),
        throwsA(isA<AgentException>()),
      );
    });
  });

  group('atomic target-model switch', () {
    test(
      'exact no-op performs no estimate, event, provider call, or save',
      () async {
        final estimator = _Estimator((_) => 1);
        final repository = _RecordingRepository();
        final stack = _runtime(repository: repository, estimator: estimator);
        final session = await stack.runtime
            .agent(_definition())
            .createSession(persistence: SessionPersistence.repository);
        final currentSelection = session.snapshot.selection;
        final saves = repository.saved.length;
        final estimatorCalls = estimator.calls;

        final operation = session.changeSelectionOperation(currentSelection);
        final events = await operation.events.toList();
        final result = await operation.result;

        expect(result.status, AgentSessionSelectionStatus.unchanged);
        expect(events, isEmpty);
        expect(estimator.calls, estimatorCalls);
        expect(repository.saved, hasLength(saves));
        expect(stack.oldProvider.requests, isEmpty);
        expect(stack.targetProvider.requests, isEmpty);
        await session.close();
        await stack.runtime.close();
      },
    );

    test(
      'fitting switch removes opaque continuation atomically and survives restart',
      () async {
        final estimator = _Estimator((_) => 10);
        final repository = _RecordingRepository();
        final record = _recordWithContinuation();
        await repository.save(
          record,
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        );
        final stack = _runtime(repository: repository, estimator: estimator);
        final session = await stack.runtime
            .agent(record.definition)
            .restoreSession(record.id);
        final target = _targetSelection();
        final operation = session.changeSelectionOperation(target);
        final eventsFuture = operation.events.toList();

        final result = await operation.result;
        final events = await eventsFuture;

        expect(result.status, AgentSessionSelectionStatus.changed);
        expect(session.snapshot.selection, target);
        expect(session.snapshot.transcript, record.transcript);
        expect(
          (await repository.load(record.id))!.continuationEntries,
          isEmpty,
        );
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(events.last, isA<AgentSessionSelectionSucceeded>());

        await session.run('next').events.drain<void>();
        expect(stack.oldProvider.requests, isEmpty);
        expect(stack.targetProvider.requests, hasLength(1));
        expect(stack.targetProvider.requests.single.model, target.model);
        await session.close();
        final restored = await stack.runtime
            .agent(record.definition)
            .restoreSession(record.id);
        expect(restored.snapshot.selection, target);
        expect(restored.snapshot.transcript.messages, hasLength(4));
        await restored.close();
        await stack.runtime.close();
      },
    );

    test(
      'oversized switch compacts and commits no old-selection candidate',
      () async {
        final estimator = _Estimator(
          (request) => request.context.messages.length > 2 ? 100 : 10,
        );
        final repository = _RecordingRepository();
        final record = _historyRecord('oversized');
        await repository.save(
          record,
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        );
        final stack = _runtime(
          repository: repository,
          estimator: estimator,
          fitPolicy: const _FitPolicy(threshold: 50, target: 40),
          compactor: RecentInteractionGroupsCompactor(1),
        );
        final session = await stack.runtime
            .agent(record.definition)
            .restoreSession(record.id);
        final operation = session.changeSelectionOperation(_targetSelection());
        final eventsFuture = operation.events.toList();

        final result = await operation.result;
        final events = await eventsFuture;

        expect(result.status, AgentSessionSelectionStatus.changed);
        expect(session.snapshot.selection, _targetSelection());
        expect(session.snapshot.transcript.messages, hasLength(2));
        expect(
          session.snapshot.compactionState?.reason,
          AgentCompactionReason.modelSwitch,
        );
        expect(session.snapshot.compactionState?.afterEstimate, 10);
        final successors = repository.saved.skip(1).toList();
        expect(successors, hasLength(1));
        expect(successors.single.selection, _targetSelection());
        expect(successors.single.transcript.messages, hasLength(2));
        final compactions = events.whereType<AgentSessionSelectionCompaction>();
        expect(compactions.first.compaction, isA<AgentCompactionStarted>());
        expect(compactions.last.compaction, isA<AgentCompactionSucceeded>());
        expect(events.where((event) => event.isTerminal), hasLength(1));
        await session.close();
        await stack.runtime.close();
      },
    );

    test('missing compactor and invalid target keep old state', () async {
      final estimator = _Estimator((_) => 100);
      final repository = _RecordingRepository();
      final stack = _runtime(
        repository: repository,
        estimator: estimator,
        fitPolicy: const _FitPolicy(threshold: 50, target: 40),
      );
      final session = await stack.runtime
          .agent(_definition())
          .createSession(persistence: SessionPersistence.repository);
      final before = session.snapshot;

      final failed = await session.changeSelection(_targetSelection());
      expect(failed.status, AgentSessionSelectionStatus.error);
      expect(failed.error?.kind, AgentErrorKind.compaction);
      expect(session.snapshot.selection, before.selection);
      expect(session.snapshot.revision, before.revision);
      final callsBeforeInvalid = estimator.calls;

      final invalid = await session.changeSelection(
        AgentSessionSelection(
          model: ModelRef(
            providerId: ProviderId('missing'),
            modelId: ModelId('missing'),
          ),
          reasoningMode: ReasoningMode.disabled,
          reasoningEffort: ReasoningEffort.modelDefault,
        ),
      );
      expect(invalid.status, AgentSessionSelectionStatus.error);
      expect(estimator.calls, callsBeforeInvalid);
      await session.close();
      await stack.runtime.close();
    });

    test(
      'cancelled model-backed compaction checkpoints usage once without switch',
      () async {
        final estimator = _Estimator((_) => 100);
        final repository = _RecordingRepository();
        final compactor = _CancellableUsageCompactor();
        final stack = _runtime(
          repository: repository,
          estimator: estimator,
          fitPolicy: const _FitPolicy(threshold: 50, target: 40),
          compactor: compactor,
        );
        final session = await stack.runtime
            .agent(_definition())
            .createSession(persistence: SessionPersistence.repository);
        final before = session.snapshot;
        final operation = session.changeSelectionOperation(_targetSelection());
        final eventsFuture = operation.events.toList();
        await compactor.started.future;

        await operation.cancel();
        final result = await operation.result;
        final events = await eventsFuture;

        expect(result.error?.kind, AgentErrorKind.cancelled);
        expect(session.snapshot.selection, before.selection);
        expect(session.snapshot.transcript, before.transcript);
        expect(session.snapshot.revision, before.revision + 1);
        final entries = session.snapshot.tokenAccounting.ledger
            .map((view) => view.entry)
            .where(
              (entry) =>
                  entry.operationKind == AgentModelOperationKind.compaction,
            )
            .toList();
        expect(entries, hasLength(1));
        expect(entries.single.model, before.selection.model);
        expect(entries.single.outcome, AgentModelInvocationOutcome.cancelled);
        expect(entries.single.responseMessageId, isNull);
        expect(events.where((event) => event.isTerminal), hasLength(1));
        final compactionEvents = events
            .whereType<AgentSessionSelectionCompaction>()
            .map((event) => event.compaction)
            .toList();
        expect(compactionEvents.last, isA<AgentCompactionCancelled>());
        expect(
          (compactionEvents.last as AgentCompactionCancelled).reports,
          hasLength(1),
        );
        expect(events.last, isA<AgentSessionSelectionCancelled>());
        await session.close();
        await stack.runtime.close();
      },
    );

    test(
      'no-change and failed reports checkpoint exact physical usage only once',
      () async {
        for (final failure in <bool>[false, true]) {
          final estimator = _Estimator((_) => 100);
          final repository = _RecordingRepository();
          final reports = <AgentCompactionInvocationReport>[
            AgentCompactionInvocationReport(
              invocationOrdinal: 0,
              model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
              outcome: AgentModelInvocationOutcome.completed,
              usage: LlmUsage(totalTokens: 3),
            ),
            AgentCompactionInvocationReport(
              invocationOrdinal: 1,
              model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
              outcome: failure
                  ? AgentModelInvocationOutcome.failed
                  : AgentModelInvocationOutcome.completed,
              usage: LlmUsage(totalTokens: 5),
            ),
          ];
          final stack = _runtime(
            repository: repository,
            estimator: estimator,
            fitPolicy: const _FitPolicy(threshold: 50, target: 40),
            compactor: _ReportingTerminalCompactor(
              reports: reports,
              failure: failure,
            ),
          );
          final session = await stack.runtime
              .agent(_definition())
              .createSession(persistence: SessionPersistence.repository);
          final before = session.snapshot;
          final operation = session.changeSelectionOperation(
            _targetSelection(),
          );
          final eventsFuture = operation.events.toList();

          final result = await operation.result;
          final events = await eventsFuture;

          expect(result.status, AgentSessionSelectionStatus.error);
          expect(result.error?.kind, AgentErrorKind.compaction);
          expect(session.snapshot.selection, before.selection);
          expect(session.snapshot.transcript, before.transcript);
          expect(session.snapshot.revision, before.revision + 1);
          final entries = session.snapshot.tokenAccounting.ledger
              .map((view) => view.entry)
              .where(
                (entry) =>
                    entry.operationKind == AgentModelOperationKind.compaction,
              )
              .toList();
          expect(entries, hasLength(2));
          expect(entries.map((entry) => entry.usage.totalTokens), <int?>[3, 5]);
          expect(
            entries.every(
              (entry) =>
                  entry.model == BuiltInLlmCatalog.gpt4oMiniModel.ref &&
                  entry.responseMessageId == null,
            ),
            isTrue,
          );
          final terminalCompaction = events
              .whereType<AgentSessionSelectionCompaction>()
              .last
              .compaction;
          final terminalReports = switch (terminalCompaction) {
            AgentCompactionNoChangeEvent(:final reports) => reports,
            AgentCompactionFailed(:final reports) => reports,
            _ => const <AgentCompactionInvocationReport>[],
          };
          expect(terminalReports, hasLength(2));
          expect(events.where((event) => event.isTerminal), hasLength(1));
          await session.close();
          await stack.runtime.close();
        }
      },
    );

    test('combined save conflict retains the complete old state', () async {
      final estimator = _Estimator(
        (request) => request.context.messages.length > 2 ? 100 : 10,
      );
      final repository = _RejectSuccessorRepository(AgentErrorKind.conflict);
      final record = _historyRecord('switch-conflict');
      await repository.seed(record);
      final stack = _runtime(
        repository: repository,
        estimator: estimator,
        fitPolicy: const _FitPolicy(threshold: 50, target: 40),
        compactor: RecentInteractionGroupsCompactor(1),
      );
      final session = await stack.runtime
          .agent(record.definition)
          .restoreSession(record.id);
      final before = session.snapshot;

      final result = await session.changeSelection(_targetSelection());

      expect(result.status, AgentSessionSelectionStatus.error);
      expect(result.error?.kind, AgentErrorKind.conflict);
      expect(session.snapshot.selection, before.selection);
      expect(session.snapshot.transcript, before.transcript);
      expect(session.snapshot.compactionState, before.compactionState);
      expect(await repository.load(record.id), record);
      await session.close();
      await stack.runtime.close();
    });

    test('acknowledged combined save wins a cancellation race', () async {
      final estimator = _Estimator(
        (request) => request.context.messages.length > 2 ? 100 : 10,
      );
      final repository = _CommitThenReleaseRepository();
      final record = _historyRecord('commit-wins-cancel');
      await repository.seed(record);
      repository.arm();
      final stack = _runtime(
        repository: repository,
        estimator: estimator,
        fitPolicy: const _FitPolicy(threshold: 50, target: 40),
        compactor: RecentInteractionGroupsCompactor(1),
      );
      final session = await stack.runtime
          .agent(record.definition)
          .restoreSession(record.id);
      final operation = session.changeSelectionOperation(_targetSelection());
      final eventsFuture = operation.events.toList();
      await repository.committed.future;

      final cancellation = operation.cancel();
      repository.release.complete();
      await cancellation;
      final result = await operation.result;
      final events = await eventsFuture;

      expect(result.status, AgentSessionSelectionStatus.changed);
      expect(session.snapshot.selection, _targetSelection());
      expect(session.snapshot.compactionState, isNotNull);
      expect(events.last, isA<AgentSessionSelectionSucceeded>());
      expect(events.where((event) => event.isTerminal), hasLength(1));
      expect((await repository.load(record.id))!.selection, _targetSelection());
      await session.close();
      await stack.runtime.close();
    });
  });
}

({
  InMemoryAgentRuntime runtime,
  QueueScriptedLlmProvider oldProvider,
  QueueScriptedLlmProvider targetProvider,
})
_runtime({
  required AgentSessionRepository repository,
  required AgentContextEstimator estimator,
  AgentModelSwitchFitPolicy? fitPolicy,
  AgentHistoryCompactor? compactor,
}) {
  final oldProvider = QueueScriptedLlmProvider(
    id: BuiltInLlmCatalog.openAi,
    wireFamily: LlmWireFamily.openaiResponses,
    turns: const <List<LlmEvent>>[],
  );
  final targetProvider = QueueScriptedLlmProvider(
    id: BuiltInLlmCatalog.deepSeek,
    wireFamily: LlmWireFamily.openaiChatCompletions,
    turns: <List<LlmEvent>>[textTurn('target answer')],
  );
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  registry.registerProvider(oldProvider);
  registry.registerProvider(targetProvider);
  final runtime = InMemoryAgentRuntime(
    registry: registry,
    repository: repository,
    tools: AgentToolRegistry(),
    policies: <String, ToolPermissionPolicy>{'allow': const AllowAllPolicy()},
    contextEstimator: estimator,
    modelSwitchFitPolicy: fitPolicy,
    historyCompactor: compactor,
  );
  return (
    runtime: runtime,
    oldProvider: oldProvider,
    targetProvider: targetProvider,
  );
}

AgentDefinition _definition() => AgentDefinition(
  id: AgentId('switch-agent'),
  name: 'Switch agent',
  systemPrompt: '',
  model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
  generation: LlmGenerationConfig(reasoningMode: ReasoningMode.disabled),
  policy: PolicyId('allow'),
);

AgentSessionSelection _targetSelection() => AgentSessionSelection(
  model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
  reasoningMode: ReasoningMode.enabled,
  reasoningEffort: ReasoningEffort.modelDefault,
);

AgentSessionRecord _recordWithContinuation() {
  final transcript = AgentTranscript(
    messages: <LlmMessage>[
      _message(LlmMessageRole.user, 'old question'),
      _message(LlmMessageRole.assistant, 'old answer'),
    ],
  );
  return AgentSessionRecord(
    id: AgentSessionId('continuation-switch'),
    revision: 0,
    definition: _definition(),
    transcript: transcript,
    usage: LlmUsage(),
    modelTurns: 1,
    toolAttempts: 0,
    createdAtMicros: 1,
    updatedAtMicros: 1,
    continuationEntries: <LlmContinuationEntry>[
      LlmContinuationEntry(
        assistantMessageIndex: 1,
        state: LlmProviderTurnState(
          origin: BuiltInLlmCatalog.gpt4oMiniModel.ref,
          wireFamily: LlmWireFamily.openaiResponses,
          format: openaiResponsesOutputItemsV1,
          payload: const <Map<String, Object?>>[
            <String, Object?>{
              'type': 'message',
              'id': 'old-response',
              'role': 'assistant',
              'content': <Map<String, Object?>>[
                <String, Object?>{
                  'type': 'output_text',
                  'text': 'old answer',
                  'annotations': <Object?>[],
                },
              ],
            },
          ],
        ),
      ),
    ],
  );
}

AgentSessionRecord _historyRecord(String id) => AgentSessionRecord(
  id: AgentSessionId(id),
  revision: 0,
  definition: _definition(),
  transcript: AgentTranscript(
    messages: <LlmMessage>[
      _message(LlmMessageRole.user, 'old one'),
      _message(LlmMessageRole.assistant, 'answer one'),
      _message(LlmMessageRole.user, 'old two'),
      _message(LlmMessageRole.assistant, 'answer two'),
    ],
  ),
  usage: LlmUsage(),
  modelTurns: 2,
  toolAttempts: 0,
  createdAtMicros: 1,
  updatedAtMicros: 1,
);

LlmMessage _message(LlmMessageRole role, String text) =>
    LlmMessage(role: role, parts: <LlmContentPart>[LlmTextPart(text)]);

final class _Estimator implements AgentContextEstimator {
  _Estimator(this.valueFor);

  final int Function(LlmRequestSnapshot request) valueFor;
  var calls = 0;

  @override
  String get id => 'switch-estimator';

  @override
  int get version => 1;

  @override
  AgentContextEstimate estimate(AgentContextEstimateInput input) {
    calls += 1;
    if (input.cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    return AgentContextEstimate(
      value: valueFor(input.request),
      estimatorId: id,
      estimatorVersion: version,
    );
  }
}

final class _FitPolicy implements AgentModelSwitchFitPolicy {
  const _FitPolicy({required this.threshold, required this.target});

  final int threshold;
  final int target;

  @override
  String get id => 'test-switch-fit';

  @override
  int get version => 1;

  @override
  AgentModelSwitchFit evaluate(AgentModelSwitchFitInput input) =>
      AgentModelSwitchFit(
        contextBound: input.model.contextBound,
        outputReserve: 1,
        headroom: 1,
        fitThreshold: threshold,
        compactionTarget: target,
        policyId: id,
        policyVersion: version,
      );
}

final class _CancellableUsageCompactor implements AgentHistoryCompactor {
  final Completer<void> started = Completer<void>();

  @override
  String get id => 'cancellable-usage';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    if (!started.isCompleted) started.complete();
    final cancelled = Completer<void>();
    final registration = context.cancellation.register(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    try {
      await cancelled.future;
    } finally {
      registration.dispose();
    }
    throw AgentCompactionStrategyException.cancelled(
      reports: <AgentCompactionInvocationReport>[
        AgentCompactionInvocationReport(
          invocationOrdinal: 0,
          model:
              context.request.model ==
                  BuiltInLlmCatalog.deepSeekV4FlashModel.ref
              ? BuiltInLlmCatalog.gpt4oMiniModel.ref
              : context.request.model,
          outcome: AgentModelInvocationOutcome.cancelled,
          usage: LlmUsage(totalTokens: 7),
        ),
      ],
    );
  }
}

final class _ReportingTerminalCompactor implements AgentHistoryCompactor {
  const _ReportingTerminalCompactor({
    required this.reports,
    required this.failure,
  });

  final List<AgentCompactionInvocationReport> reports;
  final bool failure;

  @override
  String get id => 'reporting-terminal';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    if (failure) {
      throw AgentCompactionStrategyException.failed(reports: reports);
    }
    return AgentCompactionNoChange(
      strategyId: id,
      strategyVersion: version,
      reports: reports,
    );
  }
}

final class _RejectSuccessorRepository implements AgentSessionRepository {
  _RejectSuccessorRepository(this.kind);

  final AgentErrorKind kind;
  final InMemoryAgentSessionRepository delegate =
      InMemoryAgentSessionRepository();
  var _rejected = false;

  Future<void> seed(AgentSessionRecord record) => delegate.save(
    record,
    expectedRevision: 0,
    cancellation: CancellationSource().token,
  );

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => delegate.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (!_rejected) {
      _rejected = true;
      throw AgentException(
        AgentError(kind: kind, message: 'private rejected successor detail'),
      );
    }
    await delegate.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => delegate.delete(
    id,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );
}

final class _CommitThenReleaseRepository implements AgentSessionRepository {
  final InMemoryAgentSessionRepository delegate =
      InMemoryAgentSessionRepository();
  final Completer<void> committed = Completer<void>();
  final Completer<void> release = Completer<void>();
  var _armed = false;

  Future<void> seed(AgentSessionRecord record) => delegate.save(
    record,
    expectedRevision: 0,
    cancellation: CancellationSource().token,
  );

  void arm() => _armed = true;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => delegate.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    await delegate.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: CancellationSource().token,
    );
    if (_armed) {
      if (!committed.isCompleted) committed.complete();
      await release.future;
    }
  }

  @override
  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => delegate.delete(
    id,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );
}

final class _RecordingRepository implements AgentSessionRepository {
  final InMemoryAgentSessionRepository delegate =
      InMemoryAgentSessionRepository();
  final List<AgentSessionRecord> saved = <AgentSessionRecord>[];

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => delegate.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    await delegate.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
    saved.add(record);
  }

  @override
  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => delegate.delete(
    id,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );
}

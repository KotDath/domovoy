import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';

final class _FakeExtractor implements MemoryBatchExtractor {
  _FakeExtractor(this.handler);

  FutureOr<List<MemoryCandidateDraft>> Function(
    MemoryExtractionInput input,
    CancellationToken cancellation,
  )
  handler;
  var calls = 0;
  final List<MemoryExtractionInput> inputs = <MemoryExtractionInput>[];

  @override
  Future<List<MemoryCandidateDraft>> extract(
    MemoryExtractionInput input, {
    required CancellationToken cancellation,
  }) async {
    calls += 1;
    inputs.add(input);
    return handler(input, cancellation);
  }
}

final class _FakeCommandClassifier implements MemoryCommandClassifier {
  _FakeCommandClassifier(this.result);

  final MemoryPhraseProposal? result;
  var calls = 0;
  final List<String> messages = <String>[];

  @override
  Future<MemoryPhraseProposal?> classify(
    String message, {
    required CancellationToken cancellation,
  }) async {
    calls += 1;
    messages.add(message);
    return result;
  }
}

final class _FailingAdvanceCheckpoints
    implements MemoryExtractionCheckpointRepository {
  final inner = InMemoryMemoryExtractionCheckpointRepository();
  var failNextAdvance = true;

  @override
  Future<MemoryExtractionCheckpoint?> load(
    AgentSessionId sessionId, {
    required CancellationToken cancellation,
  }) => inner.load(sessionId, cancellation: cancellation);

  @override
  Future<void> save(
    MemoryExtractionCheckpoint checkpoint, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (checkpoint.revision > 0 && failNextAdvance) {
      failNextAdvance = false;
      throw MemoryException(
        MemoryError(kind: MemoryErrorKind.persistence, message: 'boom'),
      );
    }
    return inner.save(
      checkpoint,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(
    AgentSessionId sessionId, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => inner.delete(
    sessionId,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );

  @override
  Future<List<MemoryExtractionCheckpoint>> list({
    required CancellationToken cancellation,
  }) => inner.list(cancellation: cancellation);
}

final class _Harness {
  _Harness({
    FutureOr<List<MemoryCandidateDraft>> Function(MemoryExtractionInput)?
    handler,
    FutureOr<List<MemoryCandidateDraft>> Function(
      MemoryExtractionInput,
      CancellationToken,
    )?
    cancellableHandler,
    MemoryExtractionCheckpointRepository? checkpointRepository,
    MemoryCommandClassifier? commandClassifier,
  }) {
    extractor = _FakeExtractor(
      cancellableHandler ??
          (input, cancellation) =>
              (handler ?? (_) => <MemoryCandidateDraft>[_draft()])(input),
    );
    working = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
    longTerm = InMemoryMemoryEntryRepository(layer: MemoryLayer.longTerm);
    candidates = InMemoryMemoryCandidateRepository();
    checkpoints =
        checkpointRepository ?? InMemoryMemoryExtractionCheckpointRepository();
    clock = FakeAgentClock();
    coordinator = MemoryExtractionCoordinator(
      extractor: extractor,
      commandClassifier: commandClassifier,
      repositories: MemoryRepositories(
        workingRepository: working,
        longTermRepository: longTerm,
        candidateRepository: candidates,
      ),
      checkpoints: checkpoints,
      clock: clock,
      ids: MemoryExtractionIdFactory(namespace: 'test'),
      idleFlushAfter: const Duration(minutes: 30),
    );
  }

  late final _FakeExtractor extractor;
  late final InMemoryMemoryEntryRepository working;
  late final InMemoryMemoryEntryRepository longTerm;
  late final InMemoryMemoryCandidateRepository candidates;
  late final MemoryExtractionCheckpointRepository checkpoints;
  late final FakeAgentClock clock;
  late final MemoryExtractionCoordinator coordinator;
}

final sessionId = AgentSessionId('session-1');
final projectId = ProjectId('project-1');
final open = CancellationSource().token;

MemoryCandidateDraft _draft({String content = 'Extracted fact.'}) {
  return MemoryCandidateDraft(
    operation: MemoryProposalOperation.create,
    layer: MemoryLayer.working,
    scope: MemoryScope.project,
    kind: MemoryKind.fact,
    content: content,
  );
}

List<MemoryExtractionSource> _sources(
  int count, {
  int start = 0,
  MemoryTranscriptRole role = MemoryTranscriptRole.user,
}) {
  return List<MemoryExtractionSource>.generate(
    count,
    (index) => MemoryExtractionSource(
      id: MemorySourceId('s${start + index}'),
      role: role,
      text: 'message ${start + index}',
    ),
  );
}

void main() {
  group('MemoryExtractionCoordinator', () {
    test('candidate identities stay compact for production runtime ids', () {
      final factory = MemoryExtractionIdFactory(namespace: 'extract');
      final session = AgentSessionId(
        'runtime-hmh2876gs5-as2j9s-6ki29g-akesu3-f1o267-session-1',
      );
      final source = MemorySourceId(
        'runtime-hmh2876gs5-as2j9s-6ki29g-akesu3-f1o267-message-3',
      );

      final first = factory.forExplicitPhrase(
        sessionId: session,
        sourceId: source,
        phraseIndex: 0,
      );
      final repeated = factory.forExplicitPhrase(
        sessionId: session,
        sourceId: source,
        phraseIndex: 0,
      );
      final next = factory.forExplicitPhrase(
        sessionId: session,
        sourceId: source,
        phraseIndex: 1,
      );
      final batch = factory.forBatchProposal(
        sessionId: session,
        sourceIds: List<MemorySourceId>.generate(
          40,
          (index) => MemorySourceId('${source.value}-$index'),
        ),
        proposalIndex: 0,
      );

      expect(first, repeated);
      expect(first, isNot(next));
      expect(first.value, startsWith('memory-candidate-v2-'));
      expect(first.value.length, lessThanOrEqualTo(64));
      expect(batch.value.length, lessThanOrEqualTo(64));
    });

    test('explicit phrases create candidates without an LLM call', () async {
      final harness = _Harness();
      final result = await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[
          MemoryExtractionSource(
            id: MemorySourceId('u1'),
            role: MemoryTranscriptRole.user,
            text: 'remember project: Deployment uses kubernetes.',
          ),
        ],
      );

      expect(harness.extractor.calls, 0);
      expect(result.candidates, hasLength(1));
      final stored = await harness.candidates.list(cancellation: open);
      expect(stored, hasLength(1));
      expect(stored.single.projectId, projectId);
      expect(stored.single.layer, MemoryLayer.working);
      expect(stored.single.sourceIds.map((id) => id.value), <String>['u1']);
      expect(await harness.working.list(cancellation: open), isEmpty);
    });

    test('explicit phrase persistence is idempotent by source', () async {
      final harness = _Harness();
      final source = MemoryExtractionSource(
        id: MemorySourceId('u1'),
        role: MemoryTranscriptRole.user,
        text: 'remember global: Prefers concise answers.',
      );

      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[source],
      );
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[source],
      );

      expect(await harness.candidates.list(cancellation: open), hasLength(1));
      expect(harness.extractor.calls, 0);
    });

    test('LLM fallback classifies only a missed latest command', () async {
      final classifier = _FakeCommandClassifier(
        const MemoryPhraseProposal(
          layer: MemoryLayer.longTerm,
          scope: MemoryScope.global,
          kind: MemoryKind.fact,
          content: 'Меня зовут Даниил.',
        ),
      );
      final harness = _Harness(commandClassifier: classifier);
      final source = MemoryExtractionSource(
        id: MemorySourceId('u-typo'),
        role: MemoryTranscriptRole.user,
        text: 'Запомни гглобально, что меня зовут Даниил',
      );

      final result = await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[
          MemoryExtractionSource(
            id: MemorySourceId('u-old'),
            role: MemoryTranscriptRole.user,
            text: 'Обычное старое сообщение',
          ),
          source,
        ],
      );

      expect(result.candidates, hasLength(1));
      expect(classifier.calls, 1);
      expect(classifier.messages, <String>[source.text]);
      final stored = await harness.candidates.list(cancellation: open);
      expect(stored, hasLength(1));
      expect(stored.single.layer, MemoryLayer.longTerm);
      expect(stored.single.scope, MemoryScope.global);
      expect(stored.single.projectId, isNull);

      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[source],
      );
      expect(classifier.calls, 1, reason: 'the source was already classified');
      expect(await harness.candidates.list(cancellation: open), hasLength(1));
    });

    test('deterministic fast path bypasses the LLM classifier', () async {
      final classifier = _FakeCommandClassifier(null);
      final harness = _Harness(commandClassifier: classifier);

      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[
          MemoryExtractionSource(
            id: MemorySourceId('u-fast'),
            role: MemoryTranscriptRole.user,
            text: 'Запомни глобально: меня зовут Даниил',
          ),
        ],
      );

      expect(classifier.calls, 0);
      expect(await harness.candidates.list(cancellation: open), hasLength(1));
    });

    test(
      'periodic extraction does not duplicate a command candidate',
      () async {
        final classifier = _FakeCommandClassifier(
          const MemoryPhraseProposal(
            layer: MemoryLayer.working,
            scope: MemoryScope.project,
            kind: MemoryKind.fact,
            content: 'Deployment uses kubernetes.',
          ),
        );
        final harness = _Harness(
          commandClassifier: classifier,
          handler: (_) => <MemoryCandidateDraft>[
            _draft(content: 'Deployment uses kubernetes.'),
          ],
        );
        final sources = <MemoryExtractionSource>[
          MemoryExtractionSource(
            id: MemorySourceId('u-command'),
            role: MemoryTranscriptRole.user,
            text: 'Please keep in mind that deployment uses kubernetes.',
          ),
        ];

        await harness.coordinator.onCompletedTurn(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: sources,
        );
        await harness.coordinator.analyzeNow(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: sources,
        );

        expect(classifier.calls, 1);
        expect(harness.extractor.calls, 1);
        expect(await harness.candidates.list(cancellation: open), hasLength(1));
      },
    );

    test(
      'periodic extraction drops an update with unchanged content',
      () async {
        late final MemoryEntry target;
        final harness = _Harness(
          handler: (_) => <MemoryCandidateDraft>[
            MemoryCandidateDraft(
              operation: MemoryProposalOperation.update,
              layer: MemoryLayer.working,
              scope: MemoryScope.project,
              kind: MemoryKind.fact,
              content: target.content,
              targetEntryId: target.id,
            ),
          ],
        );
        target = workingEntry(
          id: 'existing-fact',
          content: 'Проект деплоится только через Kubernetes.',
        );
        await harness.working.save(
          target,
          expectedRevision: 0,
          cancellation: open,
        );

        await harness.coordinator.analyzeNow(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: _sources(2),
        );

        expect(harness.extractor.calls, 1);
        expect(await harness.candidates.list(cancellation: open), isEmpty);
      },
    );

    test(
      'waits for 40 messages then advances by 38 keeping a 2 overlap',
      () async {
        final harness = _Harness();
        await harness.coordinator.onCompletedTurn(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: _sources(39),
        );
        expect(harness.extractor.calls, 0);
        final before = (await harness.checkpoints.load(
          sessionId,
          cancellation: open,
        ))!;
        expect(before.pendingSourceIds, hasLength(39));
        expect(before.processedSourceIds, isEmpty);

        final flushed = await harness.coordinator.onCompletedTurn(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: _sources(1, start: 39),
        );
        expect(harness.extractor.calls, 1);
        expect(harness.extractor.inputs.single.sources, hasLength(40));
        expect(flushed.isExtracted, isTrue);
        final after = (await harness.checkpoints.load(
          sessionId,
          cancellation: open,
        ))!;
        expect(after.processedSourceIds, hasLength(38));
        expect(after.pendingSourceIds.map((id) => id.value), <String>[
          's38',
          's39',
        ]);
      },
    );

    test('the next window reuses the trailing overlap', () async {
      final harness = _Harness();
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(40),
      );
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(38, start: 40),
      );

      expect(harness.extractor.calls, 2);
      final second = harness.extractor.inputs.last.sources;
      expect(second.take(2).map((source) => source.id.value), <String>[
        's38',
        's39',
      ]);
      expect(second, hasLength(40));
    });

    test('manual analyze now flushes a partial batch', () async {
      final harness = _Harness();
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(3),
      );
      expect(harness.extractor.calls, 0);

      final result = await harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(3),
      );
      expect(result.isExtracted, isTrue);
      expect(harness.extractor.calls, 1);
      final checkpoint = (await harness.checkpoints.load(
        sessionId,
        cancellation: open,
      ))!;
      expect(checkpoint.processedSourceIds, hasLength(3));
      expect(checkpoint.pendingSourceIds, isEmpty);
    });

    test('manual analyze recovers an explicit natural phrase', () async {
      final harness = _Harness(handler: (_) => const <MemoryCandidateDraft>[]);
      final result = await harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[
          MemoryExtractionSource(
            id: MemorySourceId('u-natural'),
            role: MemoryTranscriptRole.user,
            text: 'Запомни, что деплой делается только через kubernetes',
          ),
        ],
      );

      expect(result.isExtracted, isTrue);
      expect(harness.extractor.calls, 1);
      final stored = await harness.candidates.list(cancellation: open);
      expect(stored, hasLength(1));
      expect(stored.single.layer, MemoryLayer.working);
      expect(stored.single.content, 'деплой делается только через kubernetes');
    });

    test('session resume recovers an explicit phrase automatically', () async {
      final harness = _Harness(handler: (_) => const <MemoryCandidateDraft>[]);
      final result = await harness.coordinator.resume(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[
          MemoryExtractionSource(
            id: MemorySourceId('u-resumed'),
            role: MemoryTranscriptRole.user,
            text: 'Запомни, что деплоим мы через kubernetes',
          ),
        ],
      );

      expect(result.isExtracted, isTrue);
      expect(harness.extractor.calls, 0);
      final stored = await harness.candidates.list(cancellation: open);
      expect(stored, hasLength(1));
      expect(stored.single.content, 'деплоим мы через kubernetes');
    });

    test('idle debounce flushes after 30 minutes in the foreground', () async {
      final harness = _Harness();
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(5),
      );
      expect(harness.extractor.calls, 0);

      harness.clock.elapse(const Duration(minutes: 30));
      await harness.coordinator.settle(sessionId);

      expect(harness.extractor.calls, 1);
      final checkpoint = (await harness.checkpoints.load(
        sessionId,
        cancellation: open,
      ))!;
      expect(checkpoint.processedSourceIds, hasLength(5));
      expect(checkpoint.pendingSourceIds, isEmpty);

      harness.clock.elapse(const Duration(minutes: 30));
      await harness.coordinator.settle(sessionId);
      expect(harness.extractor.calls, 1);
    });

    test('failures do not advance the checkpoint and can be retried', () async {
      var fail = true;
      final harness = _Harness(
        handler: (input) {
          if (fail) {
            throw MemoryException(
              MemoryError(kind: MemoryErrorKind.protocol, message: 'boom'),
            );
          }
          return <MemoryCandidateDraft>[_draft()];
        },
      );
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(5),
      );

      final failed = await harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(5),
      );
      expect(failed.status, MemoryExtractionStatus.failed);
      var checkpoint = (await harness.checkpoints.load(
        sessionId,
        cancellation: open,
      ))!;
      expect(checkpoint.pendingSourceIds, hasLength(5));
      expect(checkpoint.processedSourceIds, isEmpty);

      fail = false;
      final retried = await harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(5),
      );
      expect(retried.isExtracted, isTrue);
      checkpoint = (await harness.checkpoints.load(
        sessionId,
        cancellation: open,
      ))!;
      expect(checkpoint.processedSourceIds, hasLength(5));
    });

    test(
      'retry after checkpoint failure does not duplicate candidates',
      () async {
        final checkpoints = _FailingAdvanceCheckpoints();
        final harness = _Harness(checkpointRepository: checkpoints);

        final failed = await harness.coordinator.analyzeNow(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: _sources(5),
        );
        expect(failed.status, MemoryExtractionStatus.failed);
        expect(await harness.candidates.list(cancellation: open), hasLength(1));

        final retried = await harness.coordinator.analyzeNow(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: _sources(5),
        );
        expect(retried.isExtracted, isTrue);
        expect(await harness.candidates.list(cancellation: open), hasLength(1));
        final checkpoint = (await checkpoints.load(
          sessionId,
          cancellation: open,
        ))!;
        expect(checkpoint.pendingSourceIds, isEmpty);
      },
    );

    test('is single-flight per session', () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final harness = _Harness(
        handler: (input) async {
          if (!started.isCompleted) {
            started.complete();
          }
          await gate.future;
          return <MemoryCandidateDraft>[_draft()];
        },
      );
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(4),
      );

      final first = harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(4),
      );
      await started.future;
      final second = await harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(4),
      );
      expect(second.status, MemoryExtractionStatus.busy);

      gate.complete();
      expect((await first).isExtracted, isTrue);
      await harness.coordinator.settle(sessionId);
      expect(harness.extractor.calls, 1);
    });

    test('a queued manual flush preserves force semantics', () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final harness = _Harness(
        handler: (input) async {
          if (!started.isCompleted) {
            started.complete();
          }
          await gate.future;
          return <MemoryCandidateDraft>[_draft()];
        },
      );

      final automatic = harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(40),
      );
      await started.future;
      final manual = await harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(40),
      );
      expect(manual.status, MemoryExtractionStatus.busy);

      gate.complete();
      await automatic;
      await harness.coordinator.settle(sessionId);
      expect(harness.extractor.calls, 2);
      final checkpoint = (await harness.checkpoints.load(
        sessionId,
        cancellation: open,
      ))!;
      expect(checkpoint.pendingSourceIds, isEmpty);
    });

    test('pause cancels timers and resume performs an overdue flush', () async {
      final harness = _Harness();
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(5),
      );
      harness.coordinator.pause(sessionId);
      expect(harness.coordinator.isPaused(sessionId), isTrue);

      harness.clock.elapse(const Duration(minutes: 30));
      await harness.coordinator.settle(sessionId);
      expect(harness.extractor.calls, 0);

      final resumed = await harness.coordinator.resume(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(5),
      );
      expect(resumed.isExtracted, isTrue);
      expect(harness.extractor.calls, 1);
      final checkpoint = (await harness.checkpoints.load(
        sessionId,
        cancellation: open,
      ))!;
      expect(checkpoint.pendingSourceIds, isEmpty);
      expect(harness.coordinator.isPaused(sessionId), isFalse);
    });

    test(
      'pause cancels an extraction already running in the background',
      () async {
        final started = Completer<void>();
        final harness = _Harness(
          cancellableHandler: (input, cancellation) async {
            started.complete();
            await cancellation.whenCancelled;
            throw MemoryException(
              MemoryError(
                kind: MemoryErrorKind.cancelled,
                message: 'cancelled',
              ),
            );
          },
        );
        final extraction = harness.coordinator.analyzeNow(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: _sources(5),
        );
        await started.future;

        harness.coordinator.pause(sessionId);
        final result = await extraction;

        expect(result.status, MemoryExtractionStatus.failed);
        expect(harness.coordinator.isPaused(sessionId), isTrue);
        final checkpoint = (await harness.checkpoints.load(
          sessionId,
          cancellation: open,
        ))!;
        expect(checkpoint.pendingSourceIds, hasLength(5));
        expect(await harness.candidates.list(cancellation: open), isEmpty);
      },
    );

    test('dispose cancels pending foreground timers', () async {
      final harness = _Harness();
      await harness.coordinator.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(5),
      );

      harness.coordinator.dispose();
      harness.clock.elapse(const Duration(minutes: 30));
      await harness.coordinator.settle(sessionId);

      expect(harness.extractor.calls, 0);
    });

    test(
      'resume schedules the remaining idle delay, not a fresh 30 minutes',
      () async {
        final harness = _Harness();
        await harness.coordinator.onCompletedTurn(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: _sources(5),
        );
        harness.coordinator.pause(sessionId);
        harness.clock.elapse(const Duration(minutes: 20));

        await harness.coordinator.resume(
          sessionId: sessionId,
          projectId: projectId,
          completedSources: _sources(5),
        );
        harness.clock.elapse(const Duration(minutes: 9, seconds: 59));
        await harness.coordinator.settle(sessionId);
        expect(harness.extractor.calls, 0);

        harness.clock.elapse(const Duration(seconds: 1));
        await harness.coordinator.settle(sessionId);
        expect(harness.extractor.calls, 1);
      },
    );

    test('never writes active memory', () async {
      final harness = _Harness();
      await harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(6),
      );
      expect(await harness.working.list(cancellation: open), isEmpty);
      expect(await harness.longTerm.list(cancellation: open), isEmpty);
      expect(await harness.candidates.list(cancellation: open), hasLength(1));
      // Sanity: an active entry in the project is only used as extractor input.
      await harness.working.save(
        workingEntry(),
        expectedRevision: 0,
        cancellation: open,
      );
      final result = await harness.coordinator.analyzeNow(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: _sources(1, start: 100),
      );
      expect(result.isExtracted, isTrue);
      expect(harness.extractor.inputs.last.activeEntries, hasLength(1));
      expect(
        (await harness.working.list(cancellation: open)).single.isActive,
        isTrue,
      );
    });
  });
}

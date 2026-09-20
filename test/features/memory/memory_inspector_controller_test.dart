import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/features/memory/application/memory_inspector_controller.dart';
import 'package:domovoy/features/memory/application/memory_inspector_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/memory_fixtures.dart';

final projectId = ProjectId('project-1');

final class _FakeExtractor implements MemoryBatchExtractor {
  var calls = 0;

  @override
  Future<List<MemoryCandidateDraft>> extract(
    MemoryExtractionInput input, {
    required CancellationToken cancellation,
  }) async {
    calls += 1;
    return <MemoryCandidateDraft>[
      const MemoryCandidateDraft(
        operation: MemoryProposalOperation.create,
        layer: MemoryLayer.working,
        scope: MemoryScope.project,
        kind: MemoryKind.fact,
        content: 'Extracted fact from the batch.',
      ),
    ];
  }
}

final class _Harness {
  _Harness({this.useInjectedEntryIds = true}) {
    working = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
    longTerm = InMemoryMemoryEntryRepository(layer: MemoryLayer.longTerm);
    candidates = InMemoryMemoryCandidateRepository();
    checkpoints = InMemoryMemoryExtractionCheckpointRepository();
    repositories = MemoryRepositories(
      workingRepository: working,
      longTermRepository: longTerm,
      candidateRepository: candidates,
    );
    retrieval = LayeredMemoryRetrievalService(repositories: repositories);
    toggles = MemoryReadTogglesController();
    extractor = _FakeExtractor();
    clock = FakeAgentClock(startMicros: 1000);
    extraction = MemoryExtractionCoordinator(
      extractor: extractor,
      repositories: repositories,
      checkpoints: checkpoints,
      clock: clock,
      ids: MemoryExtractionIdFactory(namespace: 'test'),
    );
    controller = MemoryInspectorController(
      repositories: repositories,
      retrieval: retrieval,
      toggles: toggles,
      extraction: extraction,
      entryIds: useInjectedEntryIds ? () => 'entry-${++_entrySequence}' : null,
      nowMicros: clock.nowMicros,
    );
  }

  final bool useInjectedEntryIds;

  late final InMemoryMemoryEntryRepository working;
  late final InMemoryMemoryEntryRepository longTerm;
  late final InMemoryMemoryCandidateRepository candidates;
  late final InMemoryMemoryExtractionCheckpointRepository checkpoints;
  late final MemoryRepositories repositories;
  late final LayeredMemoryRetrievalService retrieval;
  late final MemoryReadTogglesController toggles;
  late final _FakeExtractor extractor;
  late final FakeAgentClock clock;
  late final MemoryExtractionCoordinator extraction;
  late final MemoryInspectorController controller;
  var _entrySequence = 0;

  Future<void> seedEntry(
    InMemoryMemoryEntryRepository repository,
    MemoryEntry entry,
  ) {
    return repository.save(
      entry,
      expectedRevision: 0,
      cancellation: CancellationSource().token,
    );
  }

  void dispose() {
    controller.dispose();
    toggles.dispose();
  }
}

AgentSessionSnapshot _snapshot() {
  final messages = <LlmMessage>[
    LlmMessage(
      role: LlmMessageRole.user,
      parts: <LlmContentPart>[LlmTextPart('Deployment uses kubernetes.')],
    ),
    LlmMessage(
      role: LlmMessageRole.assistant,
      parts: <LlmContentPart>[LlmTextPart('Understood.')],
    ),
  ];
  return AgentSessionSnapshot(
    id: AgentSessionId('session-1'),
    definition: testDefinition(),
    lifecycle: AgentSessionLifecycle.idle,
    transcript: AgentTranscript(
      messages: messages,
      messageIds: <AgentTranscriptMessageId?>[
        AgentTranscriptMessageId('m0'),
        AgentTranscriptMessageId('m1'),
      ],
    ),
    usage: LlmUsage(),
    modelTurns: 0,
    toolAttempts: 0,
    revision: 0,
    compactionState: null,
  );
}

AgentSessionSnapshot _explicitMemorySnapshot() {
  return AgentSessionSnapshot(
    id: AgentSessionId('session-callback'),
    definition: testDefinition(),
    lifecycle: AgentSessionLifecycle.idle,
    transcript: AgentTranscript(
      messages: <LlmMessage>[
        LlmMessage(
          role: LlmMessageRole.user,
          parts: <LlmContentPart>[
            LlmTextPart('remember global: Prefers concise answers.'),
          ],
        ),
        LlmMessage(
          role: LlmMessageRole.assistant,
          parts: <LlmContentPart>[LlmTextPart('Запомнил.')],
        ),
      ],
      messageIds: <AgentTranscriptMessageId?>[
        AgentTranscriptMessageId('callback-user'),
        AgentTranscriptMessageId('callback-assistant'),
      ],
    ),
    usage: LlmUsage(),
    modelTurns: 1,
    toolAttempts: 0,
    revision: 1,
    compactionState: null,
    projectId: projectId,
  );
}

void main() {
  final open = CancellationSource().token;

  group('MemoryInspectorController', () {
    test('exposes short-term transcript and stored memory layers', () async {
      final harness = _Harness();
      await harness.seedEntry(harness.working, workingEntry());
      await harness.seedEntry(harness.longTerm, longTermEntry());
      await harness.candidates.save(
        createCandidate(id: 'candidate-1'),
        expectedRevision: 0,
        cancellation: open,
      );

      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );

      final state = harness.controller.state;
      expect(state.status, MemoryInspectorStatus.ready);
      expect(state.shortTerm, hasLength(2));
      expect(state.shortTerm.first.text, 'Deployment uses kubernetes.');
      expect(state.working, hasLength(1));
      expect(state.longTerm, hasLength(1));
      expect(state.candidates, hasLength(1));
      expect(state.trace, isNotNull);
      harness.dispose();
    });

    test(
      'completed-turn callback persists explicit phrases automatically',
      () async {
        final harness = _Harness();

        await harness.controller.recordCompletedTurn(_explicitMemorySnapshot());

        expect(harness.extractor.calls, 0);
        final candidates = await harness.candidates.list(cancellation: open);
        expect(candidates, hasLength(1));
        expect(candidates.single.layer, MemoryLayer.longTerm);
        expect(candidates.single.content, 'Prefers concise answers.');
        final checkpoint = await harness.checkpoints.load(
          AgentSessionId('session-callback'),
          cancellation: open,
        );
        expect(checkpoint!.pendingSourceIds, hasLength(2));
        harness.dispose();
      },
    );

    test(
      'confirmation creates an active entry and accepts the candidate',
      () async {
        final harness = _Harness();
        final candidate = createCandidate(id: 'candidate-confirm');
        await harness.candidates.save(
          candidate,
          expectedRevision: 0,
          cancellation: open,
        );
        await harness.controller.attachSession(
          session: _snapshot(),
          projectId: projectId,
        );

        await harness.controller.confirmCandidate(candidate);

        final active = await harness.working.list(cancellation: open);
        expect(active, hasLength(1));
        expect(active.single.content, candidate.content);
        expect(active.single.projectId, projectId);
        expect(
          await harness.candidates.list(
            status: MemoryCandidateStatus.pending,
            cancellation: open,
          ),
          isEmpty,
        );
        expect(
          await harness.candidates.list(
            status: MemoryCandidateStatus.accepted,
            cancellation: open,
          ),
          hasLength(1),
        );
        harness.dispose();
      },
    );

    test('production entry identity is stable and candidate-owned', () async {
      final harness = _Harness(useInjectedEntryIds: false);
      final candidate = createCandidate(id: 'candidate-stable');
      await harness.candidates.save(
        candidate,
        expectedRevision: 0,
        cancellation: open,
      );
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );

      await harness.controller.confirmCandidate(candidate);

      final active = await harness.working.list(cancellation: open);
      expect(active.single.id, MemoryEntryId('memory-entry-candidate-stable'));
      harness.dispose();
    });

    test('confirmation revises the targeted entry', () async {
      final harness = _Harness();
      final target = workingEntry(
        id: 'entry-target',
        content: 'Old content.',
        sourceValues: const <String>['old-source'],
      );
      await harness.seedEntry(harness.working, target);
      final candidate = updateCandidate(
        id: 'candidate-update',
        targetEntryId: target.id,
        content: 'New content.',
        sourceValues: const <String>['new-source'],
      );
      await harness.candidates.save(
        candidate,
        expectedRevision: 0,
        cancellation: open,
      );
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );

      await harness.controller.confirmCandidate(candidate);

      final revised = await harness.working.load(target.id, cancellation: open);
      expect(revised!.revision, 1);
      expect(revised.content, 'New content.');
      expect(revised.sourceIds.map((source) => source.value), <String>[
        'old-source',
        'new-source',
      ]);
      expect(
        revised.supersedesEntryId,
        isNull,
        reason: 'an update revises the same identity in place',
      );
      harness.dispose();
    });

    test('edit and reject transition the candidate', () async {
      final harness = _Harness();
      final candidate = createCandidate(id: 'candidate-edit');
      await harness.candidates.save(
        candidate,
        expectedRevision: 0,
        cancellation: open,
      );
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );

      await harness.controller.editCandidate(
        candidate,
        content: 'Edited content.',
      );
      final edited = await harness.candidates.load(
        candidate.id,
        cancellation: open,
      );
      expect(edited!.content, 'Edited content.');
      expect(edited.revision, 1);

      await harness.controller.rejectCandidate(edited);
      expect(
        await harness.candidates.list(
          status: MemoryCandidateStatus.pending,
          cancellation: open,
        ),
        isEmpty,
      );
      harness.dispose();
    });

    test('forget removes the entry from the active view', () async {
      final harness = _Harness();
      final entry = workingEntry();
      await harness.seedEntry(harness.working, entry);
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );

      await harness.controller.forgetEntry(entry);

      expect(await harness.working.list(cancellation: open), isEmpty);
      final forgotten = await harness.working.load(
        entry.id,
        cancellation: open,
      );
      expect(forgotten!.isForgotten, isTrue);
      harness.dispose();
    });

    test('edit revises a confirmed entry in place', () async {
      final harness = _Harness();
      final entry = workingEntry();
      await harness.seedEntry(harness.working, entry);
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );

      await harness.controller.editEntry(
        entry,
        content: 'Revised working fact.',
        kind: MemoryKind.decision,
      );

      final revised = await harness.working.load(entry.id, cancellation: open);
      expect(revised!.revision, 1);
      expect(revised.content, 'Revised working fact.');
      expect(revised.kind, MemoryKind.decision);
      harness.dispose();
    });

    test('clear forgets only the selected memory surface', () async {
      final harness = _Harness();
      final current = workingEntry(id: 'working-current');
      final other = workingEntry(
        id: 'working-other',
        project: 'project-2',
        sourceValues: const <String>['other-source'],
      );
      final global = longTermEntry(id: 'longterm-global');
      final candidate = createCandidate(id: 'candidate-pending');
      await harness.seedEntry(harness.working, current);
      await harness.seedEntry(harness.working, other);
      await harness.seedEntry(harness.longTerm, global);
      await harness.candidates.save(
        candidate,
        expectedRevision: 0,
        cancellation: open,
      );
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );

      await harness.controller.clearLayer(MemoryLayerView.working);
      expect(
        await harness.working.list(projectId: projectId, cancellation: open),
        isEmpty,
      );
      expect(
        await harness.working.list(
          projectId: ProjectId('project-2'),
          cancellation: open,
        ),
        <MemoryEntry>[other],
      );
      expect(await harness.longTerm.list(cancellation: open), <MemoryEntry>[
        global,
      ]);

      await harness.controller.clearLayer(MemoryLayerView.longTerm);
      expect(await harness.longTerm.list(cancellation: open), isEmpty);

      await harness.controller.clearLayer(MemoryLayerView.candidates);
      expect(
        await harness.candidates.list(
          status: MemoryCandidateStatus.pending,
          cancellation: open,
        ),
        isEmpty,
      );
      expect(
        await harness.candidates.list(
          status: MemoryCandidateStatus.rejected,
          cancellation: open,
        ),
        hasLength(1),
      );
      harness.dispose();
    });

    test('read toggles update the state and trace', () async {
      final harness = _Harness();
      await harness.seedEntry(harness.working, workingEntry());
      await harness.seedEntry(harness.longTerm, longTermEntry());
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );
      expect(harness.controller.state.trace!.includedRecords, hasLength(2));

      await harness.controller.setIncludeLongTerm(false);

      final state = harness.controller.state;
      expect(state.includeLongTerm, isFalse);
      expect(harness.toggles.includeLongTerm, isFalse);
      final disabled = state.trace!.records.singleWhere(
        (record) => record.layer == MemoryLayer.longTerm,
      );
      expect(disabled.included, isFalse);
      expect(disabled.reason, MemoryReadReason.layerDisabled);
      expect(state.trace!.includedRecords, hasLength(1));
      harness.dispose();
    });

    test('analyze now runs extraction and surfaces candidates', () async {
      final harness = _Harness();
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );

      await harness.controller.analyzeNow();

      expect(harness.extractor.calls, 1);
      expect(
        harness.controller.state.extractionStatus,
        MemoryExtractionStatus.extracted,
      );
      expect(harness.controller.state.candidates, isNotEmpty);
      harness.dispose();
    });

    test('pause and resume bridge the foreground lifecycle', () async {
      final harness = _Harness();
      await harness.controller.attachSession(
        session: _snapshot(),
        projectId: projectId,
      );
      final sessionId = harness.controller.state.sessionId!;
      await harness.extraction.onCompletedTurn(
        sessionId: sessionId,
        projectId: projectId,
        completedSources: <MemoryExtractionSource>[
          MemoryExtractionSource(
            id: MemorySourceId('m0'),
            role: MemoryTranscriptRole.user,
            text: 'Deployment uses kubernetes.',
          ),
          MemoryExtractionSource(
            id: MemorySourceId('m1'),
            role: MemoryTranscriptRole.assistant,
            text: 'Understood.',
          ),
        ],
      );

      harness.controller.pauseExtraction();
      expect(harness.extraction.isPaused(sessionId), isTrue);

      harness.clock.elapse(const Duration(minutes: 30));
      await harness.controller.resumeExtraction();

      expect(harness.extraction.isPaused(sessionId), isFalse);
      expect(harness.extractor.calls, 1);
      expect(harness.controller.state.candidates, isNotEmpty);
      harness.dispose();
    });
  });
}

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/memory_fixtures.dart';

bool _messageContains(LlmMessage message, String text) => message.parts
    .whereType<LlmTextPart>()
    .any((part) => part.text.contains(text));

bool _transcriptContains(AgentTranscript transcript, String text) =>
    transcript.messages.any((message) => _messageContains(message, text));

final class _MarkerProvider implements AgentDynamicContextProvider {
  _MarkerProvider(this.marker);

  final String marker;
  final List<AgentDynamicContextRequest> requests =
      <AgentDynamicContextRequest>[];

  @override
  Future<AgentDynamicContext?> provide(
    AgentDynamicContextRequest request,
  ) async {
    requests.add(request);
    return AgentDynamicContext(
      systemPromptText: marker,
      audit: <String, Object?>{'marker': marker},
    );
  }
}

final class _CapturingCompactor implements AgentHistoryCompactor {
  final List<LlmRequestSnapshot> requests = <LlmRequestSnapshot>[];

  @override
  String get id => 'capturing-compactor';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    requests.add(context.request);
    return AgentCompactionNoChange(
      strategyId: id,
      strategyVersion: version,
      reports: const <AgentCompactionInvocationReport>[],
    );
  }
}

Future<MemoryDynamicContextProvider> _memoryProvider({
  List<MemoryEntry> working = const <MemoryEntry>[],
  List<MemoryEntry> longTerm = const <MemoryEntry>[],
  bool includeWorking = true,
  bool includeLongTerm = true,
  int characterBudget = defaultMemoryCharacterBudget,
}) async {
  final workingRepository = InMemoryMemoryEntryRepository(
    layer: MemoryLayer.working,
  );
  final longTermRepository = InMemoryMemoryEntryRepository(
    layer: MemoryLayer.longTerm,
  );
  final cancellation = CancellationSource().token;
  for (final entry in working) {
    await workingRepository.save(
      entry,
      expectedRevision: 0,
      cancellation: cancellation,
    );
  }
  for (final entry in longTerm) {
    await longTermRepository.save(
      entry,
      expectedRevision: 0,
      cancellation: cancellation,
    );
  }
  return MemoryDynamicContextProvider(
    retrieval: LayeredMemoryRetrievalService(
      repositories: MemoryRepositories(
        workingRepository: workingRepository,
        longTermRepository: longTermRepository,
        candidateRepository: InMemoryMemoryCandidateRepository(),
      ),
    ),
    includeWorking: includeWorking,
    includeLongTerm: includeLongTerm,
    characterBudget: characterBudget,
  );
}

QueueScriptedLlmProvider _provider(List<List<LlmEvent>> turns) {
  return QueueScriptedLlmProvider(
    id: BuiltInLlmCatalog.deepSeek,
    wireFamily: LlmWireFamily.openaiChatCompletions,
    turns: turns,
  );
}

void main() {
  group('agent runtime dynamic memory context', () {
    test(
      'supplies retrieved memory to the provider and not the transcript',
      () async {
        final provider = _provider(<List<LlmEvent>>[textTurn('answer')]);
        final runtime = testRuntime(
          provider: provider,
          dynamicContextProvider: await _memoryProvider(
            working: <MemoryEntry>[workingEntry()],
          ),
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(projectId: ProjectId('project-1'));

        final events = await session
            .run('what does the user require?')
            .events
            .toList();

        expect(events.last, isA<AgentRunCompleted>());
        final request = provider.requests.single;
        expect(
          request.context.systemPrompt,
          contains(memorySystemPromptHeader),
        );
        expect(
          request.context.systemPrompt,
          contains('Retrieval must be deterministic.'),
        );

        final contextEvent = events
            .whereType<AgentDynamicContextEvent>()
            .single;
        final trace = contextEvent.audit;
        expect(trace, isA<MemoryContextTrace>());
        final memoryTrace = trace! as MemoryContextTrace;
        expect(
          memoryTrace.includedRecords.single.entryId.value,
          'entry-working-1',
        );
        expect(contextEvent.systemPromptText, contains('<memory>'));
        expect(
          memoryTrace.renderedCharacters,
          contextEvent.systemPromptText.runes.length,
        );

        expect(
          _transcriptContains(
            session.snapshot.transcript,
            'Retrieval must be deterministic.',
          ),
          isFalse,
          reason: 'memory must never be appended to the transcript',
        );
        await session.close();
        await runtime.close();
      },
    );

    test('draws project/global layers and honours read toggles', () async {
      final provider = _provider(<List<LlmEvent>>[
        textTurn('answer'),
        textTurn('answer two'),
      ]);
      final runtime = testRuntime(
        provider: provider,
        dynamicContextProvider: await _memoryProvider(
          working: <MemoryEntry>[workingEntry()],
          longTerm: <MemoryEntry>[
            longTermEntry(kind: MemoryKind.fact, content: 'Global facts only.'),
          ],
        ),
      );
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        projectId: ProjectId('project-1'),
      );

      await session.run('first').events.drain<void>();
      expect(
        provider.requests.single.context.systemPrompt,
        contains('Retrieval must be deterministic.'),
      );
      await session.close();

      final disabled = testRuntime(
        provider: provider,
        dynamicContextProvider: await _memoryProvider(
          working: <MemoryEntry>[workingEntry()],
          longTerm: <MemoryEntry>[
            longTermEntry(kind: MemoryKind.fact, content: 'Global facts only.'),
          ],
          includeWorking: false,
          includeLongTerm: false,
        ),
      );
      final disabledSession = await disabled
          .agent(testDefinition())
          .createSession(projectId: ProjectId('project-1'));
      final events = await disabledSession.run('second').events.toList();
      expect(
        provider.requests.last.context.systemPrompt,
        'You are a test agent.',
      );
      expect(events.whereType<AgentDynamicContextEvent>(), isEmpty);
      await disabledSession.close();
      await runtime.close();
      await disabled.close();
    });

    test('never feeds memory into compaction input', () async {
      const marker = 'MEMORY-MARKER-must-not-enter-compaction';
      final compactor = _CapturingCompactor();
      final provider = _provider(<List<LlmEvent>>[textTurn('answer')]);
      final runtime = testRuntime(
        provider: provider,
        dynamicContextProvider: _MarkerProvider(marker),
        historyCompactor: compactor,
      );
      final session = await runtime
          .agent(testDefinition())
          .createSession(projectId: ProjectId('project-1'));

      await session.run('hello').events.drain<void>();
      expect(provider.requests.single.context.systemPrompt, contains(marker));

      final operation = session.compact();
      await operation.events.drain<void>();
      await operation.result;

      expect(compactor.requests, isNotEmpty);
      final compactionRequest = compactor.requests.last;
      expect(compactionRequest.context.systemPrompt, isNot(contains(marker)));
      expect(
        compactionRequest.context.messages.any(
          (message) => _messageContains(message, marker),
        ),
        isFalse,
      );
      expect(
        provider.requests.where(
          (request) => request.context.systemPrompt?.contains(marker) ?? false,
        ),
        hasLength(1),
        reason: 'only the ordinary provider turn may carry memory',
      );
      await session.close();
      await runtime.close();
    });

    test(
      're-resolves memory after a model switch without touching history',
      () async {
        const marker = 'MEMORY-MARKER-after-switch';
        final provider = _provider(<List<LlmEvent>>[
          textTurn('first answer'),
          textTurn('second answer'),
        ]);
        final runtime = testRuntime(
          provider: provider,
          dynamicContextProvider: _MarkerProvider(marker),
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(projectId: ProjectId('project-1'));

        await session.run('one').events.drain<void>();
        expect(provider.requests.last.context.systemPrompt, contains(marker));

        final switched = await session.changeSelection(
          AgentSessionSelection(
            model: BuiltInLlmCatalog.deepSeekV4ProModel.ref,
            reasoningMode: ReasoningMode.disabled,
            reasoningEffort: ReasoningEffort.modelDefault,
          ),
        );
        expect(switched.status, AgentSessionSelectionStatus.changed);

        await session.run('two').events.drain<void>();
        expect(
          provider.requests.last.model,
          BuiltInLlmCatalog.deepSeekV4ProModel.ref,
        );
        expect(provider.requests.last.context.systemPrompt, contains(marker));
        expect(
          _transcriptContains(session.snapshot.transcript, marker),
          isFalse,
        );
        await session.close();
        await runtime.close();
      },
    );
  });
}

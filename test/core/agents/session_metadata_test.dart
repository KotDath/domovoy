import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/scripted_llm_provider.dart';

void main() {
  group('durable session metadata', () {
    test('current record round-trips selection/title and legacy derives', () {
      final selection = AgentSessionSelection(
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        reasoningMode: ReasoningMode.disabled,
        reasoningEffort: ReasoningEffort.modelDefault,
      );
      final record = _record(selection: selection, title: 'Stable title');
      const codec = AgentSessionCodec();
      final encoded = codec.encode(record);
      expect(encoded['version'], AgentSessionRecord.currentJsonVersion);
      expect(encoded['selection'], isA<Map<Object?, Object?>>());
      expect(encoded['title'], 'Stable title');
      expect(codec.decode(encoded), record);

      final legacy = Map<String, Object?>.from(encoded)
        ..['version'] = AgentSessionRecord.legacyJsonVersion
        ..remove('selection')
        ..remove('title');
      final decoded = codec.decode(legacy);
      expect(
        decoded.selection,
        AgentSessionSelection.fromDefinition(record.definition),
      );
      expect(decoded.title, isNull);
    });

    test('current codec rejects missing/malformed selection and title', () {
      const codec = AgentSessionCodec();
      final encoded = Map<String, Object?>.from(codec.encode(_record()));
      expect(
        () => codec.decode(
          Map<String, Object?>.from(encoded)..remove('selection'),
        ),
        throwsA(anyOf(isA<LlmException>(), isA<AgentException>())),
      );
      final malformedSelection = Map<String, Object?>.from(encoded);
      malformedSelection['selection'] = <String, Object?>{
        'type': AgentSessionSelection.jsonType,
        'version': 1,
        'model': BuiltInLlmCatalog.deepSeekV4FlashModel.ref.toJson(),
        'reasoningMode': 'sometimes',
        'reasoningEffort': 'modelDefault',
      };
      expect(
        () => codec.decode(malformedSelection),
        throwsA(anyOf(isA<LlmException>(), isA<AgentException>())),
      );
      expect(
        () => codec.decode(
          Map<String, Object?>.from(encoded)..['title'] = ' bad\n title ',
        ),
        throwsA(isA<AgentException>()),
      );
    });

    test('continuation origin must match current selection', () {
      final assistant = LlmMessage(
        role: LlmMessageRole.assistant,
        parts: <LlmContentPart>[
          LlmToolCallPart(
            callId: ToolCallId('call-1'),
            name: 'lookup',
            arguments: '{}',
          ),
        ],
      );
      expect(
        () => AgentSessionRecord(
          id: AgentSessionId('contradiction'),
          revision: 1,
          definition: testDefinition(),
          selection: AgentSessionSelection(
            model: BuiltInLlmCatalog.gpt54Model.ref,
            reasoningMode: ReasoningMode.enabled,
            reasoningEffort: ReasoningEffort.modelDefault,
          ),
          transcript: AgentTranscript(
            messages: <LlmMessage>[
              LlmMessage(
                role: LlmMessageRole.user,
                parts: <LlmContentPart>[LlmTextPart('question')],
              ),
              assistant,
            ],
          ),
          usage: LlmUsage(),
          modelTurns: 1,
          toolAttempts: 0,
          createdAtMicros: 1,
          updatedAtMicros: 2,
          continuationEntries: <LlmContinuationEntry>[
            LlmContinuationEntry(
              assistantMessageIndex: 1,
              state: LlmProviderTurnState(
                origin: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
                wireFamily: LlmWireFamily.openaiResponses,
                format: openaiResponsesOutputItemsV1,
                payload: <Map<String, Object?>>[
                  <String, Object?>{
                    'type': 'function_call',
                    'id': 'fc-1',
                    'call_id': 'call-1',
                    'name': 'lookup',
                    'arguments': '{}',
                  },
                ],
              ),
            ),
          ],
        ),
        throwsA(isA<AgentException>()),
      );
    });

    test('title policy normalizes controls/Unicode space and graphemes', () {
      final policy = DeterministicAgentSessionTitlePolicy(maxGraphemes: 6);
      expect(
        policy.deriveTitle(_user('\u0000  hello\u00a0\u2003world  ')),
        'hello…',
      );
      final emojiPolicy = DeterministicAgentSessionTitlePolicy(maxGraphemes: 4);
      expect(
        emojiPolicy.deriveTitle(
          _user('👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦'),
        ),
        '👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦…',
      );
      expect(
        DeterministicAgentSessionTitlePolicy(
          maxGraphemes: 3,
        ).deriveTitle(_user('e\u0301e\u0301e\u0301')),
        'ééé',
      );
    });

    test(
      'first productive save owns title and failed save exposes none',
      () async {
        final repository = _CountingRepository(failOnSave: 2);
        final runtime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[textTurn('unused')],
          ),
          repository: repository,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final events = await session
            .run(
              '  first   message  ',
              titlePolicy: DeterministicAgentSessionTitlePolicy(),
            )
            .events
            .toList();
        expect(events.last, isA<AgentRunFailed>());
        expect(
          (runtime.registry.requireProvider(BuiltInLlmCatalog.deepSeek)
                  as QueueScriptedLlmProvider)
              .requests,
          isEmpty,
        );
        expect(session.snapshot.title, isNull);
        expect((await repository.load(session.id))!.title, isNull);
      },
    );

    test(
      'title is one-time metadata and survives later snapshot rewrites',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('one'), textTurn('two')],
        );
        final repository = _CountingRepository();
        final runtime = testRuntime(provider: provider, repository: repository);
        final agent = runtime.agent(testDefinition());
        final session = await agent.createSession(
          persistence: SessionPersistence.repository,
        );
        final policy = DeterministicAgentSessionTitlePolicy(maxGraphemes: 12);
        await session
            .run(' First   durable title ', titlePolicy: policy)
            .events
            .drain<void>();
        final title = session.snapshot.title;
        expect(title, 'First durab…');
        await session
            .run('a different title', titlePolicy: policy)
            .events
            .drain<void>();
        expect(session.snapshot.title, title);
        final compactedShape = (await repository.load(session.id))!.copyWith(
          transcript: AgentTranscript(),
          tokenAccounting: AgentTokenAccountingState.legacy(
            transcriptMessageCount: 0,
            usage: session.snapshot.usage,
          ),
        );
        expect(compactedShape.title, title);
        await session.close();
        final restored = await agent.restoreSession(session.id);
        expect(restored.snapshot.title, title);
        await restored.close();
      },
    );
  });

  group('current session selection', () {
    test(
      'no-op is side-effect free and reasoning successor restores',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('ok')],
        );
        final repository = _CountingRepository();
        final runtime = testRuntime(provider: provider, repository: repository);
        final agent = runtime.agent(testDefinition());
        final session = await agent.createSession(
          persistence: SessionPersistence.repository,
        );
        final initial = session.snapshot;
        final noOp = await session.changeSelection(initial.selection);
        expect(noOp.status, AgentSessionSelectionStatus.unchanged);
        expect(repository.saves, 1);
        expect(session.snapshot.revision, 0);

        final changed = await session.changeSelection(
          AgentSessionSelection(
            model: initial.selection.model,
            reasoningMode: ReasoningMode.disabled,
            reasoningEffort: ReasoningEffort.modelDefault,
          ),
        );
        expect(changed.status, AgentSessionSelectionStatus.changed);
        expect(repository.saves, 2);
        expect(session.snapshot.revision, 1);
        await session.run('next').events.drain<void>();
        expect(
          provider.requests.single.generation.reasoningMode,
          ReasoningMode.disabled,
        );
        await session.close();
        final restored = await agent.restoreSession(session.id);
        expect(restored.snapshot.selection, changed.selection);
        await restored.close();
      },
    );

    test('busy and invalid changes do not mutate a frozen run', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final repository = _CountingRepository();
      final runtime = testRuntime(provider: provider, repository: repository);
      final session = await runtime
          .agent(testDefinition())
          .createSession(persistence: SessionPersistence.repository);
      final run = session.run('go');
      final eventsFuture = run.events.toList();
      await _waitUntil(() => provider.requests.isNotEmpty);
      final requested = AgentSessionSelection(
        model: session.snapshot.selection.model,
        reasoningMode: ReasoningMode.disabled,
        reasoningEffort: ReasoningEffort.modelDefault,
      );
      final busy = await session.changeSelection(requested);
      expect(busy.status, AgentSessionSelectionStatus.busy);
      expect(busy.activeOperation, AgentSessionOperationKind.run);
      expect(
        provider.requests.single.generation.reasoningMode,
        ReasoningMode.enabled,
      );
      gate.complete();
      await eventsFuture;

      final invalid = await session.changeSelection(
        AgentSessionSelection(
          model: session.snapshot.selection.model,
          reasoningMode: ReasoningMode.disabled,
          reasoningEffort: ReasoningEffort.high,
        ),
      );
      expect(invalid.status, AgentSessionSelectionStatus.error);
      expect(repository.saves, greaterThan(1));
      expect(session.snapshot.selection, isNot(requested));
      await session.close();
    });
  });
}

AgentSessionRecord _record({AgentSessionSelection? selection, String? title}) =>
    AgentSessionRecord(
      id: AgentSessionId('metadata'),
      revision: 0,
      definition: testDefinition(),
      selection: selection,
      title: title,
      transcript: AgentTranscript(),
      usage: LlmUsage(),
      modelTurns: 0,
      toolAttempts: 0,
      createdAtMicros: 1,
      updatedAtMicros: 1,
    );

LlmMessage _user(String value) => LlmMessage(
  role: LlmMessageRole.user,
  parts: <LlmContentPart>[LlmTextPart(value)],
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var index = 0; index < 100 && !condition(); index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

final class _CountingRepository implements AgentSessionRepository {
  _CountingRepository({this.failOnSave});

  final int? failOnSave;
  final InMemoryAgentSessionRepository delegate =
      InMemoryAgentSessionRepository();
  var saves = 0;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => delegate.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    saves += 1;
    if (saves == failOnSave) {
      throw AgentException(sanitizedPersistenceError());
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

import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/scripted_llm_provider.dart';

void main() {
  group('session records and repository', () {
    test('codec round-trips records without secrets or runtime objects', () {
      final record = AgentSessionRecord(
        id: AgentSessionId('s1'),
        revision: 1,
        definition: testDefinition(),
        transcript: AgentTranscript(
          messages: <LlmMessage>[
            LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('hi')],
            ),
          ],
        ),
        usage: LlmUsage(totalTokens: 4),
        modelTurns: 1,
        toolAttempts: 0,
        createdAtMicros: 1,
        updatedAtMicros: 2,
      );
      const codec = AgentSessionCodec();
      final decoded = codec.decode(codec.encode(record));
      expect(decoded, record);
      expect(codec.encode(record).toString(), isNot(contains('sk-')));
    });

    test('optimistic save detects revision conflicts', () async {
      final repo = InMemoryAgentSessionRepository();
      final first = AgentSessionRecord(
        id: AgentSessionId('s1'),
        revision: 0,
        definition: testDefinition(),
        transcript: AgentTranscript(),
        usage: LlmUsage(),
        modelTurns: 0,
        toolAttempts: 0,
        createdAtMicros: 1,
        updatedAtMicros: 1,
      );
      await repo.save(first, expectedRevision: 0, cancellation: _openToken());
      await repo.save(
        first.copyWith(revision: 1),
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      await expectLater(
        repo.save(
          first.copyWith(revision: 1, modelTurns: 9),
          expectedRevision: 0,
          cancellation: _openToken(),
        ),
        throwsA(isA<AgentException>()),
      );
    });

    test('save cancelled before commit does not write', () async {
      final repo = InMemoryAgentSessionRepository();
      final cancelled = CancellationSource()..cancel();
      final record = AgentSessionRecord(
        id: AgentSessionId('s1'),
        revision: 0,
        definition: testDefinition(),
        transcript: AgentTranscript(),
        usage: LlmUsage(),
        modelTurns: 0,
        toolAttempts: 0,
        createdAtMicros: 1,
        updatedAtMicros: 1,
      );
      await expectLater(
        repo.save(record, expectedRevision: 0, cancellation: cancelled.token),
        throwsA(
          isA<AgentException>().having(
            (error) => error.error.kind,
            'kind',
            AgentErrorKind.cancelled,
          ),
        ),
      );
      expect(await repo.load(record.id), isNull);
    });

    test('save commit wins a later cancellation', () async {
      final repo = _CommitWinsRepository();
      final source = CancellationSource();
      final record = AgentSessionRecord(
        id: AgentSessionId('s1'),
        revision: 0,
        definition: testDefinition(),
        transcript: AgentTranscript(),
        usage: LlmUsage(),
        modelTurns: 0,
        toolAttempts: 0,
        createdAtMicros: 1,
        updatedAtMicros: 1,
      );
      final future = repo.save(
        record,
        expectedRevision: 0,
        cancellation: source.token,
      );
      repo.hold.complete();
      await Future<void>.delayed(Duration.zero);
      expect(repo.writes, 1);
      source.cancel();
      repo.afterCommit.complete();
      await future;
      expect(await repo.load(record.id), isNotNull);
    });

    test('persistence shutdown budget is strictly positive', () {
      expect(
        AgentPersistencePolicy.defaultCancellationGracePeriod,
        const Duration(seconds: 5),
      );
      expect(
        () => AgentPersistencePolicy(cancellationGracePeriod: Duration.zero),
        throwsA(isA<AgentException>()),
      );
    });

    test(
      'cancel healthy repository run then second run completes and restore matches',
      () async {
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: <LlmEvent>[
            const LlmTextDelta('ok'),
            LlmUsageUpdate(LlmUsage(totalTokens: 6)),
          ],
          gate: gate,
        );
        final runtime = testRuntime(provider: provider);
        final agent = runtime.agent(testDefinition());
        final session = await agent.createSession(
          persistence: SessionPersistence.repository,
        );
        final first = session.run('one');
        await Future<void>.delayed(Duration.zero);
        await first.cancel();
        final cancelled = await first.events.toList();
        expect(cancelled.last, isA<AgentRunCancelled>());
        expect(session.lifecycle, AgentSessionLifecycle.idle);
        gate.complete();
        final second = await session.run('two').events.toList();
        expect(second.last, isA<AgentRunCompleted>());
        expect(session.snapshot.modelTurns, greaterThan(0));
        final usage = session.snapshot.usage;
        await session.close();
        final restored = await agent.restoreSession(session.id);
        expect(restored.snapshot.modelTurns, session.snapshot.modelTurns);
        expect(restored.snapshot.usage, usage);
        expect(restored.snapshot.transcript.messages, isNotEmpty);
        await restored.close();
      },
    );

    test('close after completed run restores usage and counters', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          textTurn('done', usage: LlmUsage(totalTokens: 9)),
        ],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      final events = await session.run('hello').events.toList();
      expect(events.last, isA<AgentRunCompleted>());
      expect(session.snapshot.usage.totalTokens, 9);
      expect(session.snapshot.modelTurns, 1);
      await session.close();
      final restored = await agent.restoreSession(session.id);
      expect(restored.snapshot.usage.totalTokens, 9);
      expect(restored.snapshot.modelTurns, 1);
      expect(restored.snapshot.transcript.messages, isNotEmpty);
      await restored.close();
    });

    test(
      'two successful persistent runs restore full transcript usage and counters',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn('first', usage: LlmUsage(totalTokens: 9)),
            textTurn('second', usage: LlmUsage(totalTokens: 7)),
          ],
        );
        final runtime = testRuntime(provider: provider);
        final agent = runtime.agent(testDefinition());
        final session = await agent.createSession(
          persistence: SessionPersistence.repository,
        );
        expect(
          (await session.run('hello').events.toList()).last,
          isA<AgentRunCompleted>(),
        );
        expect(
          (await session.run('again').events.toList()).last,
          isA<AgentRunCompleted>(),
        );
        final snap = session.snapshot;
        expect(snap.transcript.messages, hasLength(greaterThan(2)));
        expect(snap.modelTurns, 2);
        await session.close();
        final restored = await agent.restoreSession(session.id);
        expect(restored.snapshot.transcript, snap.transcript);
        expect(restored.snapshot.usage, snap.usage);
        expect(restored.snapshot.modelTurns, snap.modelTurns);
        expect(restored.snapshot.toolAttempts, snap.toolAttempts);
        await restored.close();
      },
    );

    test('close then restore keeps identity and committed history', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('done')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      await session.run('hello').events.drain<void>();
      final id = session.id;
      await session.close();
      final restored = await agent.restoreSession(id);
      expect(restored.id, id);
      expect(restored.snapshot.transcript.messages, isNotEmpty);
      expect(restored.lifecycle, AgentSessionLifecycle.idle);
      expect(runtime.router.queuedCount(id), 0);
      await restored.close();
    });

    test('restore rejects DeepSeek records with Responses continuation', () {
      expect(
        () => AgentSessionRecord(
          id: AgentSessionId('s-cross'),
          revision: 1,
          definition: testDefinition(),
          transcript: AgentTranscript(
            messages: <LlmMessage>[
              LlmMessage(
                role: LlmMessageRole.user,
                parts: <LlmContentPart>[LlmTextPart('q')],
              ),
              LlmMessage(
                role: LlmMessageRole.assistant,
                parts: <LlmContentPart>[
                  LlmToolCallPart(
                    callId: ToolCallId('call_1'),
                    name: 'lookup',
                    arguments: '{}',
                  ),
                ],
              ),
            ],
          ),
          usage: LlmUsage(),
          modelTurns: 1,
          toolAttempts: 0,
          createdAtMicros: 1,
          updatedAtMicros: 1,
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
                    'id': 'fc_1',
                    'call_id': 'call_1',
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

    test(
      'restore rejects DeepSeek plus Responses continuation before live work',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('ok')],
        );
        final repo = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: repo);
        final agent = runtime.agent(testDefinition());
        final session = await agent.createSession(
          id: AgentSessionId('cross-wire'),
          persistence: SessionPersistence.repository,
        );
        await session.close();
        final stored = await runtime.repository.load(session.id);
        final encoded = Map<String, Object?>.from(
          runtime.codec.encode(stored!),
        );
        encoded['transcript'] = AgentTranscript(
          messages: <LlmMessage>[
            LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('q')],
            ),
            LlmMessage(
              role: LlmMessageRole.assistant,
              parts: <LlmContentPart>[
                LlmToolCallPart(
                  callId: ToolCallId('call_1'),
                  name: 'lookup',
                  arguments: '{}',
                ),
              ],
            ),
          ],
        ).toJson();
        encoded['continuationEntries'] = <Object?>[
          LlmContinuationEntry(
            assistantMessageIndex: 1,
            state: LlmProviderTurnState(
              origin: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
              wireFamily: LlmWireFamily.openaiResponses,
              format: openaiResponsesOutputItemsV1,
              payload: <Map<String, Object?>>[
                <String, Object?>{
                  'type': 'function_call',
                  'id': 'fc_1',
                  'call_id': 'call_1',
                  'name': 'lookup',
                  'arguments': '{}',
                },
              ],
            ),
          ).toJson(),
        ];
        repo.replacePayload(session.id, encoded);
        await expectLater(
          agent.restoreSession(session.id),
          throwsA(isA<AgentException>()),
        );
        expect(runtime.debugPersistenceWaiters(session.id), 0);
      },
    );

    test('live id collision and explicit delete', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        id: AgentSessionId('fixed'),
        persistence: SessionPersistence.repository,
      );
      await expectLater(
        agent.createSession(id: AgentSessionId('fixed')),
        throwsA(isA<AgentException>()),
      );
      await session.close();
      await runtime.repository.delete(session.id);
      expect(await runtime.repository.load(session.id), isNull);
    });

    test(
      'checkpoint failure stops work and does not replay operations',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('secret')],
        );
        final repo = _FailingRepository(failOn: 2);
        final runtime = testRuntime(provider: provider, repository: repo);
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final events = await session.run('go').events.toList();
        expect(events.last, isA<AgentRunFailed>());
        expect(
          (events.last as AgentRunFailed).error.kind,
          AgentErrorKind.persistence,
        );
        expect(session.lifecycle, AgentSessionLifecycle.closed);
      },
    );

    test('initial save failure rolls back live registration', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final repo = _FailOnceRepository();
      final runtime = testRuntime(provider: provider, repository: repo);
      final agent = runtime.agent(testDefinition());
      await expectLater(
        agent.createSession(
          id: AgentSessionId('retry-me'),
          persistence: SessionPersistence.repository,
        ),
        throwsA(isA<AgentException>()),
      );
      final session = await agent.createSession(
        id: AgentSessionId('retry-me'),
        persistence: SessionPersistence.repository,
      );
      expect(session.id.value, 'retry-me');
      await session.close();
    });

    test('malformed restore is rejected before work', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      final id = session.id;
      await session.close();
      await runtime.repository.delete(id);
      await runtime.repository.save(
        AgentSessionRecord(
          id: id,
          revision: 0,
          definition: testDefinition(tools: <ToolId>[ToolId('ghost')]),
          transcript: AgentTranscript(),
          usage: LlmUsage(),
          modelTurns: 0,
          toolAttempts: 0,
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      await expectLater(
        agent.restoreSession(id),
        throwsA(isA<AgentException>()),
      );
    });

    test('terminal checkpoint failure becomes persistence failure', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('done')],
      );
      final repo = _FailingRepository(failOn: 4);
      final runtime = testRuntime(provider: provider, repository: repo);
      final session = await runtime
          .agent(testDefinition())
          .createSession(persistence: SessionPersistence.repository);
      final events = await session.run('go').events.toList();
      expect(events.last, isA<AgentRunFailed>());
      expect(
        (events.last as AgentRunFailed).error.kind,
        AgentErrorKind.persistence,
      );
    });

    test('malformed stored JSON fails at the codec boundary', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final repo = InMemoryAgentSessionRepository();
      final runtime = testRuntime(provider: provider, repository: repo);
      final agent = runtime.agent(testDefinition());
      repo.replacePayload(AgentSessionId('bad'), <String, Object?>{
        'not': 'a record',
      });
      await expectLater(
        agent.restoreSession(AgentSessionId('bad')),
        throwsA(
          isA<AgentException>().having(
            (error) => error.error.kind,
            'kind',
            AgentErrorKind.configuration,
          ),
        ),
      );
      expect(provider.requests, isEmpty);
    });

    test('unknown stored record version fails at the codec boundary', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final repo = InMemoryAgentSessionRepository();
      final runtime = testRuntime(provider: provider, repository: repo);
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      final id = session.id;
      await session.close();
      final stored = await repo.load(id);
      final raw = Map<String, Object?>.from(repo.codec.encode(stored!));
      raw['version'] = 99;
      repo.replacePayload(id, raw);
      await expectLater(
        agent.restoreSession(id),
        throwsA(
          isA<AgentException>().having(
            (error) => error.error.kind,
            'kind',
            AgentErrorKind.configuration,
          ),
        ),
      );
      expect(provider.requests, isEmpty);
    });

    test('restore uses stored definition not the current facade', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final runtime = testRuntime(provider: provider);
      final storedAgent = runtime.agent(
        testDefinition(systemPrompt: 'stored prompt'),
      );
      final session = await storedAgent.createSession(
        persistence: SessionPersistence.repository,
      );
      final id = session.id;
      await session.close();
      final facade = runtime.agent(
        testDefinition(
          systemPrompt: 'facade prompt',
          tools: <ToolId>[ToolId('ghost')],
        ),
      );
      final restored = await facade.restoreSession(id);
      expect(restored.snapshot.definition.systemPrompt, 'stored prompt');
      expect(restored.snapshot.definition.enabledTools, isEmpty);
      await restored.close();
    });

    test('delayed durable checkpoint is awaited past microtasks', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('done')],
      );
      final repo = _DelayedRepository(delayFrom: 2);
      final runtime = testRuntime(provider: provider, repository: repo);
      final session = await runtime
          .agent(testDefinition())
          .createSession(persistence: SessionPersistence.repository);
      final eventsFuture = session.run('go').events.toList();
      var finished = false;
      unawaited(eventsFuture.then((_) => finished = true));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(repo.maxInFlight, 1);
      expect(finished, isFalse);
      final events = await _completeWithReleases(repo, eventsFuture);
      expect(events.last, isA<AgentRunCompleted>());
      expect(session.lifecycle, AgentSessionLifecycle.idle);
      await _completeWithReleases(repo, session.close());
    });

    test(
      'cancel during delayed checkpoint then restore sees committed revision',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('done'), textTurn('retry')],
        );
        final repo = _DelayedRepository(delayFrom: 2);
        final runtime = testRuntime(provider: provider, repository: repo);
        final agent = runtime.agent(testDefinition());
        final session = await agent.createSession(
          persistence: SessionPersistence.repository,
        );
        final run = session.run('go');
        final eventsFuture = run.events.toList();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(repo.maxInFlight, 1);
        await _completeWithReleases(repo, run.cancel());
        final events = await _completeWithReleases(repo, eventsFuture);
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(events.last, isA<AgentRunCancelled>());
        expect(repo.maxInFlight, 1);
        expect(session.lifecycle, AgentSessionLifecycle.idle);
        expect(session.snapshot.usage, isNotNull);
        await _completeWithReleases(repo, session.close());
        final restored = await agent.restoreSession(session.id);
        final retried = await _completeWithReleases(
          repo,
          restored.run('again').events.toList(),
        );
        expect(retried.last, isA<AgentRunCompleted>());
        await _completeWithReleases(repo, restored.close());
      },
    );

    test(
      'timeout during delayed checkpoint retains the reserved reason',
      () async {
        final clock = FakeAgentClock();
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('tick')],
          gate: gate,
        );
        final repo = _DelayedRepository(delayFrom: 2);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final run = session.run(
          'go',
          options: AgentRunOptions(
            maxDuration: const QuotaOverride.value(Duration(minutes: 1)),
          ),
        );
        final eventsFuture = run.events.toList();
        await Future<void>.delayed(Duration.zero);
        clock.elapse(const Duration(minutes: 1));
        await Future<void>.delayed(Duration.zero);
        final events = await _completeWithReleases(repo, eventsFuture);
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(
          (events.last as AgentRunStopped).reason,
          AgentStopReason.durationLimit,
        );
        gate.complete();
        await _completeWithReleases(repo, session.close());
      },
    );

    test('close waits for delayed persistence', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final repo = _DelayedRepository(delayFrom: 2);
      final runtime = testRuntime(provider: provider, repository: repo);
      final session = await runtime
          .agent(testDefinition())
          .createSession(persistence: SessionPersistence.repository);
      session.run('go');
      await Future<void>.delayed(Duration.zero);
      await _completeWithReleases(repo, session.close());
      expect(session.lifecycle, AgentSessionLifecycle.closed);
      gate.complete();
    });

    test('failed cancel flush keeps cancelled terminal and closes', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final repo = _FailingRepository(failOn: 3);
      final runtime = testRuntime(provider: provider, repository: repo);
      final session = await runtime
          .agent(testDefinition())
          .createSession(persistence: SessionPersistence.repository);
      final run = session.run('go');
      await Future<void>.delayed(Duration.zero);
      await run.cancel();
      final events = await run.events.toList();
      expect(events.where((event) => event.isTerminal), hasLength(1));
      expect(events.last, isA<AgentRunCancelled>());
      expect(session.lifecycle, AgentSessionLifecycle.closed);
      gate.complete();
    });

    test(
      'productive checkpoints do not accumulate cancellation registrations',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            for (var i = 0; i < 8; i++) textTurn('turn-$i'),
          ],
        );
        final repo = _RegistrationCountingRepository();
        final runtime = testRuntime(provider: provider, repository: repo);
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        for (var i = 0; i < 8; i++) {
          final events = await session.run('go-$i').events.toList();
          expect(events.last, isA<AgentRunCompleted>());
        }
        expect(repo.liveRegistrations, 0);
        expect(repo.maxLiveRegistrations, 1);
        expect(runtime.debugPersistenceWaiters(session.id), 0);
        expect(
          runtime.debugMaxPersistenceWaiters(session.id),
          lessThanOrEqualTo(2),
        );
        await session.close();
      },
    );

    test(
      'close and run share one shutdown flush even if a second save would hang',
      () async {
        final clock = FakeAgentClock();
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final repo = _SecondFlushHangsRepository(immediateUntil: 2);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        session.run('go');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        final closeFuture = session.close();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(repo.delayedFlushes, 1);
        clock.elapse(const Duration(milliseconds: 4900));
        repo.firstFlush.complete();
        await closeFuture.timeout(const Duration(seconds: 1));
        expect(session.lifecycle, AgentSessionLifecycle.closed);
        expect(repo.delayedFlushes, 1);
        gate.complete();
      },
    );

    test(
      'unsubscribing from events cancels a hanging repository save',
      () async {
        final clock = FakeAgentClock();
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final repo = _HangingRepository(hangFrom: 2);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final run = session.run('go');
        final sub = run.events.listen((_) {});
        await _waitForHang(repo);
        final canceling = sub.cancel();
        var finished = false;
        unawaited(canceling.whenComplete(() => finished = true));
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        expect(session.lifecycle, isNot(AgentSessionLifecycle.closed));
        await _elapseGrace(clock);
        await canceling.timeout(const Duration(seconds: 1));
        expect(finished, isTrue);
        expect(session.lifecycle, AgentSessionLifecycle.closed);
        expect(runtime.isRestoreQuarantined(session.id), isTrue);
        expect(provider.requests, isEmpty);
        gate.complete();
      },
    );

    test(
      'closeAfter teardown error closes the session before cancel throws',
      () async {
        final clock = FakeAgentClock();
        final provider = _ImmediateErrorCancelLlmProvider();
        final repo = _HangingRepository(hangFrom: 3);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final run = session.run('go');
        final started = Completer<void>();
        final sub = run.events.listen((event) {
          if (event is AgentAnswerDelta && !started.isCompleted) {
            started.complete();
          }
        });
        await started.future;
        final canceling = sub.cancel();
        final expected = expectLater(
          canceling,
          throwsA(
            isA<AgentException>().having(
              (error) => error.error.message.toLowerCase(),
              'message',
              isNot(contains('secret')),
            ),
          ),
        );
        await _elapseGrace(clock);
        await expected.timeout(const Duration(seconds: 1));
        expect(session.lifecycle, AgentSessionLifecycle.closed);
      },
    );

    test('never-completing save does not block caller cancel', () async {
      final clock = FakeAgentClock();
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final repo = _HangingRepository(hangFrom: 2);
      final runtime = testRuntime(
        provider: provider,
        repository: repo,
        clock: clock,
      );
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      final run = session.run('go');
      final eventsFuture = run.events.toList();
      await Future<void>.delayed(Duration.zero);
      final cancelFuture = run.cancel();
      await _elapseGrace(clock);
      await cancelFuture.timeout(const Duration(seconds: 1));
      final events = await eventsFuture.timeout(const Duration(seconds: 1));
      expect(events.where((event) => event.isTerminal), hasLength(1));
      expect(events.last, isA<AgentRunCancelled>());
      expect(session.lifecycle, AgentSessionLifecycle.closed);
      expect(runtime.isRestoreQuarantined(session.id), isTrue);
      await expectLater(
        agent.restoreSession(session.id),
        throwsA(isA<AgentException>()),
      );
      final revision = session.snapshot.revision;
      repo.completeHanging();
      await Future<void>.delayed(Duration.zero);
      expect(session.snapshot.revision, revision);
      expect(runtime.isRestoreQuarantined(session.id), isFalse);
      final restored = await agent.restoreSession(session.id);
      expect(restored.snapshot.revision, revision);
      repo.allowHang = false;
      await restored.close();
      gate.complete();
    });

    test('never-completing save does not block timeout or watchdog', () async {
      final clock = FakeAgentClock();
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('tick')],
        gate: gate,
      );
      final repo = _HangingRepository(hangFrom: 2);
      final runtime = testRuntime(
        provider: provider,
        repository: repo,
        clock: clock,
      );
      final session = await runtime
          .agent(
            testDefinition(
              liveness: AgentLivenessPolicy(
                idleTimeout: const Duration(minutes: 10),
              ),
            ),
          )
          .createSession(persistence: SessionPersistence.repository);
      final run = session.run(
        'go',
        options: AgentRunOptions(
          maxDuration: const QuotaOverride.value(Duration(minutes: 1)),
        ),
      );
      final eventsFuture = run.events.toList();
      await Future<void>.delayed(Duration.zero);
      clock.elapse(const Duration(minutes: 1));
      await _elapseGrace(clock);
      final events = await eventsFuture.timeout(const Duration(seconds: 1));
      expect(events.where((event) => event.isTerminal), hasLength(1));
      expect(
        (events.last as AgentRunStopped).reason,
        AgentStopReason.durationLimit,
      );
      expect(session.lifecycle, AgentSessionLifecycle.closed);
      gate.complete();
    });

    test('never-completing save does not block session close', () async {
      final clock = FakeAgentClock();
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final repo = _HangingRepository(hangFrom: 2);
      final runtime = testRuntime(
        provider: provider,
        repository: repo,
        clock: clock,
      );
      final session = await runtime
          .agent(testDefinition())
          .createSession(persistence: SessionPersistence.repository);
      session.run('go');
      await Future<void>.delayed(Duration.zero);
      final closeFuture = expectLater(
        session.close(),
        throwsA(
          isA<AgentException>().having(
            (error) => error.error.kind,
            'kind',
            AgentErrorKind.persistence,
          ),
        ),
      );
      await _elapseGrace(clock);
      await closeFuture.timeout(const Duration(seconds: 1));
      expect(session.lifecycle, AgentSessionLifecycle.closed);
      await expectLater(session.close(), throwsA(isA<AgentException>()));
      gate.complete();
    });

    test(
      'hanging terminal checkpoint is bounded by cancel without a second terminal',
      () async {
        final clock = FakeAgentClock();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('done')],
        );
        final repo = _HangingRepository(hangFrom: 4);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final run = session.run('go');
        final eventsFuture = run.events.toList();
        await _waitForHang(repo);
        final cancelFuture = run.cancel();
        await _elapseGrace(clock);
        await cancelFuture.timeout(const Duration(seconds: 1));
        final events = await eventsFuture.timeout(const Duration(seconds: 1));
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(events.last, isA<AgentRunFailed>());
        expect(
          (events.last as AgentRunFailed).error.kind,
          AgentErrorKind.persistence,
        );
        expect(session.lifecycle, AgentSessionLifecycle.closed);
        final revision = session.snapshot.revision;
        repo.completeHanging();
        await Future<void>.delayed(Duration.zero);
        expect(session.snapshot.revision, revision);
      },
    );

    test(
      'hanging terminal checkpoint is bounded by close without a second terminal',
      () async {
        final clock = FakeAgentClock();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('done')],
        );
        final repo = _HangingRepository(hangFrom: 4);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final run = session.run('go');
        final eventsFuture = run.events.toList();
        await _waitForHang(repo);
        final closeFuture = expectLater(
          session.close(),
          throwsA(isA<AgentException>()),
        );
        await _elapseGrace(clock);
        final events = await eventsFuture.timeout(const Duration(seconds: 1));
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(events.last, isA<AgentRunFailed>());
        await closeFuture.timeout(const Duration(seconds: 1));
        expect(session.lifecycle, AgentSessionLifecycle.closed);
      },
    );

    test(
      'idle close with hanging flush completes without repository release',
      () async {
        final clock = FakeAgentClock();
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('unused')],
        );
        final repo = _HangingRepository(hangFrom: 2);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        expect(session.lifecycle, AgentSessionLifecycle.idle);
        final closeFuture = expectLater(
          session.close(),
          throwsA(isA<AgentException>()),
        );
        await _elapseGrace(clock);
        await closeFuture.timeout(const Duration(seconds: 1));
        expect(session.lifecycle, AgentSessionLifecycle.closed);
        expect(repo.hangingCount, 1);
        final revision = session.snapshot.revision;
        repo.completeHanging();
        await Future<void>.delayed(Duration.zero);
        expect(session.snapshot.revision, revision);
      },
    );

    test(
      'cancel during provider wait with hanging terminal checkpoint is bounded',
      () async {
        final clock = FakeAgentClock();
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final repo = _HangingRepository(hangFrom: 3);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final run = session.run('go');
        final eventsFuture = run.events.toList();
        await Future<void>.delayed(Duration.zero);
        final cancelFuture = run.cancel();
        await _elapseGrace(clock);
        await cancelFuture.timeout(const Duration(seconds: 1));
        final events = await eventsFuture.timeout(const Duration(seconds: 1));
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(events.last, isA<AgentRunCancelled>());
        expect(session.lifecycle, AgentSessionLifecycle.closed);
        expect(repo.hangingCount, 1);
        final revision = session.snapshot.revision;
        repo.failNextHang = true;
        repo.completeHanging();
        await Future<void>.delayed(Duration.zero);
        expect(session.snapshot.revision, revision);
        gate.complete();
      },
    );

    test(
      'close active session with hanging cancellation checkpoint is bounded',
      () async {
        final clock = FakeAgentClock();
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final repo = _HangingRepository(hangFrom: 3);
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
        );
        final session = await runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final run = session.run('go');
        final eventsFuture = run.events.toList();
        await Future<void>.delayed(Duration.zero);
        final closeFuture = expectLater(
          session.close(),
          throwsA(isA<AgentException>()),
        );
        await _elapseGrace(clock);
        final events = await eventsFuture.timeout(const Duration(seconds: 1));
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(events.last, isA<AgentRunCancelled>());
        await closeFuture.timeout(const Duration(seconds: 1));
        expect(session.lifecycle, AgentSessionLifecycle.closed);
        expect(repo.hangingCount, 1);
        final revision = session.snapshot.revision;
        repo.completeHanging();
        await Future<void>.delayed(Duration.zero);
        expect(session.snapshot.revision, revision);
        gate.complete();
      },
    );

    test('never-completing save does not block idle watchdog', () async {
      final clock = FakeAgentClock();
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('tick')],
        gate: gate,
      );
      final repo = _HangingRepository(hangFrom: 2);
      final runtime = testRuntime(
        provider: provider,
        repository: repo,
        clock: clock,
      );
      final session = await runtime
          .agent(
            testDefinition(
              liveness: AgentLivenessPolicy(
                idleTimeout: const Duration(minutes: 1),
              ),
            ),
          )
          .createSession(persistence: SessionPersistence.repository);
      final run = session.run('go');
      final eventsFuture = run.events.toList();
      await Future<void>.delayed(Duration.zero);
      clock.elapse(const Duration(minutes: 1));
      await _elapseGrace(clock);
      final events = await eventsFuture.timeout(const Duration(seconds: 1));
      expect(events.where((event) => event.isTerminal), hasLength(1));
      expect(
        (events.last as AgentRunStopped).reason,
        AgentStopReason.idleTimeout,
      );
      expect(session.lifecycle, AgentSessionLifecycle.closed);
      gate.complete();
    });

    test('two sessions from one definition stay independent', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      final first = await agent.createSession();
      final second = await agent.createSession();
      await first.run('one').events.drain<void>();
      await second.run('two').events.drain<void>();
      expect(first.id, isNot(second.id));
      expect(first.snapshot.transcript, isNot(second.snapshot.transcript));
      await first.close();
      await second.close();
    });
  });
}

CancellationToken _openToken() => CancellationSource().token;

Future<void> _waitForHang(_HangingRepository repo) async {
  for (var i = 0; i < 40; i++) {
    if (repo.hangingCount > 0) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('repository save did not hang');
}

Future<void> _elapseGrace(FakeAgentClock clock) async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  clock.elapse(AgentPersistencePolicy.defaultCancellationGracePeriod);
  await Future<void>.delayed(Duration.zero);
}

Future<T> _completeWithReleases<T>(
  _DelayedRepository repo,
  Future<T> future,
) async {
  final done = Completer<T>();
  unawaited(future.then(done.complete, onError: done.completeError));
  for (var i = 0; i < 40 && !done.isCompleted; i++) {
    repo.releaseAll();
    await Future<void>.delayed(Duration.zero);
  }
  return done.future.timeout(const Duration(seconds: 1));
}

final class _FailOnceRepository implements AgentSessionRepository {
  final InMemoryAgentSessionRepository _inner =
      InMemoryAgentSessionRepository();
  var _failed = false;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => _inner.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    if (!_failed) {
      _failed = true;
      throw AgentException(sanitizedPersistenceError());
    }
    return _inner.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(AgentSessionId id) => _inner.delete(id);
}

final class _DelayedRepository implements AgentSessionRepository {
  _DelayedRepository({this.delayFrom = 1});

  final InMemoryAgentSessionRepository _inner =
      InMemoryAgentSessionRepository();
  final int delayFrom;
  var _saves = 0;
  var inFlight = 0;
  var maxInFlight = 0;
  final List<Completer<void>> _gates = <Completer<void>>[];

  int get pending => _gates.where((gate) => !gate.isCompleted).length;

  void releaseAll() {
    for (final gate in _gates) {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => _inner.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _saves += 1;
    if (_saves < delayFrom) {
      if (cancellation.isCancelled) {
        throwAgent(AgentErrorKind.cancelled, 'cancelled');
      }
      return _inner.save(
        record,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
      );
    }
    inFlight += 1;
    if (inFlight > maxInFlight) {
      maxInFlight = inFlight;
    }
    final gate = Completer<void>();
    _gates.add(gate);
    final registration = cancellation.register(() {
      if (!gate.isCompleted) {
        gate.completeError(
          AgentException(
            AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
          ),
        );
      }
    });
    try {
      await gate.future;
      if (cancellation.isCancelled) {
        throwAgent(AgentErrorKind.cancelled, 'cancelled');
      }
      return _inner.save(
        record,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
      );
    } finally {
      registration.dispose();
      inFlight -= 1;
    }
  }

  @override
  Future<void> delete(AgentSessionId id) => _inner.delete(id);
}

final class _HangingRepository implements AgentSessionRepository {
  _HangingRepository({this.hangFrom = 2});

  final InMemoryAgentSessionRepository _inner =
      InMemoryAgentSessionRepository();
  final int hangFrom;
  var allowHang = true;
  var _saves = 0;
  var failNextHang = false;
  final List<Completer<void>> _hangs = <Completer<void>>[];

  int get hangingCount => _hangs.where((gate) => !gate.isCompleted).length;

  void completeHanging() {
    for (final gate in _hangs) {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => _inner.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _saves += 1;
    if (!allowHang || _saves < hangFrom) {
      return _inner.save(
        record,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
      );
    }
    final gate = Completer<void>();
    _hangs.add(gate);
    await gate.future;
    if (failNextHang) {
      throw AgentException(sanitizedPersistenceError());
    }
  }

  @override
  Future<void> delete(AgentSessionId id) => _inner.delete(id);
}

final class _FailingRepository implements AgentSessionRepository {
  _FailingRepository({this.failOn = 2});

  final InMemoryAgentSessionRepository _inner =
      InMemoryAgentSessionRepository();
  final int failOn;
  var _saves = 0;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => _inner.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _saves += 1;
    if (cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    if (_saves >= failOn) {
      throw AgentException(sanitizedPersistenceError());
    }
    return _inner.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(AgentSessionId id) => _inner.delete(id);
}

final class _CommitWinsRepository implements AgentSessionRepository {
  final InMemoryAgentSessionRepository _inner =
      InMemoryAgentSessionRepository();
  final Completer<void> hold = Completer<void>();
  final Completer<void> afterCommit = Completer<void>();
  var writes = 0;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => _inner.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (cancellation.isCancelled) {
      throwAgent(AgentErrorKind.cancelled, 'cancelled');
    }
    await hold.future;
    await _inner.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: CancellationSource().token,
    );
    writes += 1;
    await afterCommit.future;
  }

  @override
  Future<void> delete(AgentSessionId id) => _inner.delete(id);
}

final class _RegistrationCountingRepository implements AgentSessionRepository {
  final InMemoryAgentSessionRepository _inner =
      InMemoryAgentSessionRepository();
  var liveRegistrations = 0;
  var maxLiveRegistrations = 0;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => _inner.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    liveRegistrations += 1;
    if (liveRegistrations > maxLiveRegistrations) {
      maxLiveRegistrations = liveRegistrations;
    }
    final registration = cancellation.register(() {});
    try {
      return await _inner.save(
        record,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
      );
    } finally {
      registration.dispose();
      liveRegistrations -= 1;
    }
  }

  @override
  Future<void> delete(AgentSessionId id) => _inner.delete(id);
}

final class _SecondFlushHangsRepository implements AgentSessionRepository {
  _SecondFlushHangsRepository({this.immediateUntil = 2});

  final InMemoryAgentSessionRepository _inner =
      InMemoryAgentSessionRepository();
  final int immediateUntil;
  var saves = 0;
  var delayedFlushes = 0;
  final Completer<void> firstFlush = Completer<void>();

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => _inner.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    saves += 1;
    if (saves <= immediateUntil) {
      if (cancellation.isCancelled) {
        throwAgent(AgentErrorKind.cancelled, 'cancelled');
      }
      return _inner.save(
        record,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
      );
    }
    delayedFlushes += 1;
    if (delayedFlushes == 1) {
      await firstFlush.future;
      if (cancellation.isCancelled) {
        throwAgent(AgentErrorKind.cancelled, 'cancelled');
      }
      return _inner.save(
        record,
        expectedRevision: expectedRevision,
        cancellation: cancellation,
      );
    }
    await Completer<void>().future;
  }

  @override
  Future<void> delete(AgentSessionId id) => _inner.delete(id);
}

final class _ImmediateErrorCancelLlmProvider implements LlmProvider {
  @override
  ProviderId get id => BuiltInLlmCatalog.deepSeek;

  @override
  LlmWireFamily get wireFamily => LlmWireFamily.openaiChatCompletions;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) {
    late final StreamController<LlmEvent> controller;
    controller = StreamController<LlmEvent>(
      onListen: () {
        controller.add(const LlmTextDelta('partial'));
      },
      onCancel: () => Future<void>.error(StateError('teardown-secret')),
    );
    return controller.stream;
  }
}

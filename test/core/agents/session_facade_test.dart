import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/scripted_llm_provider.dart';

void main() {
  group('agent facade and session lifecycle', () {
    test('one-call run owns a transient session and closes it', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('hello')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      final run = agent.run('  hi  ');
      final events = await run.events.toList();
      expect(events.whereType<AgentAnswerDelta>().single.text, 'hello');
      expect(events.last, isA<AgentRunCompleted>());
      expect(events.where((event) => event.isTerminal), hasLength(1));
      expect(runtime.router.queuedCount(AgentSessionId('unused')), 0);
    });

    test(
      'two one-call runs have distinct sessions and no shared history',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('one'), textTurn('two')],
        );
        final runtime = testRuntime(provider: provider);
        final agent = runtime.agent(testDefinition());
        await agent.run('first').events.drain<void>();
        await agent.run('second').events.drain<void>();
        expect(provider.requests, hasLength(2));
        expect(provider.requests[0].context.messages, hasLength(1));
        expect(provider.requests[1].context.messages, hasLength(1));
        expect(
          (provider.requests[1].context.messages.single.parts.single
                  as LlmTextPart)
              .text,
          'second',
        );
      },
    );

    test('caller-owned session reuses identity and history', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('a'), textTurn('b')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession();
      await session.run('one').events.drain<void>();
      await session.run('two').events.drain<void>();
      expect(session.lifecycle, AgentSessionLifecycle.idle);
      expect(provider.requests[1].context.messages, hasLength(3));
      await session.close();
      expect(session.lifecycle, AgentSessionLifecycle.closed);
      expect(() => session.run('three'), throwsA(isA<AgentException>()));
    });

    test('rejects a concurrent run on the same session', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final runtime = testRuntime(provider: provider);
      final session = await runtime.agent(testDefinition()).createSession();
      final first = session.run('one');
      expect(() => session.run('two'), throwsA(isA<AgentException>()));
      gate.complete();
      await first.events.drain<void>();
      await session.close();
    });

    test(
      'run failure returns caller-owned session to idle for retry',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              LlmFailed(LlmError(kind: LlmErrorKind.provider, message: 'boom')),
            ],
            textTurn('recovered'),
          ],
        );
        final runtime = testRuntime(provider: provider);
        final session = await runtime.agent(testDefinition()).createSession();
        final failed = await session.run('one').events.toList();
        expect(failed.last, isA<AgentRunFailed>());
        expect(session.lifecycle, AgentSessionLifecycle.idle);
        final recovered = await session.run('two').events.toList();
        expect(recovered.last, isA<AgentRunCompleted>());
        await session.close();
      },
    );

    test(
      'close cancels work, is idempotent, and does not delete records',
      () async {
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final runtime = testRuntime(provider: provider);
        final agent = runtime.agent(testDefinition());
        final session = await agent.createSession(
          persistence: SessionPersistence.repository,
        );
        final run = session.run('go');
        await session.close();
        await session.close();
        final events = await run.events.toList();
        expect(events.whereType<AgentRunCancelled>(), isNotEmpty);
        expect(session.lifecycle, AgentSessionLifecycle.closed);
        expect(await runtime.repository.load(session.id), isNotNull);
        gate.complete();
      },
    );

    test('concurrent close awaits the same completion', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final session = await testRuntime(
        provider: provider,
      ).agent(testDefinition()).createSession();
      session.run('go');
      final first = session.close();
      final second = session.close();
      await Future.wait(<Future<void>>[first, second]);
      expect(session.lifecycle, AgentSessionLifecycle.closed);
      gate.complete();
    });

    test('restore rejects a stored record whose id does not match', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final repository = InMemoryAgentSessionRepository();
      final runtime = testRuntime(provider: provider, repository: repository);
      final agent = runtime.agent(testDefinition());
      final session = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      final stored = await repository.load(session.id);
      await session.close();
      repository.replacePayload(
        session.id,
        runtime.codec.encode(stored!.copyWith(revision: stored.revision)),
      );
      final mismatched = AgentSessionRecord(
        id: AgentSessionId('other-session'),
        revision: 0,
        definition: testDefinition(),
        transcript: AgentTranscript(),
        usage: LlmUsage(),
        modelTurns: 0,
        toolAttempts: 0,
        createdAtMicros: 1,
        updatedAtMicros: 1,
      );
      repository.replacePayload(session.id, runtime.codec.encode(mismatched));
      expect(
        () => agent.restoreSession(session.id),
        throwsA(isA<AgentException>()),
      );
    });

    test('runtime close rejects later work and is idempotent', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      await agent.run('hi').events.drain<void>();
      await runtime.close();
      await runtime.close();
      expect(runtime.lifecycle, AgentRuntimeLifecycle.closed);
      expect(
        () => runtime.agent(testDefinition()),
        throwsA(isA<AgentException>()),
      );
    });

    test(
      'immediate one-call cancel before listen yields one cancelled terminal',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('late')],
        );
        final runtime = testRuntime(provider: provider);
        final run = runtime.agent(testDefinition()).run('go');
        await run.cancel();
        final events = await run.events.toList();
        expect(events.where((event) => event.isTerminal), hasLength(1));
        expect(events.last, isA<AgentRunCancelled>());
        expect(provider.requests, isEmpty);
        final followUp = await runtime
            .agent(testDefinition())
            .run('next')
            .events
            .toList();
        expect(followUp.last, isA<AgentRunCompleted>());
      },
    );

    test(
      'one-call unsubscribe waits delayed provider teardown without deadlock',
      () async {
        final provider = _DelayedCancelLlmProvider();
        final runtime = testRuntime(provider: provider);
        final run = runtime.agent(testDefinition()).run('go');
        final started = Completer<void>();
        final sub = run.events.listen((event) {
          if (event is AgentAnswerDelta && !started.isCompleted) {
            started.complete();
          }
        });
        await started.future;
        await sub.cancel().timeout(const Duration(seconds: 2));
        expect(provider.cancelled, isTrue);
        await runtime.close();
        expect(runtime.lifecycle, AgentRuntimeLifecycle.closed);
      },
    );

    test(
      'immediate teardown error is sanitized once for one-call and closes session',
      () async {
        final provider = _DelayedCancelLlmProvider(immediateError: true);
        final runtime = testRuntime(provider: provider);
        final run = runtime.agent(testDefinition()).run('go');
        AgentSessionId? sessionId;
        final started = Completer<void>();
        final sub = run.events.listen((event) {
          if (event is AgentRunStarted) {
            sessionId = event.sessionId;
          }
          if (event is AgentAnswerDelta && !started.isCompleted) {
            started.complete();
          }
        });
        await started.future.timeout(const Duration(seconds: 2));
        await expectLater(
          sub.cancel(),
          throwsA(
            isA<AgentException>().having(
              (error) => error.error.message.toLowerCase(),
              'message',
              isNot(contains('secret')),
            ),
          ),
        );
        expect(sessionId, isNotNull);
        final receipt = await runtime.router.send(
          SessionEnvelope(
            id: MessageId('probe'),
            source: sessionId!,
            target: sessionId!,
            payload: LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('probe')],
            ),
            acceptedAtMicros: 1,
          ),
        );
        expect(receipt.status, DeliveryStatus.rejected);
        expect(
          receipt.rejection,
          anyOf(RejectionReason.closed, RejectionReason.unknown),
        );
        await runtime.close();
        expect(runtime.lifecycle, AgentRuntimeLifecycle.closed);
      },
    );

    test(
      'immediate teardown error is sanitized once for a caller-owned session',
      () async {
        final provider = _DelayedCancelLlmProvider(immediateError: true);
        final runtime = testRuntime(provider: provider);
        final session = await runtime.agent(testDefinition()).createSession();
        final run = session.run('go');
        final started = Completer<void>();
        final sub = run.events.listen((event) {
          if (event is AgentAnswerDelta && !started.isCompleted) {
            started.complete();
          }
        });
        await started.future.timeout(const Duration(seconds: 2));
        await expectLater(
          sub.cancel(),
          throwsA(
            isA<AgentException>().having(
              (error) => error.error.message.toLowerCase(),
              'message',
              isNot(contains('secret')),
            ),
          ),
        );
        await session.close();
        await runtime.close();
      },
    );

    test(
      'one-call cancel awaits inner cancellation and session cleanup',
      () async {
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final runtime = testRuntime(provider: provider);
        final run = runtime.agent(testDefinition()).run('go');
        await Future<void>.delayed(Duration.zero);
        final cancelDone = run.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(cancelDone, isA<Future<void>>());
        gate.complete();
        await cancelDone;
        expect(runtime.router.queuedCount(AgentSessionId('unused')), 0);
      },
    );

    test('awaiting cancel allows an immediate follow-up run', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final session = await testRuntime(
        provider: provider,
      ).agent(testDefinition()).createSession();
      final run = session.run('one');
      final events = <AgentRunEvent>[];
      final sub = run.events.listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await run.cancel();
      expect(events.last, isA<AgentRunCancelled>());
      final count = events.length;
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(events.length, count);
      await sub.cancel();
      final recovered = await session.run('two').events.toList();
      expect(recovered.last, isA<AgentRunCompleted>());
      await session.close();
    });

    test(
      'runtime close cancels live work concurrently with a hanging open',
      () async {
        final clock = FakeAgentClock();
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final repo = _HangingSaveRepository();
        final runtime = testRuntime(
          provider: provider,
          repository: repo,
          clock: clock,
          persistencePolicy: AgentPersistencePolicy(
            cancellationGracePeriod: const Duration(seconds: 5),
          ),
        );
        final live = await runtime.agent(testDefinition()).createSession();
        final run = live.run('go');
        final events = <AgentRunEvent>[];
        final sub = run.events.listen(events.add);
        await Future<void>.delayed(Duration.zero);
        final hanging = runtime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        hanging.ignore();
        await Future<void>.delayed(Duration.zero);
        final closing = runtime.close();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(events.whereType<AgentRunCancelled>(), isNotEmpty);
        clock.elapse(const Duration(seconds: 5));
        await closing;
        expect(runtime.lifecycle, AgentRuntimeLifecycle.closed);
        gate.complete();
        await sub.cancel();
      },
    );

    test('runtime close does not hang on a hanging initial save', () async {
      final clock = FakeAgentClock();
      final repo = _HangingSaveRepository();
      final runtime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('ok')],
        ),
        repository: repo,
        clock: clock,
        persistencePolicy: AgentPersistencePolicy(
          cancellationGracePeriod: const Duration(seconds: 5),
        ),
      );
      final creating = runtime
          .agent(testDefinition())
          .createSession(persistence: SessionPersistence.repository);
      creating.ignore();
      await Future<void>.delayed(Duration.zero);
      final closing = runtime.close();
      clock.elapse(const Duration(seconds: 5));
      await closing;
      expect(runtime.lifecycle, AgentRuntimeLifecycle.closed);
    });

    test('runtime close does not hang on a pending restore load', () async {
      final clock = FakeAgentClock();
      final repo = _HangingLoadRepository();
      final runtime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('ok')],
        ),
        repository: repo,
        clock: clock,
        persistencePolicy: AgentPersistencePolicy(
          cancellationGracePeriod: const Duration(seconds: 5),
        ),
      );
      final restoring = runtime
          .agent(testDefinition())
          .restoreSession(AgentSessionId('missing-yet'));
      restoring.ignore();
      await Future<void>.delayed(Duration.zero);
      final closing = runtime.close();
      clock.elapse(const Duration(seconds: 5));
      await closing;
      expect(runtime.lifecycle, AgentRuntimeLifecycle.closed);
    });
  });
}

final class _HangingSaveRepository implements AgentSessionRepository {
  final Completer<void> gate = Completer<void>();

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) async => null;

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    return gate.future;
  }

  @override
  Future<void> delete(AgentSessionId id) async {}
}

final class _HangingLoadRepository implements AgentSessionRepository {
  final Completer<void> gate = Completer<void>();

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) {
    return gate.future.then((_) => null);
  }

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {}

  @override
  Future<void> delete(AgentSessionId id) async {}
}

final class _DelayedCancelLlmProvider implements LlmProvider {
  _DelayedCancelLlmProvider({this.immediateError = false});

  final bool immediateError;
  var cancelled = false;

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
      onCancel: () {
        if (immediateError) {
          return Future<void>.error(StateError('teardown-secret'));
        }
        return () async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          cancelled = true;
        }();
      },
    );
    return controller.stream;
  }
}

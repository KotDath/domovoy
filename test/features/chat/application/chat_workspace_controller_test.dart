import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/chat/application/chat_workspace_state.dart';
import 'package:domovoy/features/prompt/domain/prompt_workspace.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';
import '../../../support/scripted_llm_provider.dart';

void main() {
  group('chat workspace startup', () {
    test(
      'empty catalog stays actionable and creates no transient session',
      () async {
        final repository = InMemoryAgentSessionRepository();
        final runtime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: const <List<LlmEvent>>[],
          ),
          repository: repository,
        );
        final controller = _controller(runtime, repository, repository);

        expect(
          (await controller.initialize()).status,
          ChatCommandStatus.succeeded,
        );
        expect(controller.state.catalogStatus, ChatCatalogStatus.ready);
        expect(controller.state.isEmpty, isTrue);
        expect(controller.state.selectedSession, isNull);
        expect((await repository.list()).available, isEmpty);
        expect(() => controller.state.chats.clear(), throwsUnsupportedError);
        expect(
          () => controller.state.providerGroups.clear(),
          throwsUnsupportedError,
        );
        await controller.dispose();
        await runtime.close();
      },
    );

    test('catalog failure differs from empty and leaks no raw error', () async {
      final repository = InMemoryAgentSessionRepository();
      final runtime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
        repository: repository,
      );
      final controller = _controller(
        runtime,
        repository,
        _FailingCatalog('secret storage path /home/user/key'),
      );

      final result = await controller.initialize();
      expect(result.status, ChatCommandStatus.failed);
      expect(controller.state.catalogStatus, ChatCatalogStatus.failed);
      expect(controller.state.isEmpty, isFalse);
      expect(controller.state.error!.message, isNot(contains('secret')));
      expect(controller.state.error!.message, isNot(contains('/home')));
      await controller.dispose();
      await runtime.close();
    });

    test(
      'healthy chats restore while sanitized catalog issues remain',
      () async {
        final repository = InMemoryAgentSessionRepository();
        final record = _emptyRecord('healthy');
        await repository.save(
          record,
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        );
        final runtime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: const <List<LlmEvent>>[],
          ),
          repository: repository,
        );
        final issue = AgentSessionCatalogIssue(
          id: AgentSessionId('broken'),
          reason: sanitizedPersistenceError(),
        );
        final controller = _controller(
          runtime,
          repository,
          _FixedCatalog(
            AgentSessionCatalogSnapshot(
              available: <AgentSessionSummary>[summarizeAgentSession(record)],
              issues: <AgentSessionCatalogIssue>[issue],
            ),
          ),
        );

        expect((await controller.initialize()).isSuccess, isTrue);
        expect(controller.state.selectedId, record.id);
        expect(controller.state.catalogIssues, <AgentSessionCatalogIssue>[
          issue,
        ]);
        await controller.dispose();
        await runtime.close();
      },
    );
  });

  group('chat workspace lifecycle and command lane', () {
    test('completed turns notify memory without delaying send', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('remembered answer')],
      );
      final repository = InMemoryAgentSessionRepository();
      final runtime = testRuntime(provider: provider, repository: repository);
      final callbackStarted = Completer<void>();
      final callbackGate = Completer<void>();
      final controller = _controller(
        runtime,
        repository,
        repository,
        onTurnCompleted: (snapshot) async {
          expect(snapshot.transcript.messages, hasLength(2));
          callbackStarted.complete();
          await callbackGate.future;
        },
      );
      await controller.initialize();
      await controller.createChat(id: AgentSessionId('memory-callback'));

      final result = await controller.send('remember this');

      expect(result.isSuccess, isTrue);
      await callbackStarted.future;
      expect(callbackGate.isCompleted, isFalse);
      callbackGate.complete();
      await controller.dispose();
      await runtime.close();
    });

    test(
      'two durable chats send multiple turns and restore exact selection',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn('first answer'),
            textTurn('second answer'),
            textTurn('other answer'),
          ],
        );
        final repository = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: repository);
        final controller = _controller(runtime, repository, repository);
        await controller.initialize();

        expect(
          (await controller.createChat(id: AgentSessionId('first'))).isSuccess,
          isTrue,
        );
        expect((await controller.send('first question')).isSuccess, isTrue);
        expect((await controller.send('follow up')).isSuccess, isTrue);
        expect(provider.requests, hasLength(2));
        expect(provider.requests[1].context.messages, hasLength(3));
        expect(controller.state.liveRun!.terminal, isA<AgentRunCompleted>());
        expect(
          () => controller.state.liveRun!.events.clear(),
          throwsUnsupportedError,
        );

        await controller.createChat(id: AgentSessionId('second'));
        await controller.send('second chat');
        expect(controller.state.chats, hasLength(2));
        expect(
          controller.state.chats
              .singleWhere((summary) => summary.id.value == 'first')
              .title,
          'first question',
        );
        expect(
          controller.state.chats
              .singleWhere((summary) => summary.id.value == 'second')
              .title,
          'second chat',
        );

        await controller.selectChat(AgentSessionId('first'));
        expect(controller.state.selectedId, AgentSessionId('first'));
        expect(
          controller.state.selectedSession!.transcript.messages,
          hasLength(4),
        );
        expect(
          (await repository.load(
            AgentSessionId('second'),
          ))!.transcript.messages,
          hasLength(2),
        );
        expect((await controller.closeSelected()).isSuccess, isTrue);
        expect(controller.state.selectedSession, isNull);
        expect(await repository.load(AgentSessionId('first')), isNotNull);
        await controller.dispose();
        await runtime.close();
      },
    );

    test(
      'racing sends/create/select do not queue and stop stabilizes once',
      () async {
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final repository = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: repository);
        final controller = _controller(runtime, repository, repository);
        await controller.initialize();
        await controller.createChat(id: AgentSessionId('active'));

        final sending = controller.send('admitted');
        await _waitUntil(() => provider.requests.isNotEmpty);
        expect(
          (await controller.send('duplicate')).status,
          ChatCommandStatus.busy,
        );
        expect((await controller.createChat()).status, ChatCommandStatus.busy);
        expect(
          (await controller.selectChat(AgentSessionId('active'))).status,
          ChatCommandStatus.busy,
        );
        final firstStop = controller.stop();
        final secondStop = controller.stop();
        expect((await firstStop).isSuccess, isTrue);
        expect((await secondStop).isSuccess, isTrue);
        expect((await sending).status, ChatCommandStatus.cancelled);
        expect(
          (await controller.stabilize()).status,
          ChatCommandStatus.unchanged,
        );
        expect(provider.requests, hasLength(1));
        final stored = await repository.load(AgentSessionId('active'));
        expect(
          stored!.transcript.messages.where(
            (message) => message.role == LlmMessageRole.user,
          ),
          hasLength(1),
        );
        gate.complete();
        await controller.dispose();
        await runtime.close();
      },
    );

    test('dispose suppresses a late catalog completion', () async {
      final repository = InMemoryAgentSessionRepository();
      final runtime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
        repository: repository,
      );
      final catalog = _DelayedCatalog();
      final controller = _controller(runtime, repository, catalog);
      final initializing = controller.initialize();
      await controller.dispose();
      final disposedGeneration = controller.state.generation;
      catalog.complete(AgentSessionCatalogSnapshot());
      expect((await initializing).status, ChatCommandStatus.disposed);
      expect(controller.state.isDisposed, isTrue);
      expect(controller.state.generation, disposedGeneration);
      expect(controller.state.selectedSession, isNull);
      await runtime.close();
    });

    test(
      'external successor wins and controller restores it after conflict',
      () async {
        final repository = _HeldSaveRepository(holdOnSave: 2);
        final runtime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[textTurn('must not run')],
          ),
          repository: repository,
        );
        final controller = _controller(runtime, repository, repository);
        await controller.initialize();
        await controller.createChat(id: AgentSessionId('conflict'));
        final sending = controller.send('local message');
        await repository.heldSaveStarted;
        final current = await repository.delegate.load(
          AgentSessionId('conflict'),
        );
        final externalSelection = AgentSessionSelection(
          model: current!.selection.model,
          reasoningMode: ReasoningMode.disabled,
          reasoningEffort: ReasoningEffort.modelDefault,
        );
        await repository.delegate.save(
          current.copyWith(
            revision: 1,
            updatedAtMicros: current.updatedAtMicros + 1,
            selection: externalSelection,
          ),
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        );
        repository.releaseHeldSave();

        final result = await sending;
        expect(result.status, ChatCommandStatus.conflict);
        expect(controller.state.selectedId, AgentSessionId('conflict'));
        expect(controller.state.selectedSession!.revision, 1);
        expect(controller.state.selectedSession!.selection, externalSelection);
        expect(controller.state.selectedSession!.transcript.messages, isEmpty);
        expect(result.error!.message, isNot(contains('local message')));
        await controller.dispose();
        await runtime.close();
      },
    );
  });

  group('model switch and confirmed deletion', () {
    test(
      'model switch persists and the next run uses the target model',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('target response')],
        );
        final repository = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: repository);
        final controller = _controller(runtime, repository, repository);
        await controller.initialize();
        await controller.createChat(id: AgentSessionId('switch-chat'));
        final target = AgentSessionSelection(
          model: BuiltInLlmCatalog.deepSeekV4ProModel.ref,
          reasoningMode: ReasoningMode.enabled,
          reasoningEffort: ReasoningEffort.high,
        );

        final switched = await controller.changeSelection(target);

        expect(switched.status, ChatCommandStatus.succeeded);
        expect(controller.state.selectedSession!.selection, target);
        expect(controller.state.chats.single.selection, target);
        expect((await controller.send('use target')).isSuccess, isTrue);
        expect(provider.requests.single.model, target.model);
        expect(
          provider.requests.single.generation.reasoningEffort,
          ReasoningEffort.high,
        );
        expect(
          (await repository.load(AgentSessionId('switch-chat')))!.selection,
          target,
        );
        await controller.dispose();
        await runtime.close();
      },
    );

    test(
      'confirmed selected deletion chooses the next pre-delete neighbor',
      () async {
        final repository = InMemoryAgentSessionRepository();
        final runtime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: const <List<LlmEvent>>[],
          ),
          repository: repository,
        );
        final controller = _controller(runtime, repository, repository);
        await controller.initialize();
        for (final id in <String>['one', 'two', 'three']) {
          await controller.createChat(id: AgentSessionId(id));
        }
        final before = controller.state.chats.map((chat) => chat.id).toList();
        final deleted = before[1];
        await controller.selectChat(deleted);
        final intent = controller.deletionIntentFor(deleted)!;

        final result = await controller.deleteChat(intent);

        expect(result.status, ChatCommandStatus.succeeded);
        expect(await repository.load(deleted), isNull);
        expect(
          controller.state.chats.map((chat) => chat.id),
          isNot(contains(deleted)),
        );
        expect(controller.state.selectedId, before[2]);
        expect(
          (await controller.deleteChat(intent)).status,
          ChatCommandStatus.failed,
        );
        await controller.dispose();
        await runtime.close();
      },
    );

    test(
      'nonselected delete preserves selection and discarded intent is inert',
      () async {
        final repository = InMemoryAgentSessionRepository();
        final runtime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: const <List<LlmEvent>>[],
          ),
          repository: repository,
        );
        final controller = _controller(runtime, repository, repository);
        await controller.initialize();
        await controller.createChat(id: AgentSessionId('selected'));
        await controller.createChat(id: AgentSessionId('other'));
        await controller.selectChat(AgentSessionId('selected'));
        final selected = controller.state.selectedId;
        final discarded = controller.deletionIntentFor(
          AgentSessionId('other'),
        )!;
        controller.discardDeletionIntent(discarded);
        expect(
          (await controller.deleteChat(discarded)).status,
          ChatCommandStatus.failed,
        );
        expect(await repository.load(AgentSessionId('other')), isNotNull);
        final intent = controller.deletionIntentFor(AgentSessionId('other'))!;

        expect((await controller.deleteChat(intent)).isSuccess, isTrue);
        expect(controller.state.selectedId, selected);
        expect(await repository.load(AgentSessionId('other')), isNull);
        await controller.dispose();
        await runtime.close();
      },
    );

    test('selected last chat falls back to the previous neighbor', () async {
      final repository = InMemoryAgentSessionRepository();
      final runtime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
        repository: repository,
      );
      final controller = _controller(runtime, repository, repository);
      await controller.initialize();
      for (final id in <String>['first', 'second']) {
        await controller.createChat(id: AgentSessionId(id));
      }
      final before = controller.state.chats.map((chat) => chat.id).toList();
      final last = before.last;
      await controller.selectChat(last);

      final result = await controller.deleteChat(
        controller.deletionIntentFor(last)!,
      );

      expect(result.isSuccess, isTrue);
      expect(controller.state.selectedId, before[before.length - 2]);
      expect(await repository.load(last), isNull);
      await controller.dispose();
      await runtime.close();
    });

    test(
      'busy selected deletion stops, stabilizes, closes, then tombstones',
      () async {
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('partial')],
          gate: gate,
        );
        final repository = InMemoryAgentSessionRepository();
        final runtime = testRuntime(provider: provider, repository: repository);
        final controller = _controller(runtime, repository, repository);
        await controller.initialize();
        await controller.createChat(id: AgentSessionId('busy-delete'));
        final intent = controller.deletionIntentFor(
          AgentSessionId('busy-delete'),
        )!;
        final sending = controller.send('delete while active');
        await _waitUntil(() => provider.requests.isNotEmpty);

        final deleted = await controller.deleteChat(intent);

        expect(deleted.status, ChatCommandStatus.succeeded);
        expect((await sending).status, ChatCommandStatus.disposed);
        expect(await repository.load(AgentSessionId('busy-delete')), isNull);
        expect(controller.state.selectedSession, isNull);
        expect(controller.state.chats, isEmpty);
        gate.complete();
        await controller.dispose();
        await runtime.close();
      },
    );

    test('delete failure keeps list and restores selected chat', () async {
      final repository = _FailingDeleteRepository();
      final runtime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
        repository: repository,
      );
      final controller = _controller(runtime, repository, repository);
      await controller.initialize();
      await controller.createChat(id: AgentSessionId('kept'));
      final intent = controller.deletionIntentFor(AgentSessionId('kept'))!;

      final result = await controller.deleteChat(intent);

      expect(result.status, ChatCommandStatus.failed);
      expect(controller.state.selectedId, AgentSessionId('kept'));
      expect(controller.state.chats.single.id, AgentSessionId('kept'));
      expect(await repository.load(AgentSessionId('kept')), isNotNull);
      await controller.dispose();
      await runtime.close();
    });

    test(
      'failed close establishes no tombstone and restores a usable chat',
      () async {
        final repository = _FailNextSaveRepository();
        final runtime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: const <List<LlmEvent>>[],
          ),
          repository: repository,
        );
        final controller = _controller(runtime, repository, repository);
        await controller.initialize();
        await controller.createChat(id: AgentSessionId('close-failure'));
        repository.failNextSave = true;

        final result = await controller.deleteChat(
          controller.deletionIntentFor(AgentSessionId('close-failure'))!,
        );

        expect(result.status, ChatCommandStatus.failed);
        expect(repository.deletes, 0);
        expect(
          await repository.load(AgentSessionId('close-failure')),
          isNotNull,
        );
        expect(controller.state.selectedId, AgentSessionId('close-failure'));
        expect(
          controller.state.selectedSession!.lifecycle,
          AgentSessionLifecycle.idle,
        );
        expect(
          (await controller.changeSelection(
            controller.state.selectedSession!.selection,
          )).status,
          ChatCommandStatus.unchanged,
        );
        await controller.dispose();
        await runtime.close();
      },
    );
  });

  test(
    'fresh JSONL stack restores two chats, title, selection, and messages',
    () async {
      final storage = _MemoryJsonlStorage();
      final firstStore = JsonlAgentSessionStore(storage: storage);
      final firstProvider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('a1'), textTurn('a2')],
      );
      final firstRuntime = testRuntime(
        provider: firstProvider,
        repository: firstStore,
      );
      final firstController = _controller(firstRuntime, firstStore, firstStore);
      await firstController.initialize();
      await firstController.createChat(id: AgentSessionId('jsonl-one'));
      await firstController.send('durable first');
      await firstController.send('durable follow-up');
      await firstController.createChat(id: AgentSessionId('jsonl-two'));
      await firstController.selectChat(AgentSessionId('jsonl-one'));
      expect(
        (await firstController.changeReasoning(
          ReasoningMode.disabled,
          ReasoningEffort.modelDefault,
        )).isSuccess,
        isTrue,
      );
      await firstController.dispose();
      await firstRuntime.close();

      expect(storage.payloads.values.join(), contains('"version":1'));
      expect(storage.payloads.values.join(), contains('"version":2'));
      final restartedStore = JsonlAgentSessionStore(storage: storage);
      final restartedRuntime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
        repository: restartedStore,
      );
      final restarted = _controller(
        restartedRuntime,
        restartedStore,
        restartedStore,
      );
      expect((await restarted.initialize()).isSuccess, isTrue);
      expect(restarted.state.chats, hasLength(2));
      expect(restarted.state.selectedId, AgentSessionId('jsonl-one'));
      expect(
        restarted.state.selectedSession!.transcript.messages,
        hasLength(4),
      );
      expect(
        restarted.state.selectedSession!.selection.reasoningMode,
        ReasoningMode.disabled,
      );
      expect(
        restarted.state.chats
            .singleWhere((summary) => summary.id.value == 'jsonl-one')
            .title,
        'durable first',
      );
      expect(
        restarted.state.chats
            .singleWhere((summary) => summary.id.value == 'jsonl-two')
            .title,
        isNull,
      );
      expect(firstProvider.requests[1].context.messages, hasLength(3));
      await restarted.dispose();
      await restartedRuntime.close();
    },
  );

  test('restoring a legacy prompt chat enables current local tools', () async {
    final repository = InMemoryAgentSessionRepository();
    final provider = QueueScriptedLlmProvider(
      id: BuiltInLlmCatalog.deepSeek,
      wireFamily: LlmWireFamily.openaiChatCompletions,
      turns: const <List<LlmEvent>>[],
    );
    final runtime = testRuntime(
      provider: provider,
      repository: repository,
      tools: AgentToolRegistry()
        ..register(
          AgentTool(
            descriptor: LlmToolDescriptor(name: 'read'),
            executor: ScriptedToolExecutor(
              (invocation, {required cancellation, required liveness}) async =>
                  ToolExecutionResult.success(<String, Object?>{}),
            ),
          ),
        ),
    );
    final oldSession = await runtime
        .agent(PromptWorkspace.definition())
        .createSession(
          id: AgentSessionId('legacy-prompt'),
          persistence: SessionPersistence.repository,
        );
    await oldSession.close();
    final legacyRevision = (await repository.load(
      AgentSessionId('legacy-prompt'),
    ))!.revision;

    final currentDefinition = PromptWorkspace.definition(
      enabledTools: <ToolId>[ToolId('read')],
      policy: PolicyId('allow'),
      runLimits: PromptWorkspace.interactiveLimits,
    );
    final controller = ChatWorkspaceController(
      runtime: runtime,
      definition: currentDefinition,
      catalog: repository,
      repository: repository,
      registry: runtime.registry,
    );
    expect((await controller.initialize()).isSuccess, isTrue);
    final restored = controller.state.selectedSession!;
    expect(restored.definition.enabledTools, <ToolId>[ToolId('read')]);
    expect(restored.definition.limits!.maxToolCalls, 10000);
    expect((await repository.load(restored.id))!.revision, legacyRevision + 1);
    await controller.dispose();
    await runtime.close();
  });
}

ChatWorkspaceController _controller(
  InMemoryAgentRuntime runtime,
  AgentSessionRepository repository,
  AgentSessionCatalog catalog, {
  Future<void> Function(AgentSessionSnapshot snapshot)? onTurnCompleted,
}) => ChatWorkspaceController(
  runtime: runtime,
  definition: testDefinition(),
  catalog: catalog,
  repository: repository,
  registry: runtime.registry,
  onTurnCompleted: onTurnCompleted,
);

AgentSessionRecord _emptyRecord(String id) => AgentSessionRecord(
  id: AgentSessionId(id),
  revision: 0,
  definition: testDefinition(),
  transcript: AgentTranscript(),
  usage: LlmUsage(),
  modelTurns: 0,
  toolAttempts: 0,
  createdAtMicros: 1,
  updatedAtMicros: 1,
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var index = 0; index < 100 && !condition(); index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

final class _FailingCatalog implements AgentSessionCatalog {
  _FailingCatalog(this.detail);

  final String detail;

  @override
  Future<AgentSessionCatalogSnapshot> list() => Future.error(detail);
}

final class _FixedCatalog implements AgentSessionCatalog {
  _FixedCatalog(this.snapshot);

  final AgentSessionCatalogSnapshot snapshot;

  @override
  Future<AgentSessionCatalogSnapshot> list() async => snapshot;
}

final class _DelayedCatalog implements AgentSessionCatalog {
  final Completer<AgentSessionCatalogSnapshot> _result =
      Completer<AgentSessionCatalogSnapshot>();

  void complete(AgentSessionCatalogSnapshot snapshot) {
    _result.complete(snapshot);
  }

  @override
  Future<AgentSessionCatalogSnapshot> list() => _result.future;
}

final class _MemoryJsonlStorage implements JsonlStreamStorage {
  final Map<String, String> payloads = <String, String>{};

  @override
  Future<void> cleanup(String key) async {}

  @override
  Future<List<String>> listKeys() async => payloads.keys.toList();

  @override
  Future<void> publish(String key, List<int> contents) async {
    payloads[key] = utf8.decode(contents);
  }

  @override
  Future<Stream<List<int>>?> read(String key) async {
    final value = payloads[key];
    return value == null ? null : Stream<List<int>>.value(utf8.encode(value));
  }
}

final class _HeldSaveRepository
    implements AgentSessionRepository, AgentSessionCatalog {
  _HeldSaveRepository({required this.holdOnSave});

  final int holdOnSave;
  final InMemoryAgentSessionRepository delegate =
      InMemoryAgentSessionRepository();
  final Completer<void> _started = Completer<void>();
  final Completer<void> _release = Completer<void>();
  var _saves = 0;

  Future<void> get heldSaveStarted => _started.future;

  void releaseHeldSave() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => delegate.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    _saves += 1;
    if (_saves == holdOnSave) {
      if (!_started.isCompleted) {
        _started.complete();
      }
      await _release.future;
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

  @override
  Future<AgentSessionCatalogSnapshot> list() => delegate.list();
}

final class _FailingDeleteRepository
    implements AgentSessionRepository, AgentSessionCatalog {
  final InMemoryAgentSessionRepository delegate =
      InMemoryAgentSessionRepository();

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => delegate.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => delegate.save(
    record,
    expectedRevision: expectedRevision,
    cancellation: cancellation,
  );

  @override
  Future<void> delete(
    AgentSessionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => Future<void>.error(AgentException(sanitizedPersistenceError()));

  @override
  Future<AgentSessionCatalogSnapshot> list() => delegate.list();
}

final class _FailNextSaveRepository
    implements AgentSessionRepository, AgentSessionCatalog {
  final InMemoryAgentSessionRepository delegate =
      InMemoryAgentSessionRepository();
  var failNextSave = false;
  var deletes = 0;

  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) => delegate.load(id);

  @override
  Future<void> save(
    AgentSessionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) async {
    if (failNextSave) {
      failNextSave = false;
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
  }) {
    deletes += 1;
    return delegate.delete(
      id,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<AgentSessionCatalogSnapshot> list() => delegate.list();
}

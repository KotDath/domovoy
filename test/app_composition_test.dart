import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/domain/prompt_workspace.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart'
    hide createPlatformJsonlStreamStorage;
import 'package:domovoy/infrastructure/credentials/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/agent_harness.dart';
import 'support/fakes.dart';
import 'support/recording_http_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('production agent composition', () {
    test('direct core ID factory retains its legacy default IDs', () {
      expect(AgentIdFactory().next('message'), 'message-1');
      expect(AgentIdFactory().next('run'), 'run-1');
    });

    test('registers API-key provider manifest and curated startup models', () {
      final client = http.Client();
      addTearDown(client.close);
      final stack = buildProductionAgentStack(
        httpClient: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(),
          readEnvironment: (_) => null,
        ),
      );

      expect(
        stack.registry.providers.map((provider) => provider.id.value).toSet(),
        containsAll(<String>[
          'deepseek',
          'moonshotai',
          'openai',
          'anthropic',
          'google',
          'groq',
          'openrouter',
          'together',
        ]),
      );
      expect(stack.registry.profiles, hasLength(greaterThanOrEqualTo(16)));
      expect(stack.registry.models, hasLength(9));
      expect(
        stack.registry.requireProvider(BuiltInLlmCatalog.deepSeek).wireFamily,
        LlmWireFamily.openaiChatCompletions,
      );
      expect(
        stack.registry.requireProvider(BuiltInLlmCatalog.moonshotAi).wireFamily,
        LlmWireFamily.openaiChatCompletions,
      );
      expect(
        stack.registry.requireProvider(BuiltInLlmCatalog.openAi).wireFamily,
        LlmWireFamily.openaiResponses,
      );
      expect(stack.runtime.tools.lookup('any'), isNull);
      expect(stack.runtime.approval, isNull);
      expect(stack.runtime.profile.limits.maxModelTurns, isNull);
      expect(stack.runtime.profile.limits.maxToolCalls, isNull);
      expect(stack.runtime.profile.budget.totalTokens, isNull);
      expect(
        stack.runtime.contextEstimator,
        isA<Utf8FramingAgentContextEstimator>(),
      );
      expect(stack.runtime.compactionTrigger, isA<OpenCodeCompactionTrigger>());
      expect(
        stack.runtime.modelSwitchFitPolicy,
        isA<OpenCodeAgentModelSwitchFitPolicy>(),
      );
      expect(stack.runtime.historyCompactor, isA<OpenCodeSummaryCompactor>());
      final summary =
          stack.runtime.historyCompactor as OpenCodeSummaryCompactor;
      expect(
        identical(summary.contextEstimator, stack.runtime.contextEstimator),
        isTrue,
      );
      expect(stack.repository, isA<JsonlAgentSessionStore>());
      expect(identical(stack.repository, stack.catalog), isTrue);
      expect(identical(stack.runtime.repository, stack.repository), isTrue);
      expect(
        stack.runtime.profile.liveness.idleTimeout,
        AgentLivenessPolicy.defaultIdleTimeout,
      );
    });

    test(
      'fresh production chat selects a smaller native model after catalog refresh',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'domovoy-fresh-native-switch-',
        );
        addTearDown(() => sandbox.delete(recursive: true));
        final client = RecordingClient(_switchDiscoveryResponse);
        addTearDown(client.close);
        final store = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
        );
        final stack = buildProductionAgentStack(
          httpClient: client,
          credentials: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(<ProviderId, String>{
              BuiltInLlmCatalog.deepSeek: 'test-key',
            }),
            readEnvironment: (_) => null,
          ),
          repository: store,
          catalog: store,
        );
        addTearDown(() async {
          await stack.runtime.close();
          await stack.providerModelCatalog?.close();
        });
        await stack.providerModelCatalog!.refresh();
        final session = await stack.runtime
            .agent(stack.promptDefinition)
            .createSession(persistence: SessionPersistence.repository);
        addTearDown(session.close);

        final target = _claudeSonnetSelection();
        final result = await session.changeSelection(target);

        expect(result.status, AgentSessionSelectionStatus.changed);
        expect(session.snapshot.selection, target);
        expect(
          client.requests.where((request) => request.method == 'POST'),
          isEmpty,
        );
      },
    );

    test(
      'restored Pro history selects Claude without unnecessary compaction',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'domovoy-restored-native-switch-',
        );
        addTearDown(() => sandbox.delete(recursive: true));
        final client = RecordingClient((request) {
          if (request.method == 'POST' &&
              request.url.host == 'api.deepseek.com' &&
              request.url.path.endsWith('/chat/completions')) {
            return sseResponse(
              _chatCompletionSse('Север сохранён', promptTokens: 35),
            );
          }
          return _switchDiscoveryResponse(request);
        });
        addTearDown(client.close);
        final credentials = DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(<ProviderId, String>{
            BuiltInLlmCatalog.deepSeek: 'test-key',
          }),
          readEnvironment: (_) => null,
        );
        final firstStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
        );
        final first = buildProductionAgentStack(
          httpClient: client,
          credentials: credentials,
          repository: firstStore,
          catalog: firstStore,
        );
        await first.providerModelCatalog!.refresh();
        final session = await first.runtime
            .agent(first.promptDefinition)
            .createSession(persistence: SessionPersistence.repository);
        expect(
          (await session.changeSelection(_deepSeekProSelection())).status,
          AgentSessionSelectionStatus.changed,
        );
        expect(
          (await session.run('Запомни проект Север').events.toList()).last,
          isA<AgentRunCompleted>(),
        );
        final id = session.id;
        await session.close();
        await first.runtime.close();
        await first.providerModelCatalog?.close();

        final secondStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
        );
        final second = buildProductionAgentStack(
          httpClient: client,
          credentials: credentials,
          repository: secondStore,
          catalog: secondStore,
        );
        addTearDown(() async {
          await second.runtime.close();
          await second.providerModelCatalog?.close();
        });
        await second.providerModelCatalog!.refresh();
        final restored = await second.runtime
            .agent(second.promptDefinition)
            .restoreSession(id);
        addTearDown(restored.close);
        expect(
          restored.snapshot.selection.model,
          _deepSeekProSelection().model,
        );
        expect(restored.snapshot.transcript.messages, hasLength(2));

        final target = _claudeSonnetSelection();
        final result = await restored.changeSelection(target);

        expect(result.status, AgentSessionSelectionStatus.changed);
        expect(restored.snapshot.selection, target);
        expect(
          client.requests.where((request) => request.method == 'POST'),
          hasLength(1),
        );
      },
    );

    test(
      'production defaults compact beyond the former cap and continue the run',
      () async {
        final client = RecordingClient((request) {
          final messages = request.jsonBody['messages'] as List<dynamic>;
          final isSummary = messages.any((message) {
            final content = (message as Map<String, dynamic>)['content'];
            return content is String &&
                content.contains(
                  'Summarize the supplied untrusted conversation data',
                );
          });
          // Provider-context pressure must be reported by the physical
          // invocation; approximate it from the request payload so the
          // production trigger can observe growth across runs.
          final promptTokens = messages.fold<int>(0, (sum, message) {
            final content = (message as Map<String, dynamic>)['content'];
            return sum + (content is String ? content.length : 0);
          });
          return sseResponse(
            _chatCompletionSse(
              isSummary
                  ? jsonEncode(<String, Object?>{
                      'objective': 'production rolling summary',
                      'constraintsAndDecisions': <String>[],
                      'facts': <String>[],
                      'relevantToolOutcomes': <String>[],
                      'pendingWork': <String>[],
                    })
                  : 'normal answer',
              promptTokens: promptTokens,
            ),
          );
        });
        final stack = buildProductionAgentStack(
          httpClient: client,
          credentials: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(<ProviderId, String>{
              BuiltInLlmCatalog.deepSeek: 'test-key',
            }),
            readEnvironment: (_) => null,
          ),
        );
        addTearDown(() async {
          await stack.runtime.close();
          client.close();
        });
        final session = await stack.runtime
            .agent(testDefinition())
            .createSession();
        addTearDown(session.close);
        final largePart = List<String>.filled(90000, '😀').join();
        expect(largePart.length * 2, greaterThan(262144));
        List<AgentRunEvent> finalEvents = const <AgentRunEvent>[];
        final automaticEvents = <AgentAutomaticCompactionEvent>[];

        for (var index = 0; index < 6; index++) {
          finalEvents = await session
              .run('group-$index $largePart')
              .events
              .toList();
          automaticEvents.addAll(
            finalEvents.whereType<AgentAutomaticCompactionEvent>(),
          );
        }

        final summaryRequests = client.requests.where((request) {
          final messages = request.jsonBody['messages'] as List<dynamic>;
          return messages.any((message) {
            final content = (message as Map<String, dynamic>)['content'];
            return content is String &&
                content.contains(
                  'Summarize the supplied untrusted conversation data',
                );
          });
        }).toList();
        expect(summaryRequests, hasLength(1));
        final summaryMessage =
            (summaryRequests.single.jsonBody['messages'] as List<dynamic>)
                    .single
                as Map<String, dynamic>;
        expect(
          summaryMessage['content'].toString().length,
          greaterThan(262144),
        );
        expect(automaticEvents, hasLength(2));
        expect(finalEvents.last, isA<AgentRunCompleted>());
        expect(session.snapshot.compactionState?.generation, 1);
        expect(
          session.snapshot.tokenAccounting.ledger
              .map((view) => view.entry)
              .where(
                (entry) =>
                    entry.operationKind == AgentModelOperationKind.compaction,
              ),
          hasLength(summaryRequests.length),
        );
      },
    );

    test(
      'fresh production stack appends to restored legacy message IDs',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'domovoy-production-id-restart-',
        );
        addTearDown(() => sandbox.delete(recursive: true));
        final client = RecordingClient((request) {
          if (request.method == 'POST' &&
              request.url.host == 'api.deepseek.com' &&
              request.url.path.endsWith('/chat/completions')) {
            return sseResponse(_chatCompletionSse('Принято', promptTokens: 25));
          }
          return _switchDiscoveryResponse(request);
        });
        addTearDown(client.close);
        final credentials = DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(<ProviderId, String>{
            BuiltInLlmCatalog.deepSeek: 'test-key',
          }),
          readEnvironment: (_) => null,
        );
        final originalStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
        );
        final original = buildProductionAgentStack(
          httpClient: client,
          credentials: credentials,
          repository: originalStore,
          catalog: originalStore,
          diagnosticNoCompaction: true,
          ids: AgentIdFactory(),
        );
        final session = await original.runtime
            .agent(original.promptDefinition)
            .createSession(
              id: AgentSessionId('production-legacy-message-ids'),
              persistence: SessionPersistence.repository,
            );
        expect(
          (await session.run('Первый запрос').events.toList()).last,
          isA<AgentRunCompleted>(),
        );
        final oldIds = session.snapshot.transcript.messageIds
            .whereType<AgentTranscriptMessageId>()
            .toList();
        expect(oldIds, hasLength(2));
        expect(oldIds.every((id) => id.value.startsWith('message-')), isTrue);
        await session.close();
        await original.runtime.close();
        await original.providerModelCatalog?.close();

        final restoredStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
        );
        final fresh = buildProductionAgentStack(
          httpClient: client,
          credentials: credentials,
          repository: restoredStore,
          catalog: restoredStore,
          diagnosticNoCompaction: true,
        );
        final restored = await fresh.runtime
            .agent(fresh.promptDefinition)
            .restoreSession(AgentSessionId('production-legacy-message-ids'));
        expect(
          (await restored.run('Второй запрос').events.toList()).last,
          isA<AgentRunCompleted>(),
        );
        final allIds = restored.snapshot.transcript.messageIds
            .whereType<AgentTranscriptMessageId>()
            .toList();
        expect(allIds, hasLength(4));
        expect(allIds.toSet(), hasLength(4));
        expect(
          allIds.skip(2).every((id) => id.value.startsWith('runtime-')),
          isTrue,
        );
        await restored.close();
        await fresh.runtime.close();
        await fresh.providerModelCatalog?.close();
      },
    );

    test(
      'delayed HTTP teardown finishes before the shared client closes',
      () async {
        final client = _DelayedReleaseClient(
          releaseDelay: const Duration(milliseconds: 40),
        );
        final stack = buildProductionAgentStack(
          httpClient: client,
          credentials: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(<ProviderId, String>{
              BuiltInLlmCatalog.deepSeek: 'test-key',
            }),
            readEnvironment: (_) => null,
          ),
        );
        final dependencies = DomovoyDependencies(
          runtime: stack.runtime,
          registry: stack.registry,
          promptDefinition: stack.promptDefinition,
          repository: stack.repository,
          catalog: stack.catalog,
          overrideStore: MemoryApiKeyOverrideStore(),
          apiKeyResolver: ApiKeyResolver(
            overrideStore: MemoryApiKeyOverrideStore(),
            environment: const MapEnvironmentReader({}),
          ),
          httpClient: client,
        );
        final run = stack.runtime.agent(stack.promptDefinition).run('hello');
        run.events.drain<void>().ignore();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await dependencies.close();
        expect(identical(dependencies.repository, stack.repository), isTrue);
        expect(identical(dependencies.catalog, stack.catalog), isTrue);
        expect(client.released, isTrue);
        expect(client.closed, isTrue);
        expect(client.releasedBeforeClose, isTrue);
        expect(stack.runtime.lifecycle, AgentRuntimeLifecycle.closed);
      },
    );

    test(
      'non-workspace prompt facade remains one-shot with configured runtime',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'domovoy-composition-prompt-',
        );
        addTearDown(() => sandbox.delete(recursive: true));
        final storage = _filesystemStorage(sandbox);
        final persistence = JsonlAgentSessionStore(storage: storage);
        final client = RecordingClient(
          (_) => sseResponse(
            'data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n',
          ),
        );
        final stack = buildProductionAgentStack(
          httpClient: client,
          credentials: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(<ProviderId, String>{
              BuiltInLlmCatalog.deepSeek: 'test-key',
            }),
            readEnvironment: (_) => null,
          ),
          repository: persistence,
          catalog: persistence,
        );
        addTearDown(() async {
          await stack.runtime.close();
          client.close();
        });

        expect(stack.runtime.compactionTrigger, isNotNull);
        expect(stack.runtime.historyCompactor, isNotNull);
        expect(stack.promptDefinition.limits?.maxModelTurns, 10000);
        expect(stack.promptDefinition.limits?.maxToolCalls, 10000);

        final agent = stack.runtime.agent(stack.promptDefinition);
        final first = await agent.run('first').events.toList();
        final second = await agent.run('second').events.toList();

        expect(first.last, isA<AgentRunCompleted>());
        expect(second.last, isA<AgentRunCompleted>());
        expect(first.whereType<AgentAutomaticCompactionEvent>(), isEmpty);
        expect(second.whereType<AgentAutomaticCompactionEvent>(), isEmpty);
        expect(
          first.whereType<AgentRunStarted>().single.sessionId,
          isNot(second.whereType<AgentRunStarted>().single.sessionId),
        );
        expect(client.requests, hasLength(2));
        expect((await stack.catalog.list()).available, isEmpty);
        expect((await stack.catalog.list()).issues, isEmpty);
        expect(await storage.listKeys(), isEmpty);
        expect(
          (client.requests[0].jsonBody['messages'] as List).single['content'],
          'first',
        );
        expect(
          (client.requests[1].jsonBody['messages'] as List).single['content'],
          'second',
        );
      },
    );

    test(
      'fresh production stacks restore exact records and durable deletion',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'domovoy-composition-restart-',
        );
        addTearDown(() => sandbox.delete(recursive: true));

        final firstClient = http.Client();
        final firstStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
        );
        final first = _buildStackWithPersistence(firstClient, firstStore);
        final rich = _richRecord(
          AgentSessionId('production-rich'),
          revision: 0,
          updatedAtMicros: 20,
        );
        final other = _record(
          AgentSessionId('production-other'),
          revision: 0,
          updatedAtMicros: 10,
          messages: 2,
        );
        await first.repository.save(
          rich,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        await first.repository.save(
          other,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        await first.runtime.close();
        firstClient.close();

        final secondClient = http.Client();
        final secondStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
        );
        final second = _buildStackWithPersistence(secondClient, secondStore);
        expect(identical(second.repository, secondStore), isTrue);
        expect(identical(second.catalog, secondStore), isTrue);
        expect(identical(second.runtime.repository, secondStore), isTrue);
        final catalog = await second.catalog.list();
        expect(catalog.available.map((entry) => entry.id.value), <String>[
          'production-rich',
          'production-other',
        ]);
        expect(await second.repository.load(rich.id), rich);
        expect(await second.repository.load(other.id), other);

        final restored = await second.runtime
            .agent(rich.definition)
            .restoreSession(rich.id);
        expect(restored.snapshot.id, rich.id);
        expect(restored.snapshot.transcript, rich.transcript);
        expect(restored.snapshot.usage, rich.usage);
        expect(restored.snapshot.modelTurns, rich.modelTurns);
        expect(restored.snapshot.toolAttempts, rich.toolAttempts);
        expect(restored.snapshot.compactionState, rich.compactionState);
        expect(restored.snapshot.revision, rich.revision);
        await restored.close();
        final acknowledgedRich = (await second.repository.load(rich.id))!;
        expect(acknowledgedRich.revision, 1);
        expect(acknowledgedRich.transcript, rich.transcript);
        expect(acknowledgedRich.usage, rich.usage);
        expect(acknowledgedRich.continuationEntries, rich.continuationEntries);
        expect(acknowledgedRich.compactionState, rich.compactionState);

        await second.repository.delete(
          other.id,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        await second.runtime.close();
        secondClient.close();

        final thirdClient = http.Client();
        final thirdStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
        );
        final third = _buildStackWithPersistence(thirdClient, thirdStore);
        final afterDelete = await third.catalog.list();
        expect(afterDelete.available.single.id, rich.id);
        expect(
          afterDelete.available.single.revision,
          acknowledgedRich.revision,
        );
        expect(afterDelete.issues, isEmpty);
        expect(await third.repository.load(other.id), isNull);
        expect(await third.repository.load(rich.id), acknowledgedRich);
        await expectLater(
          third.repository.save(
            other,
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
          _agentError(AgentErrorKind.conflict),
        );
        await third.runtime.close();
        thirdClient.close();
      },
    );

    test(
      'fresh production codec, JSONL store, and runtime restore mixed accounting',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'domovoy-accounting-restart-',
        );
        addTearDown(() => sandbox.delete(recursive: true));
        final expected = _mixedAccountingRecord();

        final firstClient = http.Client();
        final firstStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
          recordCodec: const AgentSessionCodec(),
        );
        final first = _buildStackWithPersistence(firstClient, firstStore);
        await first.repository.save(
          expected,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        await first.runtime.close();
        firstClient.close();

        final secondClient = http.Client();
        final secondStore = JsonlAgentSessionStore(
          storage: _filesystemStorage(sandbox),
          recordCodec: const AgentSessionCodec(),
        );
        final second = _buildStackWithPersistence(secondClient, secondStore);
        final decoded = await second.repository.load(expected.id);
        expect(decoded, expected);
        final restored = await second.runtime
            .agent(expected.definition)
            .restoreSession(expected.id);
        final accounting = restored.snapshot.tokenAccounting;
        expect(
          accounting.ledger.map((view) => view.entry).toList(),
          expected.tokenAccounting.entries,
        );
        expect(accounting.contextRevision, 12);
        expect(accounting.legacyBaseline, LlmUsage(totalTokens: 10));
        expect(accounting.currentRequest?.attemptId.value, 'failed-attempt');
        expect(accounting.latestResponse?.responseMessageRetained, isFalse);
        expect(
          accounting.latestResponse?.responseMessageId.value,
          'retry-response',
        );
        expect(accounting.assistantConversation.contributorCount, 6);
        expect(accounting.assistantConversation.overall.knownSubtotal, 20);
        expect(
          accounting.assistantConversation.overall.completeness,
          LlmUsageCompleteness.partial,
        );
        expect(accounting.compaction.contributorCount, 2);
        expect(accounting.compaction.overall.knownSubtotal, 7);
        expect(
          accounting.compaction.overall.completeness,
          LlmUsageCompleteness.partial,
        );
        expect(accounting.session.contributorCount, 9);
        expect(accounting.session.overall.knownSubtotal, 37);
        expect(accounting.byModel, hasLength(2));
        expect(
          accounting
              .byModel[BuiltInLlmCatalog.deepSeekV4FlashModel.ref]
              ?.session
              .overall
              .knownSubtotal,
          27,
        );
        expect(
          accounting
              .byModel[BuiltInLlmCatalog.gpt4oMiniModel.ref]
              ?.session
              .overall
              .completeness,
          LlmUsageCompleteness.unavailable,
        );
        expect(
          accounting.retainedContext.provenance,
          LlmUsageMetricProvenance.estimated,
        );
        expect(
          accounting.ledger
              .where(
                (view) =>
                    view.entry.operationKind ==
                    AgentModelOperationKind.compaction,
              )
              .every((view) => view.entry.responseMessageId == null),
          isTrue,
        );
        expect(
          accounting.ledger
              .where(
                (view) => view.entry.responseMessageId?.value == 'old-response',
              )
              .single
              .responseMessageRetained,
          isFalse,
        );
        expect(
          accounting.session.overall.completeness,
          LlmUsageCompleteness.partial,
        );
        expect(restored.snapshot.compactionState?.generation, 1);
        expect(restored.snapshot.transcript, expected.transcript);
        await restored.close();
        await second.runtime.close();
        secondClient.close();
      },
    );

    test(
      'injected durable failures are surfaced without memory fallback',
      () async {
        final client = http.Client();
        addTearDown(client.close);
        final persistence = JsonlAgentSessionStore(
          storage: const _UnavailableJsonlStorage(),
        );
        final stack = _buildStackWithPersistence(client, persistence);
        addTearDown(stack.runtime.close);

        expect(identical(stack.repository, persistence), isTrue);
        expect(identical(stack.catalog, persistence), isTrue);
        expect(identical(stack.runtime.repository, persistence), isTrue);
        await _expectSanitizedPersistence(stack.catalog.list());
        await _expectSanitizedPersistence(
          stack.repository.save(
            _record(
              AgentSessionId('no-production-fallback'),
              revision: 0,
              updatedAtMicros: 1,
            ),
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
        );
      },
    );

    test('closes the runtime before the shared HTTP client', () async {
      final client = _OrderingClient();
      final stack = buildProductionAgentStack(
        httpClient: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(),
          readEnvironment: (_) => null,
        ),
      );
      client.runtime = stack.runtime;
      final dependencies = DomovoyDependencies(
        runtime: stack.runtime,
        registry: stack.registry,
        promptDefinition: stack.promptDefinition,
        repository: stack.repository,
        catalog: stack.catalog,
        overrideStore: MemoryApiKeyOverrideStore(),
        apiKeyResolver: ApiKeyResolver(
          overrideStore: MemoryApiKeyOverrideStore(),
          environment: const MapEnvironmentReader({}),
        ),
        httpClient: client,
      );
      expect(client.closed, isFalse);
      await dependencies.close();
      expect(stack.runtime.lifecycle, AgentRuntimeLifecycle.closed);
      expect(client.closed, isTrue);
      expect(client.closedAfterRuntime, isTrue);
    });

    test(
      'composition close sanitizes failures and still closes the client',
      () async {
        final client = _ThrowingCloseClient();
        final stack = buildProductionAgentStack(
          httpClient: client,
          credentials: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(),
            readEnvironment: (_) => null,
          ),
        );
        final dependencies = DomovoyDependencies(
          runtime: stack.runtime,
          registry: stack.registry,
          promptDefinition: stack.promptDefinition,
          repository: stack.repository,
          catalog: stack.catalog,
          overrideStore: MemoryApiKeyOverrideStore(),
          apiKeyResolver: ApiKeyResolver(
            overrideStore: MemoryApiKeyOverrideStore(),
            environment: const MapEnvironmentReader({}),
          ),
          httpClient: client,
          disposeCallback: () {
            throw StateError('dispose-secret');
          },
        );
        await expectLater(
          dependencies.close(),
          throwsA(
            isA<AgentException>().having(
              (error) => error.error.message.toLowerCase(),
              'message',
              isNot(contains('secret')),
            ),
          ),
        );
        expect(client.closed, isTrue);
        expect(stack.runtime.lifecycle, AgentRuntimeLifecycle.closed);
      },
    );

    test(
      'keeps DeepSeek flash as the prompt default despite other profiles',
      () {
        final client = http.Client();
        addTearDown(client.close);
        final stack = buildProductionAgentStack(
          httpClient: client,
          credentials: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(),
            readEnvironment: (_) => null,
          ),
        );

        expect(
          stack.promptDefinition.model.providerId,
          BuiltInLlmCatalog.deepSeek,
        );
        expect(
          stack.promptDefinition.model.modelId,
          BuiltInLlmCatalog.deepSeekFlash,
        );
        expect(stack.promptDefinition.limits?.maxModelTurns, 10000);
        expect(stack.promptDefinition.limits?.maxToolCalls, 10000);
        expect(
          stack.promptDefinition.generation.reasoningMode,
          ReasoningMode.enabled,
        );
        expect(
          stack.registry.models.map((model) => model.id.value),
          containsAll(<String>['kimi-k3', 'gpt-5.4']),
        );
      },
    );

    test(
      'legacy DeepSeek override remains readable through composition',
      () async {
        final client = http.Client();
        addTearDown(client.close);
        final strings = MemorySecureStringStore(<String, String>{
          NamespacedProviderCredentialStore.legacyDeepSeekKey:
              '  legacy-secret  ',
        });
        final stack = buildProductionAgentStack(
          httpClient: client,
          credentials: DefaultProviderCredentialResolver(
            store: NamespacedProviderCredentialStore(strings),
            readEnvironment: (_) => 'env-should-not-win',
          ),
        );

        final resolved = await stack.credentials.resolve(
          providerId: BuiltInLlmCatalog.deepSeek,
          environmentVariable:
              BuiltInLlmCatalog.deepSeekApiKeyEnvironmentVariable,
        );
        expect(resolved.value, 'legacy-secret');
        expect(resolved.source, LlmCredentialSource.storedOverride);
      },
    );
  });

  group('prompt workspace application boundary', () {
    test(
      'presentation imports agent-runtime events, not provider transports',
      () {
        final controller = File(
          'lib/features/prompt/presentation/prompt_controller.dart',
        ).readAsStringSync();
        final page = File(
          'lib/features/prompt/presentation/prompt_page.dart',
        ).readAsStringSync();
        for (final source in <String>[controller, page]) {
          expect(source, isNot(contains('infrastructure/llm')));
          expect(source, isNot(contains('openai_compatible')));
          expect(source, isNot(contains('openai_responses')));
          expect(source, isNot(contains('core/llm/events')));
          expect(source, isNot(contains('LlmEvent')));
          expect(source, isNot(contains('LlmTextDelta')));
          expect(source, isNot(contains('OpenAiCompatibleChatAgent')));
        }
        expect(controller, contains('AgentRunEvent'));
        expect(controller, contains('.run('));
      },
    );

    test('one-call sessions close automatically and keep no history', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('one'), textTurn('two')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(PromptWorkspace.definition());

      final first = await agent.run('first').events.toList();
      final second = await agent.run('second').events.toList();
      final firstSession = first.whereType<AgentRunStarted>().single.sessionId;
      final secondSession = second
          .whereType<AgentRunStarted>()
          .single
          .sessionId;

      expect(first.last, isA<AgentRunCompleted>());
      expect(second.last, isA<AgentRunCompleted>());
      expect(firstSession, isNot(secondSession));
      expect(provider.requests, hasLength(2));
      expect(provider.requests[0].context.messages, hasLength(1));
      expect(provider.requests[1].context.messages, hasLength(1));
      expect(
        (provider.requests[1].context.messages.single.parts.single
                as LlmTextPart)
            .text,
        'second',
      );
      expect(runtime.router.queuedCount(firstSession), 0);
      expect(runtime.router.queuedCount(secondSession), 0);
    });

    test(
      'zero-tool workspace policy does not change global unlimited defaults',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[toolTurn(name: 'search', callId: 'call-1')],
        );
        final runtime = testRuntime(provider: provider);
        expect(runtime.profile.limits.maxToolCalls, isNull);
        expect(runtime.profile.limits.maxModelTurns, isNull);

        final events = await runtime
            .agent(PromptWorkspace.definition())
            .run('use a tool')
            .events
            .toList();
        final stopped = events.whereType<AgentRunStopped>().single;
        expect(stopped.reason, AgentStopReason.toolCallLimit);
        expect(provider.requests, hasLength(1));
      },
    );

    test(
      'production definitions and records serialize no secrets or runtime objects',
      () {
        final definition = PromptWorkspace.definition();
        final record = AgentSessionRecord(
          id: AgentSessionId('prompt-session'),
          revision: 0,
          definition: definition,
          transcript: AgentTranscript(),
          usage: LlmUsage(),
          modelTurns: 0,
          toolAttempts: 0,
          createdAtMicros: 1,
          updatedAtMicros: 1,
        );
        final encoded = jsonEncode(<String, Object?>{
          'definition': definition.toJson(),
          'record': const AgentSessionCodec().encode(record),
        });
        final lower = encoded.toLowerCase();
        expect(lower, isNot(contains('sk-')));
        expect(lower, isNot(contains('api_key')));
        expect(lower, isNot(contains('bearer')));
        expect(lower, isNot(contains('authorization')));
        expect(encoded, isNot(contains('http.Client')));
        expect(encoded, isNot(contains('Callback')));
        expect(encoded, isNot(contains('StreamController')));
        _assertJsonTreeHasNoRuntimeObjects(jsonDecode(encoded));
        expect(encoded, contains('deepseek-flash'));
        expect(encoded, isNot(contains('kimi-k3')));
        expect(encoded, isNot(contains('gpt-5.4')));
      },
    );
  });
}

JsonlFilesystemStreamStorage _filesystemStorage(Directory applicationSupport) {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: () async => applicationSupport,
  );
}

ProductionAgentStack _buildStackWithPersistence(
  http.Client client,
  JsonlAgentSessionStore persistence,
) {
  return buildProductionAgentStack(
    httpClient: client,
    credentials: DefaultProviderCredentialResolver(
      store: MemoryProviderCredentialStore(),
      readEnvironment: (_) => null,
    ),
    repository: persistence,
    catalog: persistence,
  );
}

final class _UnavailableJsonlStorage implements JsonlStreamStorage {
  const _UnavailableJsonlStorage();

  @override
  Future<void> cleanup(String key) {
    throw StateError('storage cleanup /private/sk-secret raw-content');
  }

  @override
  Future<List<String>> listKeys() {
    throw StateError('storage list /private/sk-secret raw-content');
  }

  @override
  Future<void> publish(String key, List<int> contents) {
    throw StateError('storage publish /private/sk-secret raw-content');
  }

  @override
  Future<Stream<List<int>>?> read(String key) {
    throw StateError('storage read /private/sk-secret raw-content');
  }
}

Future<void> _expectSanitizedPersistence(Future<Object?> future) async {
  try {
    await future;
    fail('Expected a persistence failure.');
  } on AgentException catch (error) {
    expect(error.error.kind, AgentErrorKind.persistence);
    expect(error.error.message, isNot(contains('sk-secret')));
    expect(error.error.message, isNot(contains('/private')));
    expect(error.error.message, isNot(contains('raw-content')));
  }
}

Matcher _agentError(AgentErrorKind kind) => throwsA(
  isA<AgentException>().having((error) => error.error.kind, 'kind', kind),
);

CancellationToken _openToken() => CancellationSource().token;

String _chatCompletionSse(String text, {int? promptTokens}) =>
    'data: ${jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'delta': <String, Object?>{'content': text},
          'finish_reason': 'stop',
        },
      ],
      if (promptTokens != null) 'usage': <String, Object?>{'prompt_tokens': promptTokens, 'completion_tokens': text.length, 'total_tokens': promptTokens + text.length},
    })}\n\n'
    'data: [DONE]\n\n';

http.StreamedResponse _switchDiscoveryResponse(RecordedRequest request) {
  if (request.url.host == 'models.dev') {
    return sseResponse('{}', status: 503);
  }
  if (request.method == 'GET' &&
      request.url.host == 'api.deepseek.com' &&
      request.url.path.endsWith('/models')) {
    return sseResponse(
      '{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}',
    );
  }
  return sseResponse('{}', status: 503);
}

AgentSessionSelection _claudeSonnetSelection() => AgentSessionSelection(
  model: ModelRef(
    providerId: ProviderId('anthropic'),
    modelId: ModelId('claude-sonnet-4-6'),
  ),
  reasoningMode: ReasoningMode.disabled,
  reasoningEffort: ReasoningEffort.modelDefault,
);

AgentSessionSelection _deepSeekProSelection() => AgentSessionSelection(
  model: BuiltInLlmCatalog.deepSeekV4ProModel.ref,
  reasoningMode: ReasoningMode.disabled,
  reasoningEffort: ReasoningEffort.modelDefault,
);

AgentSessionRecord _record(
  AgentSessionId id, {
  required int revision,
  required int updatedAtMicros,
  int messages = 0,
}) {
  return AgentSessionRecord(
    id: id,
    revision: revision,
    definition: testDefinition(),
    transcript: AgentTranscript(
      messages: List<LlmMessage>.generate(
        messages,
        (index) => LlmMessage(
          role: index.isEven ? LlmMessageRole.user : LlmMessageRole.assistant,
          parts: <LlmContentPart>[LlmTextPart('message-$index')],
        ),
      ),
    ),
    usage: LlmUsage(totalTokens: messages),
    modelTurns: messages ~/ 2,
    toolAttempts: 0,
    createdAtMicros: 1,
    updatedAtMicros: updatedAtMicros,
  );
}

AgentSessionRecord _richRecord(
  AgentSessionId id, {
  required int revision,
  required int updatedAtMicros,
}) {
  final messages = <LlmMessage>[
    LlmMessage(
      role: LlmMessageRole.assistant,
      parts: <LlmContentPart>[LlmTextPart('summary')],
    ),
    LlmMessage(
      role: LlmMessageRole.user,
      parts: <LlmContentPart>[LlmTextPart('question')],
    ),
    LlmMessage(
      role: LlmMessageRole.assistant,
      parts: <LlmContentPart>[LlmTextPart('answer')],
    ),
  ];
  return AgentSessionRecord(
    id: id,
    revision: revision,
    definition: testDefinition(model: BuiltInLlmCatalog.gpt4oMiniModel.ref),
    selection: AgentSessionSelection(
      model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
      reasoningMode: ReasoningMode.disabled,
      reasoningEffort: ReasoningEffort.modelDefault,
    ),
    transcript: AgentTranscript(messages: messages),
    usage: LlmUsage(inputTokens: 4, outputTokens: 2, totalTokens: 6),
    modelTurns: 1,
    toolAttempts: 0,
    createdAtMicros: 1,
    updatedAtMicros: updatedAtMicros,
    continuationEntries: <LlmContinuationEntry>[
      LlmContinuationEntry(
        assistantMessageIndex: 2,
        state: LlmProviderTurnState(
          origin: BuiltInLlmCatalog.gpt4oMiniModel.ref,
          wireFamily: LlmWireFamily.openaiResponses,
          format: openaiResponsesOutputItemsV1,
          payload: <Map<String, Object?>>[
            <String, Object?>{
              'type': 'message',
              'id': 'message-2',
              'role': 'assistant',
              'content': <Map<String, Object?>>[
                <String, Object?>{
                  'type': 'output_text',
                  'text': 'answer',
                  'annotations': <Object?>[],
                },
              ],
            },
          ],
        ),
      ),
    ],
    compactionState: AgentCompactionState(
      generation: 1,
      generatedPrefixStart: 0,
      generatedPrefixCount: 1,
      reason: AgentCompactionReason.manual,
      triggerId: null,
      triggerVersion: null,
      strategyId: 'summary',
      strategyVersion: 1,
      estimatorId: 'utf8-framing',
      estimatorVersion: 1,
      removedMessageCount: 2,
      beforeEstimate: 20,
      afterEstimate: 10,
      decisionMetadata: const <String, Object?>{'mode': 'safe'},
      updatedAtMicros: updatedAtMicros,
    ),
  );
}

AgentSessionRecord _mixedAccountingRecord() {
  final summaryId = AgentTranscriptMessageId('summary-message');
  final requestId = AgentTranscriptMessageId('current-request');
  final responseId = AgentTranscriptMessageId('current-response');
  final transcript = AgentTranscript(
    messages: <LlmMessage>[
      LlmMessage(
        role: LlmMessageRole.assistant,
        parts: <LlmContentPart>[LlmTextPart('summary')],
      ),
      LlmMessage(
        role: LlmMessageRole.user,
        parts: <LlmContentPart>[LlmTextPart('current request')],
      ),
      LlmMessage(
        role: LlmMessageRole.assistant,
        parts: <LlmContentPart>[LlmTextPart('current answer')],
      ),
    ],
    messageIds: <AgentTranscriptMessageId?>[summaryId, requestId, responseId],
  );
  final deepSeek = BuiltInLlmCatalog.deepSeekV4FlashModel.ref;
  final alternate = BuiltInLlmCatalog.gpt4oMiniModel.ref;
  final entries = <AgentModelUsageEntry>[
    AgentModelUsageEntry.assistant(
      sequence: 1,
      attemptId: ProviderAttemptId('normal-attempt'),
      model: deepSeek,
      outcome: AgentModelInvocationOutcome.completed,
      usage: LlmUsage(totalTokens: 3),
      contextRevision: 1,
      runId: RunId('normal-run'),
      turnId: TurnId('normal-turn'),
      retryOrdinal: 0,
      requestMessageId: AgentTranscriptMessageId('old-request'),
      responseMessageId: AgentTranscriptMessageId('old-response'),
    ),
    AgentModelUsageEntry.assistant(
      sequence: 2,
      attemptId: ProviderAttemptId('tool-call-attempt'),
      model: deepSeek,
      outcome: AgentModelInvocationOutcome.completed,
      usage: LlmUsage(totalTokens: 4),
      contextRevision: 3,
      runId: RunId('tool-run'),
      turnId: TurnId('tool-call-turn'),
      retryOrdinal: 0,
      requestMessageId: AgentTranscriptMessageId('tool-request'),
      responseMessageId: AgentTranscriptMessageId('tool-call-response'),
    ),
    AgentModelUsageEntry.assistant(
      sequence: 3,
      attemptId: ProviderAttemptId('tool-answer-attempt'),
      model: deepSeek,
      outcome: AgentModelInvocationOutcome.completed,
      usage: LlmUsage(totalTokens: 5),
      contextRevision: 5,
      runId: RunId('tool-run'),
      turnId: TurnId('tool-answer-turn'),
      retryOrdinal: 0,
      requestMessageId: requestId,
      responseMessageId: responseId,
    ),
    AgentModelUsageEntry.assistant(
      sequence: 4,
      attemptId: ProviderAttemptId('overflow-attempt'),
      model: deepSeek,
      outcome: AgentModelInvocationOutcome.overflow,
      usage: LlmUsage(totalTokens: 2),
      contextRevision: 7,
      runId: RunId('retry-run'),
      turnId: TurnId('retry-turn'),
      retryOrdinal: 0,
      requestMessageId: AgentTranscriptMessageId('retry-request'),
    ),
    AgentModelUsageEntry.assistant(
      sequence: 5,
      attemptId: ProviderAttemptId('retry-attempt'),
      model: deepSeek,
      outcome: AgentModelInvocationOutcome.completed,
      usage: LlmUsage(totalTokens: 6),
      contextRevision: 9,
      runId: RunId('retry-run'),
      turnId: TurnId('retry-turn'),
      retryOrdinal: 1,
      requestMessageId: AgentTranscriptMessageId('retry-request'),
      responseMessageId: AgentTranscriptMessageId('retry-response'),
    ),
    AgentModelUsageEntry.assistant(
      sequence: 6,
      attemptId: ProviderAttemptId('failed-attempt'),
      model: deepSeek,
      outcome: AgentModelInvocationOutcome.failed,
      usage: LlmUsage(),
      contextRevision: 10,
      runId: RunId('failed-run'),
      turnId: TurnId('failed-turn'),
      retryOrdinal: 0,
      requestMessageId: AgentTranscriptMessageId('failed-request'),
    ),
    AgentModelUsageEntry.compaction(
      sequence: 7,
      attemptId: ProviderAttemptId('same-model-compaction'),
      model: deepSeek,
      outcome: AgentModelInvocationOutcome.completed,
      usage: LlmUsage(totalTokens: 7),
      contextRevision: 10,
      compactionOperationId: AgentCompactionOperationId('mixed-compaction'),
      invocationOrdinal: 0,
      runId: RunId('retry-run'),
    ),
    AgentModelUsageEntry.compaction(
      sequence: 8,
      attemptId: ProviderAttemptId('alternate-model-compaction'),
      model: alternate,
      outcome: AgentModelInvocationOutcome.cancelled,
      usage: LlmUsage(inputTokens: 8),
      contextRevision: 10,
      compactionOperationId: AgentCompactionOperationId('mixed-compaction'),
      invocationOrdinal: 1,
      runId: RunId('retry-run'),
    ),
  ];
  final tokenAccounting = AgentTokenAccountingState(
    generation: 1,
    contextRevision: 12,
    messageIds: transcript.messageIds,
    legacyBaseline: LlmUsage(totalTokens: 10),
    entries: entries,
  );
  return AgentSessionRecord(
    id: AgentSessionId('mixed-accounting'),
    revision: 0,
    definition: testDefinition(),
    transcript: transcript,
    usage: tokenAccounting.compatibilityUsage,
    modelTurns: 6,
    toolAttempts: 1,
    createdAtMicros: 1,
    updatedAtMicros: 2,
    compactionState: AgentCompactionState(
      generation: 1,
      generatedPrefixStart: 0,
      generatedPrefixCount: 1,
      reason: AgentCompactionReason.providerOverflow,
      triggerId: 'restart-trigger',
      triggerVersion: 1,
      strategyId: 'restart-summary',
      strategyVersion: 1,
      estimatorId: 'utf8-framing',
      estimatorVersion: 1,
      removedMessageCount: 8,
      beforeEstimate: 100,
      afterEstimate: 20,
      decisionMetadata: const <String, Object?>{},
      updatedAtMicros: 2,
    ),
    tokenAccounting: tokenAccounting,
  );
}

final class _DelayedReleaseClient extends http.BaseClient {
  _DelayedReleaseClient({required this.releaseDelay});

  final Duration releaseDelay;
  var released = false;
  var closed = false;
  var releasedBeforeClose = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    final controller = StreamController<List<int>>(
      onCancel: () async {
        await Future<void>.delayed(releaseDelay);
        released = true;
      },
    );
    return http.StreamedResponse(
      controller.stream,
      200,
      headers: const <String, String>{'content-type': 'text/event-stream'},
    );
  }

  @override
  void close() {
    releasedBeforeClose = released;
    closed = true;
  }
}

final class _ThrowingCloseClient extends http.BaseClient {
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnsupportedError('Network is disabled in composition tests.');
  }

  @override
  void close() {
    closed = true;
    throw StateError('client-secret');
  }
}

final class _OrderingClient extends http.BaseClient {
  InMemoryAgentRuntime? runtime;
  var closed = false;
  var closedAfterRuntime = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw UnsupportedError('Network is disabled in composition tests.');
  }

  @override
  void close() {
    closedAfterRuntime = runtime?.lifecycle == AgentRuntimeLifecycle.closed;
    closed = true;
  }
}

void _assertJsonTreeHasNoRuntimeObjects(Object? value) {
  if (value == null || value is num || value is bool || value is String) {
    return;
  }
  if (value is List) {
    for (final item in value) {
      _assertJsonTreeHasNoRuntimeObjects(item);
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      expect(entry.key, isA<String>());
      _assertJsonTreeHasNoRuntimeObjects(entry.value);
    }
    return;
  }
  fail('Serialized payload contained a runtime object: ${value.runtimeType}');
}

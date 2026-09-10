import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/domain/prompt_workspace.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/infrastructure/credentials/credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/agent_harness.dart';
import 'support/fakes.dart';

void main() {
  group('production agent composition', () {
    test('registers both wire families and eight curated models', () {
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
        <String>{'deepseek', 'moonshotai', 'openai'},
      );
      expect(stack.registry.profiles, hasLength(3));
      expect(stack.registry.models, hasLength(8));
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
        stack.runtime.profile.liveness.idleTimeout,
        AgentLivenessPolicy.defaultIdleTimeout,
      );
    });

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
          promptDefinition: stack.promptDefinition,
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
        expect(client.released, isTrue);
        expect(client.closed, isTrue);
        expect(client.releasedBeforeClose, isTrue);
        expect(stack.runtime.lifecycle, AgentRuntimeLifecycle.closed);
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
        promptDefinition: stack.promptDefinition,
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
          promptDefinition: stack.promptDefinition,
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
          BuiltInLlmCatalog.deepSeekV4Flash,
        );
        expect(stack.promptDefinition.limits?.maxModelTurns, 1);
        expect(stack.promptDefinition.limits?.maxToolCalls, 0);
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
        expect(encoded, contains('deepseek-v4-flash'));
        expect(encoded, isNot(contains('kimi-k3')));
        expect(encoded, isNot(contains('gpt-5.4')));
      },
    );
  });
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

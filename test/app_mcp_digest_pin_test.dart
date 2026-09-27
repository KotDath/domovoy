import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

import 'infrastructure/mcp/servers/arxiv/arxiv_test_support.dart';
import 'support/agent_harness.dart';
import 'support/mcp_composition_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a valid Digest v1 answer grounded in the request's papers.
  List<LlmEvent> groundedDigest(LlmRequest request) {
    final textPart = request.context.messages.last.parts
        .whereType<LlmTextPart>()
        .single;
    final payload = jsonDecode(textPart.text) as Map<String, dynamic>;
    final papers = payload['papers'] as List<dynamic>;
    return <LlmEvent>[
      LlmTextDelta(
        jsonEncode(<String, Object?>{
          'overview': 'Краткий обзор переданных аннотаций.',
          'items': <Object?>[
            for (final raw in papers)
              <String, Object?>{
                'arxivId': (raw as Map<String, dynamic>)['arxivId'],
                'finding': 'Наблюдение по аннотации.',
              },
          ],
        }),
      ),
      const LlmCompleted(finishReason: LlmFinishReason.stop),
    ];
  }

  Map<String, Object?> digestArguments() => <String, Object?>{
    'topic': 'Методы графов',
    'papers': <Object?>[paperFixture().toJson()],
  };

  const digestToolName = 'mcp_digest__summarize_papers';

  test('a per-run scope pins the model used by a local digest call', () async {
    final provider = RoutingLlmProvider(
      id: ProviderId('deepseek'),
      agentResponder: (request, index) => textTurn('ok'),
      digestResponder: (request, index) => groundedDigest(request),
    );
    final harness = await McpCompositionHarness.start(provider: provider);
    addTearDown(harness.dispose);

    final context = harness.mcp.runToolContexts.begin(
      model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    );
    expect(harness.mcp.pins.activeScopeCount, 1);

    final result = await harness.mcp.host.callTool(
      modelToolName: digestToolName,
      arguments: digestArguments(),
      requestMeta: <String, Object?>{'domovoy/runScope': context.scopeKey},
    );
    expect(
      result.isError,
      isFalse,
      reason: 'digest call failed: ${result.textContent}',
    );
    expect(
      (result.structuredContent as Map<String, Object?>?)?['topic'],
      'Методы графов',
    );
    expect(provider.digestRequests, hasLength(1));
    expect(
      provider.digestRequests.single.model,
      BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    );

    harness.mcp.runToolContexts.end(context);
    expect(harness.mcp.pins.activeScopeCount, 0);
  });

  test('absent, expired and guessed scopes fail closed', () async {
    final provider = RoutingLlmProvider(
      id: ProviderId('deepseek'),
      agentResponder: (request, index) => textTurn('ok'),
      digestResponder: (request, index) => groundedDigest(request),
    );
    final harness = await McpCompositionHarness.start(provider: provider);
    addTearDown(harness.dispose);

    final absent = await harness.mcp.host.callTool(
      modelToolName: digestToolName,
      arguments: digestArguments(),
    );
    expect(absent.isError, isTrue);
    expect(absent.textContent, contains('model_unavailable'));

    final context = harness.mcp.runToolContexts.begin(
      model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    );
    harness.mcp.runToolContexts.end(context);
    final expired = await harness.mcp.host.callTool(
      modelToolName: digestToolName,
      arguments: digestArguments(),
      requestMeta: <String, Object?>{'domovoy/runScope': context.scopeKey},
    );
    expect(expired.isError, isTrue);
    expect(expired.textContent, contains('model_unavailable'));

    final guessed = await harness.mcp.host.callTool(
      modelToolName: digestToolName,
      arguments: digestArguments(),
      requestMeta: const <String, Object?>{
        'domovoy/runScope': 'guessed-scope-key',
      },
    );
    expect(guessed.isError, isTrue);
    expect(guessed.textContent, contains('model_unavailable'));
    expect(provider.digestRequests, isEmpty);
  });

  test(
    'envelope metadata cannot select a model, only the registered pin can',
    () async {
      final provider = RoutingLlmProvider(
        id: ProviderId('deepseek'),
        agentResponder: (request, index) => textTurn('ok'),
        digestResponder: (request, index) => groundedDigest(request),
      );
      final harness = await McpCompositionHarness.start(provider: provider);
      addTearDown(harness.dispose);

      final context = harness.mcp.runToolContexts.begin(
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      );
      addTearDown(() => harness.mcp.runToolContexts.end(context));
      final result = await harness.mcp.host.callTool(
        modelToolName: digestToolName,
        arguments: digestArguments(),
        requestMeta: <String, Object?>{
          'domovoy/runScope': context.scopeKey,
          'model': <String, Object?>{
            'providerId': 'moonshotai',
            'modelId': 'kimi-k2.6',
          },
          'ModelRef': 'moonshotai/kimi-k2.6',
        },
      );
      expect(result.isError, isFalse);
      expect(
        provider.digestRequests.single.model,
        BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        reason: 'the model comes from the trusted pin, not from _meta',
      );
    },
  );

  test('two concurrent runs with different models stay isolated', () async {
    final gate = Completer<void>();
    final provider = RoutingLlmProvider(
      id: ProviderId('deepseek'),
      agentResponder: (request, index) => textTurn('ok'),
      digestResponder: (request, index) async {
        await gate.future;
        return groundedDigest(request);
      },
    );
    final moonshot = RoutingLlmProvider(
      id: ProviderId('moonshotai'),
      agentResponder: (request, index) => textTurn('ok'),
      digestResponder: (request, index) async {
        await gate.future;
        return groundedDigest(request);
      },
    );
    final harness = await McpCompositionHarness.start(provider: provider);
    addTearDown(harness.dispose);
    harness.runtime.registry.registerProvider(moonshot);

    final flash = harness.mcp.runToolContexts.begin(
      model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    );
    final kimi = harness.mcp.runToolContexts.begin(
      model: BuiltInLlmCatalog.kimiK26Model.ref,
    );
    addTearDown(() {
      harness.mcp.runToolContexts
        ..end(flash)
        ..end(kimi);
    });
    final flashCall = harness.mcp.host.callTool(
      modelToolName: digestToolName,
      arguments: digestArguments(),
      requestMeta: <String, Object?>{'domovoy/runScope': flash.scopeKey},
    );
    final kimiCall = harness.mcp.host.callTool(
      modelToolName: digestToolName,
      arguments: digestArguments(),
      requestMeta: <String, Object?>{'domovoy/runScope': kimi.scopeKey},
    );
    // Both calls are in flight and blocked inside their providers.
    await Future<void>.delayed(Duration.zero);
    expect(provider.digestRequests, hasLength(1));
    expect(moonshot.digestRequests, hasLength(1));
    expect(
      provider.digestRequests.single.model,
      BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    );
    expect(
      moonshot.digestRequests.single.model,
      BuiltInLlmCatalog.kimiK26Model.ref,
    );
    gate.complete();
    final results = await Future.wait(<Future<McpToolCallResult>>[
      flashCall,
      kimiCall,
    ]);
    expect(results.every((result) => !result.isError), isTrue);
  });

  test(
    'an agent run conveys the trusted scope and releases it at run end',
    () async {
      final provider = RoutingLlmProvider(
        id: ProviderId('deepseek'),
        agentResponder: (request, index) {
          if (index == 0) {
            return <LlmEvent>[
              ...toolTurn(
                name: digestToolName,
                callId: 'digest-1',
                arguments: jsonEncode(digestArguments()),
              ),
            ];
          }
          return textTurn('done');
        },
        digestResponder: (request, index) => groundedDigest(request),
      );
      final harness = await McpCompositionHarness.start(provider: provider);
      addTearDown(harness.dispose);
      final access = harness.mcp.feature.toolAccess;
      await access.attachScope(
        chatId: AgentSessionId('digest-agent'),
        projectId: null,
      );
      await access.toggleTool(digestToolName, true);

      final events = await harness.runSession(
        prompt: 'сделай сводку',
        enabledTools: <ToolId>[ToolId(digestToolName)],
        sessionId: AgentSessionId('digest-agent'),
        withRunContext: true,
      );
      final finished = events.whereType<AgentToolFinished>().toList();
      expect(finished, hasLength(1));
      expect(finished.single.success, isTrue);
      expect(provider.digestRequests, hasLength(1));
      // Scope released after the run settled: no dangling capability.
      expect(harness.mcp.pins.activeScopeCount, 0);
    },
  );

  test('an agent run without a scope cannot synthesize', () async {
    final provider = RoutingLlmProvider(
      id: ProviderId('deepseek'),
      agentResponder: (request, index) {
        if (index == 0) {
          return <LlmEvent>[
            ...toolTurn(
              name: digestToolName,
              callId: 'digest-no-scope',
              arguments: jsonEncode(digestArguments()),
            ),
          ];
        }
        return textTurn('done');
      },
      digestResponder: (request, index) => groundedDigest(request),
    );
    final harness = await McpCompositionHarness.start(provider: provider);
    addTearDown(harness.dispose);
    final access = harness.mcp.feature.toolAccess;
    await access.attachScope(
      chatId: AgentSessionId('digest-no-scope'),
      projectId: null,
    );
    await access.toggleTool(digestToolName, true);

    final events = await harness.runSession(
      prompt: 'сделай сводку',
      enabledTools: <ToolId>[ToolId(digestToolName)],
      sessionId: AgentSessionId('digest-no-scope'),
    );
    final finished = events.whereType<AgentToolFinished>().single;
    expect(finished.success, isFalse);
    expect(provider.digestRequests, isEmpty);
  });
}

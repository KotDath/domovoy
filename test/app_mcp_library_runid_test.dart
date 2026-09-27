import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/research/research.dart';
import 'package:flutter_test/flutter_test.dart';

import 'infrastructure/mcp/servers/arxiv/arxiv_test_support.dart';
import 'support/agent_harness.dart';
import 'support/mcp_composition_harness.dart';
import 'support/memory_jsonl_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const saveTool = 'mcp_library__save_digest';
  const listTool = 'mcp_library__list_saved';
  const getTool = 'mcp_library__get_saved';

  Map<String, Object?> saveArguments() {
    final paper = paperFixture();
    final digest = Digest(
      topic: 'Методы графов',
      overview: 'Обзор по аннотации.',
      items: <DigestItem>[
        DigestItem(
          arxivId: paper.arxivId.value,
          finding: 'Наблюдение по аннотации.',
        ),
      ],
      generatedAt: DateTime.utc(2025, 1, 7),
    );
    return <String, Object?>{
      'topic': 'Методы графов',
      'papers': <Object?>[paper.toJson()],
      'digest': digest.toJson(),
    };
  }

  Future<Map<String, Object?>> callAndReadStructured(
    McpCompositionHarness harness,
    String tool,
    Map<String, Object?> arguments,
  ) async {
    final result = await harness.mcp.host.callTool(
      modelToolName: tool,
      arguments: arguments,
    );
    expect(result.isError, isFalse, reason: result.textContent);
    return (result.structuredContent as Map).cast<String, Object?>();
  }

  test(
    'a scheduled retry reuses the application run id and does not duplicate',
    () async {
      final arguments = jsonEncode(saveArguments());
      final provider = RoutingLlmProvider(
        id: ProviderId('deepseek'),
        agentResponder: (request, index) {
          if (index < 2) {
            return <LlmEvent>[
              ...toolTurn(
                name: saveTool,
                callId: 'save-$index',
                arguments: arguments,
              ),
            ];
          }
          return textTurn('done');
        },
      );
      final harness = await McpCompositionHarness.start(provider: provider);
      addTearDown(harness.dispose);
      final access = harness.mcp.feature.toolAccess;
      final chatId = AgentSessionId('scheduled-library');
      await access.attachScope(chatId: chatId, projectId: null);
      await access.toggleTool(saveTool, true);

      final events = await harness.runSession(
        prompt: 'сохрани подборку',
        enabledTools: <ToolId>[ToolId(saveTool)],
        sessionId: chatId,
        withRunContext: true,
        bindLibraryRunId: true,
      );
      final runId = events.whereType<AgentRunStarted>().single.runId.value;
      final finished = events.whereType<AgentToolFinished>().toList();
      expect(finished, hasLength(2));
      expect(
        finished.map((event) => event.success),
        everyElement(isTrue),
        reason: 'both the save and its retry succeeded',
      );

      final listing = await callAndReadStructured(harness, listTool, {
        'limit': 10,
      });
      expect(listing['totalCount'], 1, reason: 'the retry did not duplicate');
      final cards = (listing['records'] as List).cast<Map>();
      final libraryId = cards.single['libraryId'];
      final saved = await callAndReadStructured(harness, getTool, {
        'libraryId': libraryId,
      });
      expect(saved['runId'], runId);
    },
  );

  test(
    'a model-authored run id cannot override the application run id',
    () async {
      final arguments = jsonEncode(<String, Object?>{
        ...saveArguments(),
        'runId': 'model-authored-run',
      });
      final provider = RoutingLlmProvider(
        id: ProviderId('deepseek'),
        agentResponder: (request, index) {
          if (index == 0) {
            return <LlmEvent>[
              ...toolTurn(
                name: saveTool,
                callId: 'conflict-1',
                arguments: arguments,
              ),
            ];
          }
          return textTurn('done');
        },
      );
      final harness = await McpCompositionHarness.start(provider: provider);
      addTearDown(harness.dispose);
      final access = harness.mcp.feature.toolAccess;
      final chatId = AgentSessionId('scheduled-conflict');
      await access.attachScope(chatId: chatId, projectId: null);
      await access.toggleTool(saveTool, true);

      final events = await harness.runSession(
        prompt: 'сохрани подборку',
        enabledTools: <ToolId>[ToolId(saveTool)],
        sessionId: chatId,
        withRunContext: true,
        bindLibraryRunId: true,
      );
      final finished = events.whereType<AgentToolFinished>().toList();
      expect(finished, hasLength(1));
      expect(finished.single.success, isFalse);
      final listing = await callAndReadStructured(harness, listTool, {
        'limit': 10,
      });
      expect(listing['totalCount'], 0, reason: 'nothing was written');
    },
  );

  test('interactive saves without a run id create distinct records', () async {
    final arguments = jsonEncode(saveArguments());
    final provider = RoutingLlmProvider(
      id: ProviderId('deepseek'),
      agentResponder: (request, index) {
        if (index == 0) {
          return <LlmEvent>[
            ...toolTurn(
              name: saveTool,
              callId: 'manual-$index',
              arguments: arguments,
            ),
          ];
        }
        return textTurn('done');
      },
    );
    final harness = await McpCompositionHarness.start(provider: provider);
    addTearDown(harness.dispose);
    final access = harness.mcp.feature.toolAccess;

    for (var run = 0; run < 2; run += 1) {
      // Each interactive chat grants the tool explicitly; nothing is shared.
      final chat = AgentSessionId('manual-library-$run');
      await access.attachScope(chatId: chat, projectId: null);
      await access.toggleTool(saveTool, true);
      harness.provider.resetAgentTurns();
      final events = await harness.runSession(
        prompt: 'сохрани вручную',
        enabledTools: <ToolId>[ToolId(saveTool)],
        sessionId: chat,
        withRunContext: true,
      );
      expect(events.whereType<AgentToolFinished>().single.success, isTrue);
    }

    final listing = await callAndReadStructured(harness, listTool, {
      'limit': 10,
    });
    expect(listing['totalCount'], 2);
    final cards = (listing['records'] as List).cast<Map>();
    final ids = cards.map((card) => card['libraryId']).toSet();
    expect(ids, hasLength(2), reason: 'manual saves stay distinct');
    for (final card in cards) {
      final saved = await callAndReadStructured(harness, getTool, {
        'libraryId': card['libraryId'],
      });
      expect(saved['runId'], isNull);
    }
  });

  test(
    'a library record survives a restart through the same JSONL store',
    () async {
      final libraryStorage = FakeMemoryJsonlStorage();
      final provider = RoutingLlmProvider(
        id: ProviderId('deepseek'),
        agentResponder: (request, index) {
          if (index == 0) {
            return <LlmEvent>[
              ...toolTurn(
                name: saveTool,
                callId: 'restart-save',
                arguments: jsonEncode(saveArguments()),
              ),
            ];
          }
          return textTurn('done');
        },
      );
      final first = await McpCompositionHarness.start(
        provider: provider,
        libraryStorage: libraryStorage,
      );
      final access = first.mcp.feature.toolAccess;
      final chatId = AgentSessionId('restart-library');
      await access.attachScope(chatId: chatId, projectId: null);
      await access.toggleTool(saveTool, true);
      final events = await first.runSession(
        prompt: 'сохрани',
        enabledTools: <ToolId>[ToolId(saveTool)],
        sessionId: chatId,
        withRunContext: true,
        bindLibraryRunId: true,
      );
      final savedId = events.whereType<AgentToolFinished>().single;
      expect(savedId.success, isTrue);
      await first.dispose();

      final second = await McpCompositionHarness.start(
        provider: RoutingLlmProvider(
          id: ProviderId('deepseek'),
          agentResponder: (request, index) => textTurn('ok'),
        ),
        libraryStorage: libraryStorage,
      );
      addTearDown(second.dispose);
      final listing = await callAndReadStructured(second, listTool, {
        'limit': 10,
      });
      expect(listing['totalCount'], 1);
      final cards = (listing['records'] as List).cast<Map>();
      final libraryId = cards.single['libraryId'] as String;
      expect(libraryId.trim(), isNotEmpty);
    },
  );
}

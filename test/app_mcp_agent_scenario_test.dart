import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import 'infrastructure/mcp/servers/arxiv/arxiv_test_support.dart';
import 'support/agent_harness.dart';
import 'support/mcp_composition_harness.dart';

/// The long Day 19/20 scenario: one agent run routes
/// `arxiv.search_papers -> digest.summarize_papers -> library.save_digest`
/// through three distinct local MCP servers, then proposes an automation task
/// whose scheduled run reports back with the pinned model and a chat card.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const arxivTool = 'mcp_arxiv__search_papers';
  const digestTool = 'mcp_digest__summarize_papers';
  const libraryTool = 'mcp_library__save_digest';
  const automationTool = 'mcp_automation__create_task';

  /// Extracts the latest structured tool payload of one shape from the
  /// transcript of the request, simulating how a real agent copies data from
  /// a tool result into the next call.
  Map<String, Object?>? lastStructured(LlmRequest request, String key) {
    for (final message in request.context.messages.reversed) {
      if (message.role != LlmMessageRole.tool) {
        continue;
      }
      for (final part in message.parts) {
        if (part is! LlmToolResultPart) {
          continue;
        }
        final decoded = jsonDecode(part.content);
        if (decoded is! Map) {
          continue;
        }
        final structured = decoded['structuredContent'];
        if (structured is Map && structured[key] != null) {
          return structured.cast<String, Object?>();
        }
      }
    }
    return null;
  }

  List<Object?> papersFrom(LlmRequest request) {
    final structured = lastStructured(request, 'papers');
    return (structured?['papers'] as List<Object?>?) ?? const <Object?>[];
  }

  test(
    'long agent scenario routes three servers and records the trace',
    () async {
      final clock = FakeArxivClock();
      final adapter = FakeArxivHttpAdapter(
        clock: clock,
        responder: (url, index) async => atomResponse(
          atomFeed(
            entries: <String>[
              atomEntry(
                id: 'http://arxiv.org/abs/2501.01234v1',
                title: 'Graph methods',
                summary: 'An abstract about graph methods.',
              ),
              atomEntry(
                id: 'http://arxiv.org/abs/2501.05678v2',
                title: 'Spectral embeddings',
                summary: 'An abstract about spectral embeddings.',
              ),
            ],
            totalResults: '2',
          ),
        ),
      );
      final provider = RoutingLlmProvider(
        id: ProviderId('deepseek'),
        agentResponder: (request, index) {
          switch (index) {
            case 0:
              return toolTurn(
                name: arxivTool,
                callId: 'arxiv-1',
                arguments: jsonEncode(<String, Object?>{
                  'query': 'graph methods',
                  'limit': 2,
                }),
              );
            case 1:
              return toolTurn(
                name: digestTool,
                callId: 'digest-1',
                arguments: jsonEncode(<String, Object?>{
                  'topic': 'Graph methods',
                  'papers': papersFrom(request),
                }),
              );
            case 2:
              final digest = lastStructured(request, 'items');
              return toolTurn(
                name: libraryTool,
                callId: 'library-1',
                arguments: jsonEncode(<String, Object?>{
                  'topic': 'Graph methods',
                  'papers': papersFrom(request),
                  'digest': digest,
                }),
              );
            default:
              return textTurn('Подборка сохранена.');
          }
        },
        digestResponder: (request, index) {
          final text = request.context.messages.last.parts
              .whereType<LlmTextPart>()
              .single
              .text;
          final payload = jsonDecode(text) as Map<String, dynamic>;
          final papers = payload['papers'] as List<dynamic>;
          return <LlmEvent>[
            LlmTextDelta(
              jsonEncode(<String, Object?>{
                'overview': 'Сводка по двум аннотациям.',
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
        },
      );
      final harness = await McpCompositionHarness.start(
        provider: provider,
        arxivHttpAdapter: adapter,
        arxivClock: clock,
      );
      addTearDown(harness.dispose);

      final access = harness.mcp.feature.toolAccess;
      final chatId = AgentSessionId('pipeline-chat');
      await access.attachScope(chatId: chatId, projectId: null);
      for (final tool in <String>[arxivTool, digestTool, libraryTool]) {
        await access.toggleTool(tool, true);
      }

      final events = await harness.runSession(
        prompt: 'найди работы и сохрани подборку',
        enabledTools: <ToolId>[
          ToolId(arxivTool),
          ToolId(digestTool),
          ToolId(libraryTool),
        ],
        sessionId: chatId,
        withRunContext: true,
        bindLibraryRunId: true,
      );
      final runId = events.whereType<AgentRunStarted>().single.runId.value;

      final started = events
          .whereType<AgentToolStarted>()
          .map((event) => event.name)
          .toList();
      expect(started, <String>[arxivTool, digestTool, libraryTool]);
      // Three different servers participated, in order.
      expect(started.map((name) => name.split('__').first).toSet(), <String>{
        'mcp_arxiv',
        'mcp_digest',
        'mcp_library',
      });
      expect(
        events.whereType<AgentToolFinished>().map((event) => event.success),
        everyElement(isTrue),
      );
      expect(adapter.requests, hasLength(1));

      final listing = await harness.mcp.host.callTool(
        modelToolName: 'mcp_library__list_saved',
        arguments: const <String, Object?>{'limit': 10},
      );
      final structured = (listing.structuredContent as Map)
          .cast<String, Object?>();
      expect(structured['totalCount'], 1);
      final card = (structured['records'] as List).single as Map;
      final saved = await harness.mcp.host.callTool(
        modelToolName: 'mcp_library__get_saved',
        arguments: <String, Object?>{'libraryId': card['libraryId']},
      );
      final record = (saved.structuredContent as Map).cast<String, Object?>();
      expect(record['runId'], runId);
      expect((record['papers'] as List), hasLength(2));
      expect((record['digest'] as Map)['sourceScope'], 'abstract');
    },
  );

  test(
    'automation task proposal, confirmation, run and chat delivery',
    () async {
      final clock = FakeArxivClock();
      final provider = RoutingLlmProvider(
        id: ProviderId('deepseek'),
        agentResponder: (request, index) {
          if (index == 0) {
            return toolTurn(
              name: automationTool,
              callId: 'task-1',
              arguments: jsonEncode(<String, Object?>{
                'name': 'Пятиминутная сводка',
                'prompt': 'Кратко напомни о статусе работы.',
                'cron': '*/5 * * * *',
                'timeZone': 'UTC',
                'model': 'deepseek/deepseek-v4-flash',
                'allowedTools': <String>[],
                'delivery': <String, Object?>{
                  'kind': 'chat',
                  'chatId': 'delivery-target',
                },
              }),
            );
          }
          return textTurn('Предложение задачи создано.');
        },
      );
      final harness = await McpCompositionHarness.start(
        provider: provider,
        arxivHttpAdapter: FakeArxivHttpAdapter(
          clock: clock,
          responder: (url, index) async => atomResponse(atomFeed()),
        ),
        arxivClock: clock,
      );
      addTearDown(harness.dispose);

      // The delivery target chat must exist on this device.
      await harness.sessions.save(
        AgentSessionRecord(
          id: AgentSessionId('delivery-target'),
          revision: 0,
          definition: testDefinition(),
          transcript: AgentTranscript(),
          usage: LlmUsage(),
          modelTurns: 0,
          toolAttempts: 0,
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );

      final access = harness.mcp.feature.toolAccess;
      final chatId = AgentSessionId('automation-chat');
      await access.attachScope(chatId: chatId, projectId: null);
      await access.toggleTool(automationTool, true);

      final events = await harness.runSession(
        prompt: 'поставь напоминание каждые пять минут',
        enabledTools: <ToolId>[ToolId(automationTool)],
        sessionId: chatId,
        withRunContext: true,
      );
      expect(events.whereType<AgentToolFinished>().single.success, isTrue);

      final service = harness.mcp.automation!.service;
      final proposed = (await service.listTasks(
        state: AutomationTaskState.proposed,
      )).single;
      expect(proposed.state, AutomationTaskState.proposed);
      expect((proposed.schedule as CronSchedule).expression, '*/5 * * * *');
      expect(proposed.delivery.kind, AutomationDeliveryKind.chat);
      expect(proposed.delivery.chatId, 'delivery-target');

      final confirmed = await service.confirmTask(proposed.taskId);
      expect(confirmed.state, AutomationTaskState.active);
      expect(confirmed.nextDueAt, isNotNull);

      final handle = await service.runTaskNow(confirmed.taskId);
      final run = await handle.done;
      expect(
        run.status,
        AutomationRunStatus.succeeded,
        reason: run.error?.message,
      );
      expect(run.resultText, contains('Задача выполнена по расписанию.'));
      expect(provider.scheduledRequests, hasLength(1));
      expect(
        provider.scheduledRequests.single.model,
        BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        reason: 'the scheduled run uses the task model pin',
      );
      expect(harness.mcp.pins.activeScopeCount, 0);

      final card = await harness.mcp.chatDeliveryStore!.findByRunId(
        run.runId.value,
      );
      expect(card, isNotNull);
      expect(card!.chatId, 'delivery-target');
      expect(card.status, AutomationRunStatus.succeeded);
      expect(card.resultText, contains('Задача выполнена по расписанию.'));
    },
  );
}

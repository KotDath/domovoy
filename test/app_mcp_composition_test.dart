import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/features/mcp/mcp.dart' show McpPlatformCapabilities;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'infrastructure/mcp/servers/arxiv/arxiv_test_support.dart';
import 'support/agent_harness.dart';
import 'support/automation_fakes.dart';
import 'support/mcp_composition_harness.dart';
import 'support/memory_jsonl_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RoutingLlmProvider idleProvider() => RoutingLlmProvider(
    id: ProviderId('deepseek'),
    agentResponder: (request, index) => textTurn('ok'),
  );

  FakeArxivHttpAdapter arxivAdapter(FakeArxivClock clock) {
    return FakeArxivHttpAdapter(
      clock: clock,
      responder: (url, index) async => atomResponse(
        atomFeed(
          entries: <String>[
            atomEntry(
              id: 'http://arxiv.org/abs/2501.01234v1',
              title: 'Fixture paper',
              summary: 'Fixture abstract about graphs.',
            ),
          ],
          totalResults: '1',
        ),
      ),
    );
  }

  test(
    'composes four built-in servers with distinct ids and complete catalogs',
    () async {
      final clock = FakeArxivClock();
      final harness = await McpCompositionHarness.start(
        provider: idleProvider(),
        arxivHttpAdapter: arxivAdapter(clock),
        arxivClock: clock,
      );
      addTearDown(harness.dispose);

      expect(harness.mcp.builtInConnectionIds, <String>{
        'arxiv',
        'digest',
        'library',
        'automation',
      });
      expect(harness.mcp.builtInErrors, isEmpty);

      final snapshot = harness.mcp.host.snapshot;
      final ready = snapshot.connections
          .where((status) => status.isReady)
          .map((status) => status.id.value)
          .toSet();
      expect(
        ready,
        containsAll(<String>['arxiv', 'digest', 'library', 'automation']),
      );

      final routes = snapshot.catalog.routes;
      Iterable<String> toolsOf(String connectionId) => routes
          .where((route) => route.connectionId.value == connectionId)
          .map((route) => route.originalToolName);

      expect(
        toolsOf('arxiv'),
        containsAll(<String>['search_papers', 'get_paper']),
      );
      expect(toolsOf('digest'), containsAll(<String>['summarize_papers']));
      expect(
        toolsOf('library'),
        containsAll(<String>['save_digest', 'list_saved', 'get_saved']),
      );
      expect(
        toolsOf('automation'),
        containsAll(<String>[
          'create_task',
          'list_tasks',
          'pause_task',
          'run_task_now',
        ]),
      );
      // Model-facing names are unique across the four catalogs.
      expect(
        routes.map((route) => route.modelToolName.value).toSet(),
        hasLength(routes.length),
      );
      expect(
        harness.mcp.host.isAppOwnedConnection(McpConnectionId('digest')),
        isTrue,
      );
    },
  );

  test(
    'per-chat and per-project grants gate MCP tools in the runtime',
    () async {
      final clock = FakeArxivClock();
      final adapter = arxivAdapter(clock);
      final harness = await McpCompositionHarness.start(
        provider: RoutingLlmProvider(
          id: ProviderId('deepseek'),
          agentResponder: (request, index) {
            if (index == 0) {
              return <LlmEvent>[...toolTurn(name: 'read', callId: 'pi-1')];
            }
            if (index == 1) {
              return <LlmEvent>[
                ...toolTurn(
                  name: 'mcp_arxiv__search_papers',
                  callId: 'mcp-1',
                  arguments: '{"query":"graphs","limit":2}',
                ),
              ];
            }
            return textTurn('done');
          },
        ),
        arxivHttpAdapter: adapter,
        arxivClock: clock,
      );
      addTearDown(harness.dispose);

      final access = harness.mcp.feature.toolAccess;
      final chatA = AgentSessionId('chat-a');
      final chatB = AgentSessionId('chat-b');
      await access.attachScope(chatId: chatA, projectId: null);
      await access.toggleTool('mcp_arxiv__search_papers', true);
      expect(access.effectiveToolIds(chatId: chatA), <String>[
        'mcp_arxiv__search_papers',
      ]);

      final enabled = <ToolId>[
        ToolId('read'),
        ToolId('mcp_arxiv__search_papers'),
      ];
      harness.provider
        ..resetAgentTurns()
        ..agentResponder = (request, index) {
          if (index == 0) {
            return <LlmEvent>[...toolTurn(name: 'read', callId: 'pi-1')];
          }
          if (index == 1) {
            return <LlmEvent>[
              ...toolTurn(
                name: 'mcp_arxiv__search_papers',
                callId: 'mcp-1',
                arguments: '{"query":"graphs","limit":2}',
              ),
            ];
          }
          return textTurn('done');
        };
      final granted = await harness.runSession(
        prompt: 'use both tools',
        enabledTools: enabled,
        sessionId: chatA,
      );
      expect(
        granted.whereType<AgentToolFinished>().map((event) => event.success),
        everyElement(isTrue),
      );
      expect(granted.whereType<AgentToolFinished>(), hasLength(2));
      expect(adapter.requests, hasLength(1));

      // The second chat inherits nothing: the same enabled tools are denied
      // before the server is ever called.
      final requestsBefore = adapter.requests.length;
      harness.provider
        ..resetAgentTurns()
        ..agentResponder = (request, index) {
          if (index == 0) {
            return <LlmEvent>[
              ...toolTurn(
                name: 'mcp_arxiv__search_papers',
                callId: 'denied-1',
                arguments: '{"query":"graphs","limit":2}',
              ),
            ];
          }
          return textTurn('done');
        };
      final denied = await harness.runSession(
        prompt: 'use the search tool',
        enabledTools: enabled,
        sessionId: chatB,
      );
      final deniedFinished = denied.whereType<AgentToolFinished>().toList();
      expect(deniedFinished, hasLength(1));
      expect(deniedFinished.single.success, isFalse);
      expect(adapter.requests, hasLength(requestsBefore));

      // A project grant applies to chats of that project and never to another
      // project or to a chat without one.
      final projectId = ProjectId('project-1');
      await access.attachScope(chatId: null, projectId: projectId);
      await access.toggleTool('mcp_arxiv__search_papers', true);
      harness.provider
        ..resetAgentTurns()
        ..agentResponder = (request, index) {
          if (index == 0) {
            return <LlmEvent>[
              ...toolTurn(
                name: 'mcp_arxiv__search_papers',
                callId: 'project-1',
                arguments: '{"query":"graphs","limit":2}',
              ),
            ];
          }
          return textTurn('done');
        };
      final projectRun = await harness.runSession(
        prompt: 'project scoped',
        enabledTools: enabled,
        sessionId: AgentSessionId('chat-project'),
        projectId: projectId,
      );
      expect(
        projectRun.whereType<AgentToolFinished>().map((event) => event.success),
        everyElement(isTrue),
      );
      expect(projectRun.whereType<AgentToolFinished>(), hasLength(1));
      harness.provider
        ..resetAgentTurns()
        ..agentResponder = (request, index) {
          if (index == 0) {
            return <LlmEvent>[
              ...toolTurn(
                name: 'mcp_arxiv__search_papers',
                callId: 'other-project-1',
                arguments: '{"query":"graphs","limit":2}',
              ),
            ];
          }
          return textTurn('done');
        };
      final otherProjectRun = await harness.runSession(
        prompt: 'other project',
        enabledTools: enabled,
        sessionId: AgentSessionId('chat-other-project'),
        projectId: ProjectId('project-2'),
      );
      expect(
        otherProjectRun.whereType<AgentToolFinished>().map(
          (event) => event.success,
        ),
        everyElement(isFalse),
      );
      expect(otherProjectRun.whereType<AgentToolFinished>(), hasLength(1));
      harness.provider
        ..resetAgentTurns()
        ..agentResponder = (request, index) {
          if (index == 0) {
            return <LlmEvent>[
              ...toolTurn(
                name: 'mcp_arxiv__search_papers',
                callId: 'no-project-1',
                arguments: '{"query":"graphs","limit":2}',
              ),
            ];
          }
          return textTurn('done');
        };
      final noProjectRun = await harness.runSession(
        prompt: 'no project',
        enabledTools: enabled,
        sessionId: AgentSessionId('chat-no-project'),
      );
      expect(
        noProjectRun.whereType<AgentToolFinished>().map(
          (event) => event.success,
        ),
        everyElement(isFalse),
      );
      expect(noProjectRun.whereType<AgentToolFinished>(), hasLength(1));
    },
  );

  test(
    'stored ids cannot grant Pi or unknown tools and removed routes fail closed',
    () async {
      final clock = FakeArxivClock();
      final adapter = arxivAdapter(clock);
      final harness = await McpCompositionHarness.start(
        provider: RoutingLlmProvider(
          id: ProviderId('deepseek'),
          agentResponder: (request, index) {
            if (index >= 4) {
              return textTurn('done');
            }
            return <LlmEvent>[
              ...toolTurn(
                name: <String>[
                  'read',
                  'bash',
                  'mcp_library__save_digest',
                  'mcp_arxiv__search_papers',
                ][index % 4],
                callId: 'call-$index',
                arguments: index % 4 == 3
                    ? '{"query":"graphs","limit":2}'
                    : '{}',
              ),
            ];
          },
        ),
        arxivHttpAdapter: adapter,
        arxivClock: clock,
      );
      addTearDown(harness.dispose);

      final access = harness.mcp.feature.toolAccess;
      final chatA = AgentSessionId('stored-ids');
      await access.attachScope(chatId: chatA, projectId: null);
      // Persisted ids are untrusted shape-validated strings: a stored Pi name
      // or an unknown name grants nothing beyond what the run itself
      // authorizes, and never becomes authority over another tool.
      await access.toggleTool('read', true);
      await access.toggleTool('bash', true);
      await access.toggleTool('mcp_arxiv__not_a_real_tool', true);
      await access.toggleTool('mcp_arxiv__search_papers', true);

      final enabled = <ToolId>[
        ToolId('read'),
        ToolId('bash'),
        ToolId('mcp_library__save_digest'),
        ToolId('mcp_arxiv__search_papers'),
      ];
      final events = await harness.runSession(
        prompt: 'stored ids',
        enabledTools: enabled,
        sessionId: chatA,
      );
      final finished = <String, bool>{
        for (final event in events.whereType<AgentToolFinished>())
          event.callId.value: event.success,
      };
      expect(finished['call-0'], isTrue, reason: 'Pi read stays usable');
      expect(
        finished['call-2'],
        isFalse,
        reason: 'new library tool was never granted',
      );
      expect(
        finished['call-3'],
        isTrue,
        reason: 'explicitly granted live MCP tool works',
      );

      // A stored id that is not a live route is denied by the policy itself,
      // even though the composition remembers it; it can therefore never
      // become authority over Pi tools or newly discovered MCP tools.
      final policy = harness.policies['allow']!;
      final unknownStored = policy.decide(
        ToolInvocation(
          callId: 'stored-unknown',
          name: 'mcp_arxiv__not_a_real_tool',
          arguments: const <String, Object?>{},
          sessionId: chatA,
        ),
      );
      expect(unknownStored, ToolPermission.deny);
      expect(
        policy.decide(
          ToolInvocation(
            callId: 'stored-pi',
            name: 'read',
            arguments: const <String, Object?>{},
            sessionId: chatA,
          ),
        ),
        ToolPermission.allow,
        reason: 'the Pi identity stays governed by the run definition',
      );

      // A tool that disappeared from the catalog is no longer advertised and
      // cannot be called even though the grant is still stored: a run that
      // pins the removed identity fails visibly at session creation.
      await harness.mcp.host.disconnect(McpConnectionId('arxiv'));
      expect(
        harness.mcp.host.snapshot.catalog.lookup('mcp_arxiv__search_papers'),
        isNull,
      );
      final requestsBefore = adapter.requests.length;
      await expectLater(
        harness.runSession(
          prompt: 'removed route',
          enabledTools: enabled,
          sessionId: AgentSessionId('stored-ids-2'),
        ),
        throwsA(isA<AgentException>()),
      );
      expect(adapter.requests, hasLength(requestsBefore));
      // The stored selection still shows the removed id as missing rather
      // than silently dropping or re-granting it.
      await access.attachScope(chatId: chatA, projectId: null);
      expect(
        access.state.missingSelectedToolIds,
        contains('mcp_arxiv__search_papers'),
      );
    },
  );

  test(
    'durable selections reload into the live policy after a restart',
    () async {
      final selections = FakeMemoryJsonlStorage();
      final connections = FakeMemoryJsonlStorage();

      final first = await McpCompositionHarness.start(
        provider: idleProvider(),
        selectionStorage: selections,
        connectionStorage: connections,
      );
      final chatId = AgentSessionId('restart-chat');
      await first.mcp.feature.toolAccess.attachScope(
        chatId: chatId,
        projectId: null,
      );
      await first.mcp.feature.toolAccess.toggleTool(
        'mcp_arxiv__search_papers',
        true,
      );
      expect(selections.keys, isNotEmpty);
      await first.dispose();

      final second = await McpCompositionHarness.start(
        provider: idleProvider(),
        selectionStorage: selections,
        connectionStorage: connections,
      );
      addTearDown(second.dispose);
      expect(
        second.mcp.feature.toolAccess.effectiveToolIds(chatId: chatId),
        <String>['mcp_arxiv__search_papers'],
      );
      // The live policy consults the reloaded record, not an empty default.
      final enabled = <ToolId>[
        ToolId('mcp_arxiv__search_papers'),
        ToolId('mcp_library__save_digest'),
      ];
      final events = await second.runSession(
        prompt: 'after restart',
        enabledTools: enabled,
        sessionId: chatId,
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      );
      expect(events.last, isA<AgentRunCompleted>());
    },
  );

  test('Aurora foreground policy pauses and resumes the scheduler', () async {
    final harness = await McpCompositionHarness.start(
      provider: idleProvider(),
      withLibrary: false,
      capabilities: McpPlatformCapabilities.aurora,
      pauseAutomationInBackground: true,
    );
    addTearDown(harness.dispose);
    final observer = harness.mcp.automationObserver;
    expect(observer, isNotNull);

    // The composition override is authoritative even though this test host
    // reports a desktop platform; the observer must not trust Dart platform
    // facts alone.
    expect(observer!.pauseWhenBackgrounded(), isTrue);
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(harness.mcp.automation!.service.isForeground, isFalse);
    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(harness.mcp.automation!.service.isForeground, isTrue);
  });

  test('graceful close stops servers, clients and scopes', () async {
    final harness = await McpCompositionHarness.start(provider: idleProvider());
    await harness.mcp.initialize();
    expect(harness.mcp.pins.activeScopeCount, 0);
    await harness.dispose();
    // Idempotent close: the app shell may close twice on teardown.
    await harness.mcp.close();
    expect(
      harness.mcp.host.snapshot.connections.where((status) => status.isReady),
      isEmpty,
    );
    expect(harness.mcp.host.snapshot.catalog.length, 0);
    expect(harness.mcp.localServers.isRunning('arxiv'), isFalse);
  });

  test(
    'a restart catches up exactly one missed period and never overlaps',
    () async {
      final clock = FakeAutomationClock(DateTime.utc(2026, 1, 1, 12, 0));
      final harness = await McpCompositionHarness.start(
        provider: RoutingLlmProvider(
          id: ProviderId('deepseek'),
          agentResponder: (request, index) => textTurn('ok'),
          scheduledResponder: (request, index) =>
              textTurn('Сводка по расписанию: всё в порядке.'),
        ),
        automationClock: clock,
      );
      addTearDown(harness.dispose);
      final service = harness.mcp.automation!.service;
      final task = await service.createTask(
        automationDraft(
          name: 'Catch-up',
          modelId: 'deepseek-v4-flash',
          schedule: CronSchedule(expression: '*/5 * * * *', timeZoneId: 'UTC'),
        ),
      );
      expect(task.state, AutomationTaskState.active);
      expect(task.nextDueAt, DateTime.utc(2026, 1, 1, 12, 5));

      // The app closes (or leaves the foreground) and is reopened 12 minutes
      // later: exactly one fresh run, older periods stay aggregated.
      await service.stop();
      clock.advance(const Duration(minutes: 12));
      await service.start();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var runs = await service.listRuns(task.taskId);
      bool terminal(AutomationRun run) =>
          run.status != AutomationRunStatus.running;
      while ((runs.isEmpty || !terminal(runs.single)) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        runs = await service.listRuns(task.taskId);
      }
      await service.stop();
      // Exactly one catch-up run replaced the missed periods; nothing was
      // replayed one by one.
      expect(runs, hasLength(1));
      expect(runs.single.trigger, AutomationRunTrigger.catchUp);
      expect(runs.single.status, AutomationRunStatus.succeeded);
      expect(runs.single.resultText, contains('Сводка по расписанию'));
      expect(runs.single.aggregatedSkippedCount, greaterThanOrEqualTo(1));
      expect(harness.mcp.pins.activeScopeCount, 0);
    },
  );
}

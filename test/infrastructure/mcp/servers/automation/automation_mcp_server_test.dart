import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/servers/automation/automation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../../support/automation_fakes.dart';
import '../../../../support/mcp_fakes.dart';

/// `McpServer` that captures the registered tools so their schemas and
/// callbacks can be exercised directly.
final class _RecordingMcpServer extends sdk.McpServer {
  _RecordingMcpServer()
    : super(
        const sdk.Implementation(
          name: 'automation-recording',
          version: '1.0.0',
        ),
      );

  final Map<String, sdk.RegisteredTool> tools = <String, sdk.RegisteredTool>{};
  final Map<String, sdk.ToolFunction> callbacks = <String, sdk.ToolFunction>{};

  @override
  sdk.RegisteredTool registerTool(
    String name, {
    String? title,
    String? description,
    sdk.ToolInputSchema? inputSchema,
    sdk.ToolOutputSchema? outputSchema,
    sdk.ToolAnnotations? annotations,
    Map<String, dynamic>? meta,
    required sdk.ToolFunction callback,
  }) {
    final registered = super.registerTool(
      name,
      title: title,
      description: description,
      inputSchema: inputSchema,
      outputSchema: outputSchema,
      annotations: annotations,
      meta: meta,
      callback: callback,
    );
    tools[name] = registered;
    callbacks[name] = callback;
    return registered;
  }
}

final class _AutomationHarness {
  _AutomationHarness._({
    required this.service,
    required this.repository,
    required this.clock,
    required this.executor,
    required this.factory,
    required this.server,
  });

  final AutomationService service;
  final AutomationRepository repository;
  final FakeAutomationClock clock;
  final ScriptedAutomationExecutor executor;
  final AutomationMcpServerFactory factory;
  final _RecordingMcpServer server;

  static Future<_AutomationHarness> start({
    AutomationLimits limits = const AutomationLimits(),
    DateTime? now,
    AutomationRepository? repository,
  }) async {
    final resolved = repository ?? InMemoryAutomationRepository();
    final clock = FakeAutomationClock(now ?? DateTime.utc(2026, 1, 1, 12));
    final executor = ScriptedAutomationExecutor();
    final service = AutomationService(
      tasks: resolved,
      runs: resolved,
      executor: executor,
      timeZones: automationTestZones(),
      clock: clock,
      limits: limits,
      ids: SequentialAutomationIdGenerator(),
    );
    await service.start();
    final factory = AutomationMcpServerFactory(
      service: service,
      limits: limits,
    );
    final server = _RecordingMcpServer();
    factory.create().registerTools(server);
    return _AutomationHarness._(
      service: service,
      repository: resolved,
      clock: clock,
      executor: executor,
      factory: factory,
      server: server,
    );
  }

  sdk.RegisteredTool tool(String name) {
    final tool = server.tools[name];
    if (tool == null) {
      throw StateError('Tool "$name" was not registered.');
    }
    return tool;
  }

  Future<sdk.CallToolResult> call(
    String name,
    Map<String, Object?> arguments, {
    sdk.AbortSignal? signal,
  }) {
    final callback = server.callbacks[name];
    if (callback == null) {
      throw StateError('Tool "$name" was not registered.');
    }
    return Future<sdk.CallToolResult>.sync(
      () => callback(
        Map<String, dynamic>.from(arguments),
        sdk.RequestHandlerExtra(
          signal: signal ?? sdk.BasicAbortController().signal,
          requestId: 1,
          sendNotification: (notification, {relatedTask}) async {},
          sendRequest:
              <T extends sdk.BaseResultData>(
                request,
                resultFactory,
                options,
              ) async => throw UnsupportedError('no outgoing requests'),
        ),
      ),
    );
  }

  Future<void> dispose() => service.dispose();
}

String resultText(sdk.CallToolResult result) => result.content
    .whereType<sdk.TextContent>()
    .map((block) => block.text)
    .join('\n');

void main() {
  late _AutomationHarness harness;

  setUp(() async {
    harness = await _AutomationHarness.start();
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('registration', () {
    test('registers the four tools with representable schemas', () {
      expect(harness.server.tools.keys, <String>{
        automationCreateTaskToolName,
        automationListTasksToolName,
        automationPauseTaskToolName,
        automationRunTaskNowToolName,
      });
      for (final name in harness.server.tools.keys) {
        final tool = harness.tool(name);
        for (final profile in <ToolSchemaProfile>[
          ToolSchemaProfile.openaiChatCompletions,
          ToolSchemaProfile.openaiResponses,
          ToolSchemaProfile.portable,
        ]) {
          expect(
            toolSchemaProblem(_schemaMap(tool.inputSchema), profile: profile),
            isNull,
            reason: '$name input schema for ${profile.id}',
          );
          expect(
            toolSchemaProblem(_schemaMap(tool.outputSchema!), profile: profile),
            isNull,
            reason: '$name output schema for ${profile.id}',
          );
          expect(
            representToolSchema(
              _schemaMap(tool.inputSchema),
              profile: profile,
            ).isRepresented,
            isTrue,
          );
          expect(
            representToolSchema(
              _schemaMap(tool.outputSchema!),
              profile: profile,
            ).isRepresented,
            isTrue,
          );
        }
      }
    });
  });

  group('create_task', () {
    test('proposes a cron task with three upcoming occurrences', () async {
      final result = await harness.call(
        automationCreateTaskToolName,
        <String, Object?>{
          'name': 'Сводка arXiv',
          'prompt': 'Собери свежие статьи.',
          'cron': '*/5 * * * *',
          'timeZone': 'Europe/Moscow',
          'model': 'deepseek/deepseek-v4-flash',
          'allowedTools': <String>['mcp_arxiv__search_papers'],
          'delivery': <String, Object?>{'kind': 'tasks'},
        },
      );
      expect(result.isError, isFalse);
      final structured = result.structuredContent!;
      expect(structured['state'], 'proposed');
      expect(structured['origin'], 'agent');
      expect(structured['requiresConfirmation'], isTrue);
      expect(structured['scheduleKind'], 'cron');
      expect(structured['cron'], '*/5 * * * *');
      expect(structured['timeZone'], 'Europe/Moscow');
      expect((structured['nextOccurrences']! as List<Object?>), hasLength(3));
      expect(
        firstToolSchemaValueProblem(
          _schemaMap(harness.tool(automationCreateTaskToolName).outputSchema!),
          _schemaMap(structured),
        ),
        isNull,
      );

      final stored = (await harness.repository.listTasks()).single;
      expect(stored.state, AutomationTaskState.proposed);
      expect(stored.origin, AutomationTaskOrigin.agent);
      expect(stored.allowedToolIds, <String>['mcp_arxiv__search_papers']);
      expect(resultText(result), contains('подтверждения человеком'));
    });

    test('proposes a one-shot task', () async {
      final result = await harness
          .call(automationCreateTaskToolName, <String, Object?>{
            'name': 'Напоминание',
            'prompt': 'Проверь календарь.',
            'runAt': '2026-01-01T13:00:00Z',
            'model': 'deepseek/deepseek-v4-flash',
          });
      expect(result.isError, isFalse);
      expect(result.structuredContent!['scheduleKind'], 'oneShot');
      expect(result.structuredContent!['runAt'], '2026-01-01T13:00:00.000Z');
      expect(
        (await harness.repository.listTasks()).single.schedule,
        isA<OneShotSchedule>(),
      );
    });

    test('rejects ambiguous schedules, missing zones and bad input', () async {
      Future<void> expectFailure(Map<String, Object?> args) async {
        final result = await harness.call(automationCreateTaskToolName, args);
        expect(result.isError, isTrue);
        expect(resultText(result), startsWith('[automation:'));
      }

      await expectFailure(<String, Object?>{
        'name': 'x',
        'prompt': 'y',
        'cron': '*/5 * * * *',
        'runAt': '2026-01-01T13:00:00Z',
        'model': 'deepseek/deepseek-v4-flash',
      });
      await expectFailure(<String, Object?>{
        'name': 'x',
        'prompt': 'y',
        'model': 'deepseek/deepseek-v4-flash',
      });
      await expectFailure(<String, Object?>{
        'name': 'x',
        'prompt': 'y',
        'cron': '*/5 * * * *',
        'model': 'deepseek/deepseek-v4-flash',
      });
      await expectFailure(<String, Object?>{
        'name': 'x',
        'prompt': 'y',
        'cron': 'not-a-cron',
        'timeZone': 'Europe/Moscow',
        'model': 'deepseek/deepseek-v4-flash',
      });
      await expectFailure(<String, Object?>{
        'name': 'x',
        'prompt': 'y',
        'cron': '*/5 * * * *',
        'timeZone': 'Europe/Moscow',
        'model': 'no-slash',
      });
      await expectFailure(<String, Object?>{
        'name': 'x',
        'prompt': 'y',
        'cron': '*/5 * * * *',
        'timeZone': 'Europe/Moscow',
        'model': 'deepseek/deepseek-v4-flash',
        'shell': 'rm -rf /',
      });
      expect(await harness.repository.listTasks(), isEmpty);
    });
  });

  group('list_tasks', () {
    test(
      'lists tasks with the last run summary and filters by status',
      () async {
        final created = await harness
            .call(automationCreateTaskToolName, <String, Object?>{
              'name': 'Сводка',
              'prompt': 'Собери.',
              'cron': '*/5 * * * *',
              'timeZone': 'Europe/Moscow',
              'model': 'deepseek/deepseek-v4-flash',
            });
        final taskId = created.structuredContent!['taskId']! as String;

        // A second, active task with a finished manual run.
        final active = await harness.service.createTask(automationDraft());
        final handle = await harness.service.runTaskNow(active.taskId);
        await handle.done;

        final list = await harness.call(automationListTasksToolName, const {});
        expect(list.isError, isFalse);
        final tasks = list.structuredContent!['tasks']! as List<Object?>;
        expect(tasks, hasLength(2));
        final record = tasks.first! as Map<String, Object?>;
        expect(record['taskId'], taskId);
        expect(record['state'], 'proposed');
        expect(record['cron'], '*/5 * * * *');
        final withRun = tasks.last! as Map<String, Object?>;
        final lastRun = withRun['lastRun']! as Map<String, Object?>;
        expect(lastRun['status'], 'succeeded');
        expect(lastRun['trigger'], 'manual');
        expect(
          firstToolSchemaValueProblem(
            _schemaMap(harness.tool(automationListTasksToolName).outputSchema!),
            _schemaMap(list.structuredContent!),
          ),
          isNull,
        );

        final filtered = await harness.call(
          automationListTasksToolName,
          <String, Object?>{'status': 'active'},
        );
        expect(
          (filtered.structuredContent!['tasks']! as List<Object?>),
          hasLength(1),
        );
        final bad = await harness.call(
          automationListTasksToolName,
          <String, Object?>{'status': 'nonsense'},
        );
        expect(bad.isError, isTrue);
        expect(resultText(bad), startsWith('[automation:invalid_input]'));
      },
    );
  });

  group('pause_task', () {
    test('pauses and resumes with the new revision', () async {
      final task = await harness.service.createTask(
        automationDraft(),
        origin: AutomationCallOrigin.agentTool,
      );
      await harness.service.confirmTask(task.taskId);

      final paused = await harness.call(
        automationPauseTaskToolName,
        <String, Object?>{
          'taskId': task.taskId.value,
          'paused': true,
          'expectedRevision': 1,
        },
      );
      expect(paused.isError, isFalse);
      expect(paused.structuredContent!['state'], 'paused');
      expect(paused.structuredContent!['revision'], 2);
      expect(
        firstToolSchemaValueProblem(
          _schemaMap(harness.tool(automationPauseTaskToolName).outputSchema!),
          _schemaMap(paused.structuredContent!),
        ),
        isNull,
      );

      final resumed = await harness.call(
        automationPauseTaskToolName,
        <String, Object?>{'taskId': task.taskId.value, 'paused': false},
      );
      expect(resumed.isError, isFalse);
      expect(resumed.structuredContent!['state'], 'active');
      expect(resumed.structuredContent!['nextDueAt'], isNotNull);
    });

    test('reports revision mismatches and unknown tasks', () async {
      final task = await harness.service.createTask(automationDraft());
      final mismatch = await harness.call(
        automationPauseTaskToolName,
        <String, Object?>{
          'taskId': task.taskId.value,
          'paused': true,
          'expectedRevision': 99,
        },
      );
      expect(mismatch.isError, isTrue);
      expect(
        resultText(mismatch),
        startsWith('[automation:revision_mismatch]'),
      );

      final missing = await harness.call(
        automationPauseTaskToolName,
        <String, Object?>{'taskId': 'atm_${'0' * 32}', 'paused': true},
      );
      expect(missing.isError, isTrue);
      expect(resultText(missing), startsWith('[automation:not_found]'));
    });
  });

  group('run_task_now', () {
    test('starts a manual run and keeps the planned moment', () async {
      final task = await harness.service.createTask(automationDraft());
      final planned = task.nextDueAt;
      final result = await harness.call(
        automationRunTaskNowToolName,
        <String, Object?>{'taskId': task.taskId.value},
      );
      expect(result.isError, isFalse);
      final structured = result.structuredContent!;
      expect(structured['status'], 'running');
      expect(structured['trigger'], 'manual');
      expect(
        firstToolSchemaValueProblem(
          _schemaMap(harness.tool(automationRunTaskNowToolName).outputSchema!),
          _schemaMap(structured),
        ),
        isNull,
      );
      await harness.service.waitForIdle();
      final stored = await harness.repository.findTask(task.taskId);
      expect(stored!.nextDueAt, planned);
      final run = (await harness.repository.listRuns(
        taskId: task.taskId,
      )).single;
      expect(run.status, AutomationRunStatus.succeeded);
      expect(run.trigger, AutomationRunTrigger.manual);
    });

    test('denies a proposal until a human confirms', () async {
      final proposed = await harness.service.createTask(
        automationDraft(),
        origin: AutomationCallOrigin.agentTool,
      );
      final result = await harness.call(
        automationRunTaskNowToolName,
        <String, Object?>{'taskId': proposed.taskId.value},
      );
      expect(result.isError, isTrue);
      expect(resultText(result), startsWith('[automation:denied]'));
    });

    test(
      'denies launching another task while a scheduled run is active',
      () async {
        final gate = Completer<void>();
        harness.executor.handler = (request, cancellation) async {
          await gate.future;
          return AutomationRunOutcome(
            status: AutomationRunStatus.succeeded,
            resultText: 'ok',
          );
        };
        final first = await harness.service.createTask(automationDraft());
        final other = await harness.service.createTask(
          automationDraft(
            name: 'Другая',
            schedule: AutomationSchedule.oneShot(DateTime.utc(2026, 1, 1, 13)),
          ),
        );
        harness.clock.advance(const Duration(minutes: 5));
        await harness.service.tick();
        expect(harness.service.isScheduledRunActive, isTrue);

        final result = await harness.call(
          automationRunTaskNowToolName,
          <String, Object?>{'taskId': other.taskId.value},
        );
        expect(result.isError, isTrue);
        expect(resultText(result), startsWith('[automation:denied]'));

        gate.complete();
        await harness.service.waitForIdle();
        expect(first.taskId, isNot(other.taskId));
      },
    );

    test('reports an unknown task', () async {
      final result = await harness.call(
        automationRunTaskNowToolName,
        <String, Object?>{'taskId': 'atm_${'0' * 32}'},
      );
      expect(result.isError, isTrue);
      expect(resultText(result), startsWith('[automation:not_found]'));
    });
  });

  test('an aborted call is reported as cancelled', () async {
    final controller = sdk.BasicAbortController();
    controller.abort();
    final result = await harness.call(
      automationListTasksToolName,
      const <String, Object?>{},
      signal: controller.signal,
    );
    expect(result.isError, isTrue);
    expect(resultText(result), startsWith('[automation:cancelled]'));
  });

  group('cancellation at the mutation boundary', () {
    Future<void> pump([int rounds = 12]) async {
      for (var index = 0; index < rounds; index += 1) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    Future<_AutomationHarness> gatedHarness(
      GatedAutomationRepository repository,
    ) => _AutomationHarness.start(repository: repository);

    Map<String, Object?> createArgs() => <String, Object?>{
      'name': 'Сводка',
      'prompt': 'Собери.',
      'cron': '*/5 * * * *',
      'timeZone': 'Europe/Moscow',
      'model': 'deepseek/deepseek-v4-flash',
    };

    test('create_task reports the committed proposal after an abort', () async {
      final repository = GatedAutomationRepository(
        InMemoryAutomationRepository(),
      );
      final gated = await gatedHarness(repository);
      final controller = sdk.BasicAbortController();
      repository.gate('createTask');

      final call = gated.call(
        automationCreateTaskToolName,
        createArgs(),
        signal: controller.signal,
      );
      await pump();
      expect(repository.callsFor('createTask'), 1);
      controller.abort('client cancelled');
      repository.release('createTask');

      final result = await call;
      // The committed record is the truth: no fabricated cancellation error.
      expect(result.isError, isFalse);
      expect(result.structuredContent!['state'], 'proposed');
      expect(await repository.listTasks(), hasLength(1));
      await gated.dispose();
    });

    test('create_task aborts before the commit without a proposal', () async {
      final repository = GatedAutomationRepository(
        InMemoryAutomationRepository(),
      );
      final gated = await gatedHarness(repository);
      final controller = sdk.BasicAbortController();
      final before = repository.callsFor('listTasks');
      repository.gate('listTasks');

      final call = gated.call(
        automationCreateTaskToolName,
        createArgs(),
        signal: controller.signal,
      );
      await pump();
      expect(repository.callsFor('listTasks'), before + 1);
      controller.abort('client cancelled');
      repository.release('listTasks');

      final result = await call;
      expect(result.isError, isTrue);
      expect(resultText(result), startsWith('[automation:cancelled]'));
      expect(await repository.listTasks(), isEmpty);
      await gated.dispose();
    });

    test(
      'pause_task aborts before the commit without changing the task',
      () async {
        final repository = GatedAutomationRepository(
          InMemoryAutomationRepository(),
        );
        final gated = await gatedHarness(repository);
        final task = await gated.service.createTask(automationDraft());
        final controller = sdk.BasicAbortController();
        repository.gate('findTask');

        final call = gated.call(automationPauseTaskToolName, <String, Object?>{
          'taskId': task.taskId.value,
          'paused': true,
        }, signal: controller.signal);
        await pump();
        expect(repository.callsFor('findTask'), greaterThanOrEqualTo(1));
        controller.abort('client cancelled');
        repository.release('findTask');

        final result = await call;
        expect(result.isError, isTrue);
        expect(resultText(result), startsWith('[automation:cancelled]'));
        final stored = await repository.findTask(task.taskId);
        expect(stored!.state, AutomationTaskState.active);
        await gated.dispose();
      },
    );

    test(
      'run_task_now reports the committed interrupted record after an abort',
      () async {
        final repository = GatedAutomationRepository(
          InMemoryAutomationRepository(),
        );
        final gated = await gatedHarness(repository);
        final task = await gated.service.createTask(automationDraft());
        final controller = sdk.BasicAbortController();
        repository.gate('appendRun');

        final call = gated.call(automationRunTaskNowToolName, <String, Object?>{
          'taskId': task.taskId.value,
        }, signal: controller.signal);
        await pump();
        expect(repository.callsFor('appendRun'), 1);
        controller.abort('client cancelled');
        repository.release('appendRun');

        final result = await call;
        expect(result.isError, isFalse);
        expect(result.structuredContent!['status'], 'interrupted');
        expect(
          firstToolSchemaValueProblem(
            _schemaMap(gated.tool(automationRunTaskNowToolName).outputSchema!),
            _schemaMap(result.structuredContent!),
          ),
          isNull,
        );
        expect(gated.executor.requests, isEmpty);
        final runs = await repository.listRuns(taskId: task.taskId);
        expect(runs, hasLength(1));
        expect(runs.single.status, AutomationRunStatus.interrupted);
        await gated.dispose();
      },
    );

    test('run_task_now aborts before the commit without launching', () async {
      final repository = GatedAutomationRepository(
        InMemoryAutomationRepository(),
      );
      final gated = await gatedHarness(repository);
      final task = await gated.service.createTask(automationDraft());
      final controller = sdk.BasicAbortController();
      repository.gate('findTask');

      final call = gated.call(automationRunTaskNowToolName, <String, Object?>{
        'taskId': task.taskId.value,
      }, signal: controller.signal);
      await pump();
      expect(repository.callsFor('findTask'), greaterThanOrEqualTo(1));
      controller.abort('client cancelled');
      repository.release('findTask');

      final result = await call;
      expect(result.isError, isTrue);
      expect(resultText(result), startsWith('[automation:cancelled]'));
      expect(gated.executor.requests, isEmpty);
      expect(repository.inner.runs, isEmpty);
      await gated.dispose();
    });
  });

  group('annotations', () {
    test('run_task_now is conservatively destructive', () {
      expect(
        harness.tool(automationRunTaskNowToolName).annotations!.destructiveHint,
        isTrue,
      );
      expect(
        harness.tool(automationCreateTaskToolName).annotations!.destructiveHint,
        isFalse,
      );
      expect(
        harness.tool(automationListTasksToolName).annotations!.destructiveHint,
        isFalse,
      );
      expect(
        harness.tool(automationPauseTaskToolName).annotations!.destructiveHint,
        isFalse,
      );
    });

    test('an interactive catalog grant makes run_task_now require approval', () {
      final builder = McpCatalogBuilder();
      builder.addConnection(McpConnectionId('automation'), <McpToolDescriptor>[
        scriptedTool(
          'automation',
          'run_task_now',
          annotations: const <String, Object?>{'destructiveHint': true},
        ),
      ]);
      final grant = ToolAccessGrant.forMcpCatalog(
        catalog: builder.build(),
        allowedToolIds: <String>['mcp_automation__run_task_now'],
      );
      // The annotation only adds approval; the allowlist is still the authority.
      expect(
        grant.permissionFor('mcp_automation__run_task_now'),
        ToolPermission.ask,
      );
      expect(grant.permits('mcp_automation__run_task_now'), isFalse);
      expect(grant.permits('mcp_automation__other'), isFalse);
    });
  });
}

Map<String, Object?> _schemaMap(Object? schema) {
  if (schema is Map) {
    return Map<String, Object?>.from(schema);
  }
  if (schema is sdk.JsonSchema) {
    return Map<String, Object?>.from(schema.toJson());
  }
  throw ArgumentError.value(schema, 'schema', 'Not a JSON schema.');
}

import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/infrastructure/automation/automation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

/// Delegates to a real runtime while recording the definitions and counting
/// the sessions, so "one fresh pinned session per run" is observable.
final class _RecordingRuntime implements AgentRuntime {
  _RecordingRuntime(this.inner);

  final InMemoryAgentRuntime inner;
  final List<AgentDefinition> definitions = <AgentDefinition>[];
  var sessions = 0;

  @override
  Agent agent(AgentDefinition definition) {
    definitions.add(definition);
    return _RecordingAgent(inner.agent(definition), this);
  }

  @override
  Future<void> close() => inner.close();
}

final class _RecordingAgent implements Agent {
  _RecordingAgent(this.inner, this.owner);

  final Agent inner;
  final _RecordingRuntime owner;

  @override
  AgentDefinition get definition => inner.definition;

  @override
  Future<AgentSession> createSession({
    AgentSessionId? id,
    SessionPersistence persistence = SessionPersistence.transient,
    ProjectId? projectId,
  }) {
    owner.sessions += 1;
    return inner.createSession(
      id: id,
      persistence: persistence,
      projectId: projectId,
    );
  }

  @override
  Future<AgentSession> restoreSession(AgentSessionId id) =>
      inner.restoreSession(id);

  @override
  AgentRun run(String input, {AgentRunOptions? options}) =>
      inner.run(input, options: options);

  @override
  AgentRun runTyped(LlmMessage input, {AgentRunOptions? options}) =>
      inner.runTyped(input, options: options);
}

void main() {
  late LlmProviderRegistry registry;
  late AgentToolRegistry tools;
  late Map<String, ToolPermissionPolicy> policies;
  late _RecordingRuntime runtime;
  late _RecordingRunCancellation cancellation;

  final model = BuiltInLlmCatalog.deepSeekV4FlashModel.ref;
  final createTaskToolId = McpToolNamePolicy().candidate(
    connectionId: McpConnectionId('automation'),
    originalToolName: 'create_task',
  );
  final runTaskNowToolId = McpToolNamePolicy().candidate(
    connectionId: McpConnectionId('automation'),
    originalToolName: 'run_task_now',
  );

  setUp(() {
    registry = LlmProviderRegistry();
    BuiltInLlmCatalog.registerInto(registry);
    tools = AgentToolRegistry();
    policies = <String, ToolPermissionPolicy>{
      'deny': const DenyAllPolicy(),
      'allow': const AllowAllPolicy(),
    };
    runtime = _RecordingRuntime(
      InMemoryAgentRuntime(
        registry: registry,
        tools: tools,
        policies: policies,
      ),
    );
    cancellation = _RecordingRunCancellation();
  });

  AgentSessionAutomationExecutor buildExecutor({
    LlmProvider? provider,
    ProviderCredentialResolver? credentials,
    AutomationRunLimits runLimits = const AutomationRunLimits(),
  }) {
    registry.registerProvider(
      provider ??
          QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[
              textTurn(
                'Готова сводка.',
                usage: LlmUsage(inputTokens: 10, outputTokens: 5),
              ),
            ],
          ),
    );
    return AgentSessionAutomationExecutor(
      runtime: runtime,
      models: registry,
      tools: tools,
      policies: policies,
      credentials: credentials,
      runLimits: runLimits,
    );
  }

  AutomationTask task({
    String id = 'atm_00000000000000000000000000000001',
    List<String> allowedToolIds = const <String>[],
  }) {
    return AutomationTask(
      taskId: id,
      name: 'Сводка arXiv',
      prompt: 'Собери свежие статьи.',
      schedule: AutomationSchedule.cron(
        expression: '*/5 * * * *',
        timeZoneId: 'Europe/Moscow',
      ),
      model: model,
      allowedToolIds: allowedToolIds,
      state: AutomationTaskState.active,
      origin: AutomationTaskOrigin.human,
      nextDueAt: DateTime.utc(2026, 1, 1, 12, 5),
      createdAt: DateTime.utc(2026, 1, 1, 12),
      updatedAt: DateTime.utc(2026, 1, 1, 12),
    );
  }

  AutomationRunRequest request(
    AutomationTask source, {
    String runId = 'ran_00000000000000000000000000000001',
  }) {
    return AutomationRunRequest(
      task: source,
      runId: runId,
      trigger: AutomationRunTrigger.scheduled,
      scheduledAt: DateTime.utc(2026, 1, 1, 12, 5),
    );
  }

  group('availability', () {
    test('reports an unknown model', () async {
      final executor = buildExecutor();
      final unknown = task().copyWith(
        model: ModelRef(
          providerId: ProviderId('deepseek'),
          modelId: ModelId('no-such-model'),
        ),
      );
      final availability = await executor.availability(unknown);
      expect(availability.isAvailable, isFalse);
      expect(availability.kind, AutomationRunErrorKind.modelUnavailable);
    });

    test('reports a tool that is not registered', () async {
      final executor = buildExecutor();
      final availability = await executor.availability(
        task(allowedToolIds: const <String>['mcp_missing__tool']),
      );
      expect(availability.isAvailable, isFalse);
      expect(availability.kind, AutomationRunErrorKind.toolUnavailable);
      expect(availability.message, contains('не зарегистрирован'));
    });

    test('reports a tool the registry marks unavailable', () async {
      tools.register(
        AgentTool(
          descriptor: LlmToolDescriptor(name: 'bad_tool'),
          executor: ScriptedToolExecutor(
            (invocation, {required cancellation, required liveness}) async =>
                ToolExecutionResult.success('never'),
          ),
          unavailableReason: 'схема не представима',
        ),
      );
      final executor = buildExecutor();
      final availability = await executor.availability(
        task(allowedToolIds: const <String>['bad_tool']),
      );
      expect(availability.isAvailable, isFalse);
      expect(availability.kind, AutomationRunErrorKind.toolUnavailable);
      expect(availability.message, contains('схема не представима'));
    });

    test('reports a missing provider secret', () async {
      final executor = buildExecutor(
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(),
          readEnvironment: (_) => null,
        ),
      );
      final availability = await executor.availability(task());
      expect(availability.isAvailable, isFalse);
      expect(availability.kind, AutomationRunErrorKind.secretUnavailable);
    });

    test('is available with a model, tools and a stored key', () async {
      tools.register(
        AgentTool(
          descriptor: LlmToolDescriptor(name: 'search'),
          executor: ScriptedToolExecutor(
            (invocation, {required cancellation, required liveness}) async =>
                ToolExecutionResult.success(<String, Object?>{'ok': true}),
          ),
        ),
      );
      final executor = buildExecutor(
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(<ProviderId, String>{
            BuiltInLlmCatalog.deepSeek: 'sk-test',
          }),
          readEnvironment: (_) => null,
        ),
      );
      final availability = await executor.availability(
        task(allowedToolIds: const <String>['search']),
      );
      expect(availability.isAvailable, isTrue);
    });
  });

  group('execution', () {
    test('pins the definition and starts one fresh session per run', () async {
      final executor = buildExecutor();
      final source = task();
      final outcome = await executor.execute(
        request(source),
        cancellation: cancellation,
      );
      expect(outcome.status, AutomationRunStatus.succeeded);
      expect(outcome.resultText, contains('Готова сводка'));
      expect(outcome.modelTurns, greaterThanOrEqualTo(1));
      expect(runtime.sessions, 1);

      final definition = runtime.definitions.single;
      expect(definition.model, model);
      expect(definition.interactiveApproval, isFalse);
      expect(definition.policy.value, source.policyId);
      expect(definition.systemPrompt, automationScheduledSystemPrompt);
      expect(definition.systemPrompt, contains('по расписанию'));
      final grant = policies[source.policyId]! as ToolAccessPolicy;
      expect(grant.grant.isUnattended, isTrue);
      expect(grant.grant.permits(createTaskToolId), isFalse);
      expect(grant.grant.permits(runTaskNowToolId), isFalse);

      // A second run gets its own definition and session.
      final second = await executor.execute(
        request(source, runId: 'ran_00000000000000000000000000000002'),
        cancellation: _RecordingRunCancellation(),
      );
      expect(second.status, AutomationRunStatus.succeeded);
      expect(runtime.sessions, 2);
      expect(runtime.definitions, hasLength(2));
      expect(runtime.definitions[0].id, isNot(runtime.definitions[1].id));
    });

    test('traces a tool call and counts it', () async {
      final toolExecutor = ScriptedToolExecutor(
        (invocation, {required cancellation, required liveness}) async =>
            ToolExecutionResult.success(<String, Object?>{'papers': 1}),
      );
      tools.register(
        AgentTool(
          descriptor: LlmToolDescriptor(name: 'search'),
          executor: toolExecutor,
        ),
      );
      final executor = buildExecutor(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            toolTurn(name: 'search', callId: 'call-1', arguments: '{}'),
            textTurn('Нашёл одну статью.'),
          ],
        ),
      );
      final outcome = await executor.execute(
        request(task(allowedToolIds: const <String>['search'])),
        cancellation: cancellation,
      );
      expect(outcome.status, AutomationRunStatus.succeeded);
      expect(outcome.resultText, contains('Нашёл одну статью'));
      expect(outcome.toolCalls, 1);
      expect(toolExecutor.executions, 1);
      expect(outcome.trace.single.name, 'search');
      expect(outcome.trace.single.status, AutomationToolTraceStatus.succeeded);
    });

    test(
      'the scheduled grant denies automation task control even when allowed',
      () async {
        final executors = <String, ScriptedToolExecutor>{
          for (final toolId in <String>[createTaskToolId, runTaskNowToolId])
            toolId: ScriptedToolExecutor(
              (invocation, {required cancellation, required liveness}) async =>
                  ToolExecutionResult.success('unexpected'),
            ),
        };
        for (final entry in executors.entries) {
          tools.register(
            AgentTool(
              descriptor: LlmToolDescriptor(name: entry.key),
              executor: entry.value,
            ),
          );
        }
        final executor = buildExecutor(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[
              toolTurn(
                name: createTaskToolId,
                callId: 'call-1',
                arguments: '{}',
              ),
              textTurn('Инструмент отклонён.'),
              toolTurn(
                name: runTaskNowToolId,
                callId: 'call-2',
                arguments: '{}',
              ),
              textTurn('Инструмент отклонён.'),
            ],
          ),
        );
        for (final toolId in <String>[createTaskToolId, runTaskNowToolId]) {
          final outcome = await executor.execute(
            request(task(allowedToolIds: <String>[toolId])),
            cancellation: cancellation,
          );
          expect(executors[toolId]!.executions, 0, reason: toolId);
          expect(
            outcome.trace.single.status,
            AutomationToolTraceStatus.denied,
            reason: toolId,
          );
          expect(outcome.status, AutomationRunStatus.succeeded, reason: toolId);
        }
      },
    );

    test('a tool-call limit stops the run visibly', () async {
      tools.register(
        AgentTool(
          descriptor: LlmToolDescriptor(name: 'search'),
          executor: ScriptedToolExecutor(
            (invocation, {required cancellation, required liveness}) async =>
                ToolExecutionResult.success('ok'),
          ),
        ),
      );
      final executor = buildExecutor(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            toolTurn(name: 'search', callId: 'call-1', arguments: '{}'),
            toolTurn(name: 'search', callId: 'call-2', arguments: '{}'),
            textTurn('Готово.'),
          ],
        ),
        runLimits: const AutomationRunLimits(maxToolCalls: 1),
      );
      final outcome = await executor.execute(
        request(task(allowedToolIds: const <String>['search'])),
        cancellation: cancellation,
      );
      expect(outcome.status, AutomationRunStatus.failed);
      expect(outcome.error!.kind, AutomationRunErrorKind.limits);
      expect(outcome.error!.message, contains('лимит'));
    });

    test('cancellation stops the run and reports interrupted', () async {
      final executor = buildExecutor(
        provider: _HangingLlmProvider(id: BuiltInLlmCatalog.deepSeek),
      );
      final future = executor.execute(
        request(task()),
        cancellation: cancellation,
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      final outcome = await future;
      expect(outcome.status, AutomationRunStatus.interrupted);
      expect(outcome.error!.kind, AutomationRunErrorKind.interrupted);
    });

    test('a cancelled-before-start request never opens a session', () async {
      final executor = buildExecutor();
      final preCancelled = _RecordingRunCancellation()..cancel();
      final outcome = await executor.execute(
        request(task()),
        cancellation: preCancelled,
      );
      expect(outcome.status, AutomationRunStatus.interrupted);
      expect(runtime.sessions, 0);
    });
  });
}

final class _RecordingRunCancellation implements AutomationResultCancellation {
  final Completer<void> _cancelled = Completer<void>();
  var _isCancelled = false;

  @override
  bool get isCancelled => _isCancelled;

  @override
  Future<void> get whenCancelled => _cancelled.future;

  @override
  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _cancelled.complete();
  }
}

/// Provider whose stream never produces a terminal event.
final class _HangingLlmProvider implements LlmProvider {
  _HangingLlmProvider({required this.id});

  @override
  final ProviderId id;

  @override
  LlmWireFamily get wireFamily => LlmWireFamily.openaiChatCompletions;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) {
    final controller = StreamController<LlmEvent>();
    cancellation.register(() => controller.close());
    return controller.stream;
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';

final class QueueScriptedLlmProvider implements LlmProvider {
  QueueScriptedLlmProvider({
    required this.id,
    required this.wireFamily,
    required this.turns,
  });

  @override
  final ProviderId id;

  @override
  final LlmWireFamily wireFamily;

  final List<List<LlmEvent>> turns;
  final List<LlmRequest> requests = <LlmRequest>[];
  var _index = 0;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    requests.add(request);
    if (cancellation.isCancelled) {
      yield const LlmCancelled();
      return;
    }
    final events = _index < turns.length
        ? turns[_index++]
        : const <LlmEvent>[LlmCompleted(finishReason: LlmFinishReason.stop)];
    for (final event in events) {
      if (cancellation.isCancelled) {
        yield const LlmCancelled();
        return;
      }
      yield event;
      if (event.isTerminal) {
        return;
      }
    }
    yield const LlmCompleted(finishReason: LlmFinishReason.stop);
  }
}

final class ScriptedToolExecutor implements AgentToolExecutor {
  ScriptedToolExecutor(this.handler);

  final Future<ToolExecutionResult> Function(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  })
  handler;
  var executions = 0;

  @override
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  }) {
    executions += 1;
    return handler(invocation, cancellation: cancellation, liveness: liveness);
  }
}

AgentDefinition testDefinition({
  ModelRef? model,
  List<ToolId>? tools,
  PolicyId? policy,
  AgentRunLimits? limits,
  AgentLivenessPolicy? liveness,
  AgentNoProgressPolicy? noProgress,
  AgentTokenBudget? budget,
  String systemPrompt = 'You are a test agent.',
}) {
  return AgentDefinition(
    id: AgentId('tester'),
    name: 'Tester',
    systemPrompt: systemPrompt,
    model: model ?? BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    enabledTools: tools ?? const <ToolId>[],
    policy: policy ?? PolicyId('allow'),
    limits: limits,
    liveness: liveness,
    noProgress: noProgress,
    budget: budget,
  );
}

InMemoryAgentRuntime testRuntime({
  required LlmProvider provider,
  AgentToolRegistry? tools,
  Map<String, ToolPermissionPolicy>? policies,
  ToolApprovalHandler? approval,
  AgentSessionRepository? repository,
  InMemorySessionRouter? router,
  AgentClock? clock,
  List<AgentLifecycleHook>? hooks,
  AgentRunLimits? profileLimits,
  AgentRuntimeProfile? profile,
  AgentPersistencePolicy? persistencePolicy,
}) {
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  registry.registerProvider(provider);
  return InMemoryAgentRuntime(
    registry: registry,
    tools: tools,
    policies: policies,
    approval: approval,
    repository: repository,
    router: router,
    clock: clock,
    hooks: hooks ?? const <AgentLifecycleHook>[],
    profileLimits: profileLimits,
    profile: profile,
    persistencePolicy: persistencePolicy,
  );
}

List<LlmEvent> textTurn(String text, {LlmUsage? usage}) {
  return <LlmEvent>[
    LlmTextDelta(text),
    if (usage != null) LlmUsageUpdate(usage),
    LlmCompleted(finishReason: LlmFinishReason.stop, usage: usage),
  ];
}

List<LlmEvent> toolTurn({
  required String name,
  required String callId,
  String arguments = '{}',
  String? answer,
}) {
  return <LlmEvent>[
    if (answer != null) LlmTextDelta(answer),
    LlmToolCallDelta(
      callId: ToolCallId(callId),
      index: 0,
      name: name,
      argumentsFragment: arguments,
    ),
    const LlmCompleted(finishReason: LlmFinishReason.toolCalls),
  ];
}

String jsonObject(Map<String, Object?> value) => jsonEncode(value);

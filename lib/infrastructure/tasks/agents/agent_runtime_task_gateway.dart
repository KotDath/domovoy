import 'dart:async';
import 'dart:convert';

import '../../../core/agents/agents.dart';
import '../../../core/tasks/tasks.dart';

final class AgentRuntimeTaskGateway implements TaskAgentGateway {
  AgentRuntimeTaskGateway({
    required this.runtime,
    required this.baseDefinition,
    AgentIdFactory? ids,
  }) : ids = ids ?? AgentIdFactory(prefix: 'task-agent');

  final AgentRuntime runtime;
  final AgentDefinition baseDefinition;
  final AgentIdFactory ids;
  AgentRun? _activeRun;

  @override
  Future<TaskInvariantReview> reviewInvariants({
    required String candidate,
    required List<TaskInvariantRule> rules,
  }) async {
    if (rules.isEmpty) return TaskInvariantReview();
    final value = await _invokeJson(
      role: 'invariant-reviewer',
      systemPrompt:
          'Check the candidate only against the supplied invariants. '
          'Return JSON {"violations":[{"ruleId":"...","reason":"..."}]}. '
          'Use an empty list when allowed. Do not reveal chain-of-thought.',
      payload: <String, Object?>{
        'candidate': candidate,
        'invariants': rules.map((rule) => rule.toJson()).toList(),
      },
    );
    final raw = value['violations'];
    if (raw is! List<Object?>) {
      throw const FormatException('Invariant review has no violations list.');
    }
    return TaskInvariantReview(
      violations: raw.map((item) {
        final map = (item! as Map<Object?, Object?>).cast<String, Object?>();
        return TaskInvariantViolation(
          ruleId: map['ruleId']! as String,
          reason: map['reason']! as String,
        );
      }).toList(),
    );
  }

  @override
  Future<TaskPlan> preparePlan({
    required String goal,
    required List<TaskInvariantRule> rules,
  }) async {
    final value = await _invokeJson(
      role: 'planner',
      systemPrompt:
          'Create a directed acyclic plan with 1 to 6 nodes. Return only JSON '
          '{"nodes":[{"id":"short-id","title":"...",'
          '"instructions":"...","acceptanceCriteria":"...",'
          '"dependencies":["id"]}]}. Respect every invariant. Do not execute.',
      payload: <String, Object?>{
        'goal': goal,
        'invariants': rules.map((rule) => rule.toJson()).toList(),
      },
    );
    return TaskPlan.fromJson(value);
  }

  @override
  Future<String> executeNode({
    required String goal,
    required TaskPlan plan,
    required TaskPlanNode node,
    required Map<TaskNodeId, String> dependencyOutputs,
    required List<TaskInvariantRule> rules,
    String? previousOutput,
    String? rejectionEvidence,
  }) => _invokeText(
    role: 'worker-${node.id.value}',
    systemPrompt:
        'Execute only the supplied plan node. Return the Markdown result, not '
        'JSON. Respect every invariant. You have no tools and no chat history.',
    payload: <String, Object?>{
      'goal': goal,
      'approvedPlan': plan.toJson(),
      'node': node.toJson(),
      'dependencyOutputs': <String, String>{
        for (final entry in dependencyOutputs.entries)
          entry.key.value: entry.value,
      },
      'invariants': rules.map((rule) => rule.toJson()).toList(),
      'previousOutput': ?previousOutput,
      'rejectionEvidence': ?rejectionEvidence,
    },
  );

  @override
  Future<TaskVerification> verifyNode({
    required String goal,
    required TaskPlan plan,
    required TaskPlanNode node,
    required String output,
    required List<TaskInvariantRule> rules,
  }) async {
    final value = await _invokeJson(
      role: 'verifier-${node.id.value}',
      systemPrompt:
          'Verify the node result against its acceptance criteria and every '
          'invariant. Return only JSON '
          '{"accepted":true|false,"evidence":"concise explanation"}.',
      payload: <String, Object?>{
        'goal': goal,
        'approvedPlan': plan.toJson(),
        'node': node.toJson(),
        'output': output,
        'invariants': rules.map((rule) => rule.toJson()).toList(),
      },
    );
    return _verification(value);
  }

  @override
  Future<String> composeFinal({
    required String goal,
    required TaskPlan plan,
    required Map<TaskNodeId, String> outputs,
    required List<TaskInvariantRule> rules,
    String? previousOutput,
    String? rejectionEvidence,
  }) => _invokeText(
    role: 'final-composer',
    systemPrompt:
        'Compose the final Markdown answer from the verified node outputs. '
        'Respect every invariant. You have no tools and no chat history.',
    payload: <String, Object?>{
      'goal': goal,
      'approvedPlan': plan.toJson(),
      'verifiedOutputs': <String, String>{
        for (final entry in outputs.entries) entry.key.value: entry.value,
      },
      'invariants': rules.map((rule) => rule.toJson()).toList(),
      'previousOutput': ?previousOutput,
      'rejectionEvidence': ?rejectionEvidence,
    },
  );

  @override
  Future<TaskVerification> verifyFinal({
    required String goal,
    required TaskPlan plan,
    required String output,
    required List<TaskInvariantRule> rules,
  }) async {
    final value = await _invokeJson(
      role: 'final-verifier',
      systemPrompt:
          'Verify that the final answer satisfies the goal, approved plan, and '
          'every invariant. Return only JSON '
          '{"accepted":true|false,"evidence":"concise explanation"}.',
      payload: <String, Object?>{
        'goal': goal,
        'approvedPlan': plan.toJson(),
        'output': output,
        'invariants': rules.map((rule) => rule.toJson()).toList(),
      },
    );
    return _verification(value);
  }

  @override
  Future<void> cancelActive() async {
    await _activeRun?.cancel();
  }

  TaskVerification _verification(Map<String, Object?> value) {
    final accepted = value['accepted'];
    final evidence = value['evidence'];
    if (accepted is! bool || evidence is! String || evidence.trim().isEmpty) {
      throw const FormatException('Invalid verification response.');
    }
    return TaskVerification(accepted: accepted, evidence: evidence.trim());
  }

  Future<Map<String, Object?>> _invokeJson({
    required String role,
    required String systemPrompt,
    required Map<String, Object?> payload,
  }) async {
    final text = await _invokeText(
      role: role,
      systemPrompt: systemPrompt,
      payload: payload,
    );
    final normalized = _extractJson(text);
    final decoded = jsonDecode(normalized);
    if (decoded is! Map) throw const FormatException('Expected a JSON object.');
    return decoded.cast<String, Object?>();
  }

  Future<String> _invokeText({
    required String role,
    required String systemPrompt,
    required Map<String, Object?> payload,
  }) async {
    if (_activeRun != null) {
      throw StateError('A task-agent invocation is already active.');
    }
    final definition = AgentDefinition(
      id: AgentId(ids.next(role)),
      name: 'Task $role',
      systemPrompt: systemPrompt,
      model: baseDefinition.model,
      generation: baseDefinition.generation,
      enabledTools: const <ToolId>[],
      policy: PolicyId('deny'),
      limits: baseDefinition.limits,
      liveness: baseDefinition.liveness,
      noProgress: baseDefinition.noProgress,
      budget: baseDefinition.budget,
    );
    final run = runtime
        .agent(definition)
        .run(
          jsonEncode(payload),
          options: AgentRunOptions(includeDynamicContext: false),
        );
    _activeRun = run;
    final answer = StringBuffer();
    try {
      await for (final event in run.events) {
        switch (event) {
          case AgentAnswerDelta(:final text):
            answer.write(text);
          case AgentRunFailed(:final error):
            throw StateError(error.message);
          case AgentRunStopped():
            throw StateError('Task-agent invocation stopped.');
          case AgentRunCancelled():
            throw StateError('Task-agent invocation cancelled.');
          default:
            break;
        }
      }
    } finally {
      if (identical(_activeRun, run)) _activeRun = null;
    }
    final result = answer.toString().trim();
    if (result.isEmpty) throw const FormatException('Empty task-agent result.');
    return result;
  }

  String _extractJson(String value) {
    final start = value.indexOf('{');
    final end = value.lastIndexOf('}');
    if (start < 0 || end < start) {
      throw const FormatException('Task-agent result has no JSON object.');
    }
    return value.substring(start, end + 1);
  }
}

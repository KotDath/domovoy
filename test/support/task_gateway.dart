import 'dart:async';

import 'package:domovoy/core/tasks/tasks.dart';

final class FakeTaskAgentGateway implements TaskAgentGateway {
  final List<String> calls = <String>[];
  Completer<void>? executionGate;
  var cancelCount = 0;

  @override
  Future<void> cancelActive() async {
    cancelCount += 1;
    executionGate?.complete();
    executionGate = null;
  }

  @override
  Future<String> composeFinal({
    required String goal,
    required TaskPlan plan,
    required Map<TaskNodeId, String> outputs,
    required List<TaskInvariantRule> rules,
    String? previousOutput,
    String? rejectionEvidence,
  }) async {
    calls.add('compose');
    return 'Готовый ответ';
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
  }) async {
    calls.add('execute:${node.id.value}');
    final gate = executionGate;
    if (gate != null) await gate.future;
    return 'Результат шага';
  }

  @override
  Future<TaskPlan> preparePlan({
    required String goal,
    required List<TaskInvariantRule> rules,
  }) async {
    calls.add('plan');
    return TaskPlan(<TaskPlanNode>[
      TaskPlanNode(
        id: const TaskNodeId('work'),
        title: 'Выполнить задачу',
        instructions: 'Подготовить результат.',
        acceptanceCriteria: 'Результат готов.',
      ),
    ]);
  }

  @override
  Future<TaskInvariantReview> reviewInvariants({
    required String candidate,
    required List<TaskInvariantRule> rules,
  }) async => TaskInvariantReview();

  @override
  Future<TaskVerification> verifyFinal({
    required String goal,
    required TaskPlan plan,
    required String output,
    required List<TaskInvariantRule> rules,
  }) async =>
      const TaskVerification(accepted: true, evidence: 'Финал проверен.');

  @override
  Future<TaskVerification> verifyNode({
    required String goal,
    required TaskPlan plan,
    required TaskPlanNode node,
    required String output,
    required List<TaskInvariantRule> rules,
  }) async => const TaskVerification(accepted: true, evidence: 'Шаг проверен.');
}

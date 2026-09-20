import 'invariants.dart';
import 'ids.dart';
import 'model.dart';

final class TaskInvariantReview {
  TaskInvariantReview({
    List<TaskInvariantViolation> violations = const <TaskInvariantViolation>[],
  }) : violations = List<TaskInvariantViolation>.unmodifiable(violations);

  final List<TaskInvariantViolation> violations;

  bool get isAllowed => violations.isEmpty;
}

final class TaskVerification {
  const TaskVerification({required this.accepted, required this.evidence});

  final bool accepted;
  final String evidence;
}

/// Isolated LLM boundary used by the controlled task scheduler.
///
/// Every method represents a fresh bounded invocation. Implementations must not
/// inherit the chat transcript and must expose no mutating tools.
abstract interface class TaskAgentGateway {
  Future<TaskInvariantReview> reviewInvariants({
    required String candidate,
    required List<TaskInvariantRule> rules,
  });

  Future<TaskPlan> preparePlan({
    required String goal,
    required List<TaskInvariantRule> rules,
  });

  Future<String> executeNode({
    required String goal,
    required TaskPlan plan,
    required TaskPlanNode node,
    required Map<TaskNodeId, String> dependencyOutputs,
    required List<TaskInvariantRule> rules,
    String? previousOutput,
    String? rejectionEvidence,
  });

  Future<TaskVerification> verifyNode({
    required String goal,
    required TaskPlan plan,
    required TaskPlanNode node,
    required String output,
    required List<TaskInvariantRule> rules,
  });

  Future<String> composeFinal({
    required String goal,
    required TaskPlan plan,
    required Map<TaskNodeId, String> outputs,
    required List<TaskInvariantRule> rules,
    String? previousOutput,
    String? rejectionEvidence,
  });

  Future<TaskVerification> verifyFinal({
    required String goal,
    required TaskPlan plan,
    required String output,
    required List<TaskInvariantRule> rules,
  });

  Future<void> cancelActive();
}

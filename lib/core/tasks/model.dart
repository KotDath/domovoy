import 'ids.dart';
import 'invariants.dart';

enum TaskPhase { planning, execution, validation, done }

enum TaskNodeStatus {
  pending,
  ready,
  running,
  verifying,
  repairing,
  succeeded,
  failed,
  interrupted,
}

enum TaskExpectedAction {
  captureGoal,
  preparePlan,
  approvePlan,
  runNode,
  verifyNode,
  repairNode,
  composeFinal,
  validateFinal,
  resume,
  resolveFailure,
  none,
}

final class TaskPlanNode {
  TaskPlanNode({
    required this.id,
    required this.title,
    required this.instructions,
    required this.acceptanceCriteria,
    List<TaskNodeId> dependencies = const <TaskNodeId>[],
  }) : dependencies = List<TaskNodeId>.unmodifiable(dependencies) {
    if (title.trim().isEmpty) throw ArgumentError.value(title, 'title');
    if (instructions.trim().isEmpty) {
      throw ArgumentError.value(instructions, 'instructions');
    }
    if (acceptanceCriteria.trim().isEmpty) {
      throw ArgumentError.value(acceptanceCriteria, 'acceptanceCriteria');
    }
  }

  final TaskNodeId id;
  final String title;
  final String instructions;
  final String acceptanceCriteria;
  final List<TaskNodeId> dependencies;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id.value,
    'title': title,
    'instructions': instructions,
    'acceptanceCriteria': acceptanceCriteria,
    'dependencies': dependencies.map((id) => id.value).toList(),
  };

  factory TaskPlanNode.fromJson(Map<String, Object?> json) => TaskPlanNode(
    id: TaskNodeId.parse(json['id']! as String),
    title: json['title']! as String,
    instructions: json['instructions']! as String,
    acceptanceCriteria: json['acceptanceCriteria']! as String,
    dependencies: (json['dependencies']! as List<Object?>)
        .cast<String>()
        .map(TaskNodeId.parse)
        .toList(),
  );
}

final class TaskPlan {
  TaskPlan(List<TaskPlanNode> nodes)
    : nodes = List<TaskPlanNode>.unmodifiable(nodes) {
    validate();
  }

  static const maximumNodes = 6;
  final List<TaskPlanNode> nodes;

  void validate() {
    if (nodes.isEmpty || nodes.length > maximumNodes) {
      throw const FormatException(
        'Task plan must contain between 1 and 6 nodes.',
      );
    }
    final ids = <TaskNodeId>{};
    for (final node in nodes) {
      if (!ids.add(node.id)) {
        throw FormatException('Duplicate task node: ${node.id.value}.');
      }
    }
    for (final node in nodes) {
      for (final dependency in node.dependencies) {
        if (!ids.contains(dependency)) {
          throw FormatException(
            'Unknown dependency ${dependency.value} for ${node.id.value}.',
          );
        }
        if (dependency == node.id) {
          throw FormatException(
            'Task node ${node.id.value} depends on itself.',
          );
        }
      }
    }
    topologicalOrder();
  }

  List<TaskPlanNode> topologicalOrder() {
    final byId = <TaskNodeId, TaskPlanNode>{
      for (final node in nodes) node.id: node,
    };
    final permanent = <TaskNodeId>{};
    final temporary = <TaskNodeId>{};
    final ordered = <TaskPlanNode>[];

    void visit(TaskNodeId id) {
      if (permanent.contains(id)) return;
      if (!temporary.add(id)) {
        throw const FormatException('Task plan contains a dependency cycle.');
      }
      final node = byId[id]!;
      for (final dependency in node.dependencies) {
        visit(dependency);
      }
      temporary.remove(id);
      permanent.add(id);
      ordered.add(node);
    }

    for (final node in nodes) {
      visit(node.id);
    }
    return List<TaskPlanNode>.unmodifiable(ordered);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'nodes': nodes.map((node) => node.toJson()).toList(),
  };

  factory TaskPlan.fromJson(Map<String, Object?> json) => TaskPlan(
    (json['nodes']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(TaskPlanNode.fromJson)
        .toList(),
  );
}

final class TaskNodeState {
  const TaskNodeState({
    required this.id,
    required this.status,
    this.output,
    this.verificationEvidence,
    this.attempt = 0,
    this.repairCount = 0,
  });

  final TaskNodeId id;
  final TaskNodeStatus status;
  final String? output;
  final String? verificationEvidence;
  final int attempt;
  final int repairCount;

  TaskNodeState copyWith({
    TaskNodeStatus? status,
    Object? output = _keep,
    Object? verificationEvidence = _keep,
    int? attempt,
    int? repairCount,
  }) => TaskNodeState(
    id: id,
    status: status ?? this.status,
    output: identical(output, _keep) ? this.output : output as String?,
    verificationEvidence: identical(verificationEvidence, _keep)
        ? this.verificationEvidence
        : verificationEvidence as String?,
    attempt: attempt ?? this.attempt,
    repairCount: repairCount ?? this.repairCount,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id.value,
    'status': status.name,
    'output': output,
    'verificationEvidence': verificationEvidence,
    'attempt': attempt,
    'repairCount': repairCount,
  };

  factory TaskNodeState.fromJson(Map<String, Object?> json) => TaskNodeState(
    id: TaskNodeId.parse(json['id']! as String),
    status: TaskNodeStatus.values.byName(json['status']! as String),
    output: json['output'] as String?,
    verificationEvidence: json['verificationEvidence'] as String?,
    attempt: json['attempt']! as int,
    repairCount: json['repairCount']! as int,
  );
}

const _keep = Object();

final class TaskSnapshot {
  TaskSnapshot({
    required this.id,
    required this.sessionId,
    required this.phase,
    required this.revision,
    required this.createdAtMicros,
    required this.updatedAtMicros,
    this.projectId,
    this.goal,
    this.plan,
    this.planApproved = false,
    List<TaskNodeState> nodes = const <TaskNodeState>[],
    this.currentNodeId,
    this.finalOutput,
    this.finalValidationEvidence,
    this.finalAttempt = 0,
    this.finalRepairCount = 0,
    this.paused = false,
    this.cancelled = false,
    this.failureCode,
    this.failureMessage,
    List<String> appliedInvariantIds = const <String>[],
    List<TaskInvariantPolicyStamp> appliedPolicyStamps =
        const <TaskInvariantPolicyStamp>[],
  }) : nodes = List<TaskNodeState>.unmodifiable(nodes),
       appliedInvariantIds = List<String>.unmodifiable(appliedInvariantIds),
       appliedPolicyStamps = List<TaskInvariantPolicyStamp>.unmodifiable(
         appliedPolicyStamps,
       );

  factory TaskSnapshot.initial({
    required TaskId id,
    required String sessionId,
    String? projectId,
    required int nowMicros,
  }) => TaskSnapshot(
    id: id,
    sessionId: sessionId,
    projectId: projectId,
    phase: TaskPhase.planning,
    revision: 0,
    createdAtMicros: nowMicros,
    updatedAtMicros: nowMicros,
  );

  final TaskId id;
  final String sessionId;
  final String? projectId;
  final TaskPhase phase;
  final int revision;
  final int createdAtMicros;
  final int updatedAtMicros;
  final String? goal;
  final TaskPlan? plan;
  final bool planApproved;
  final List<TaskNodeState> nodes;
  final TaskNodeId? currentNodeId;
  final String? finalOutput;
  final String? finalValidationEvidence;
  final int finalAttempt;
  final int finalRepairCount;
  final bool paused;
  final bool cancelled;
  final String? failureCode;
  final String? failureMessage;
  final List<String> appliedInvariantIds;
  final List<TaskInvariantPolicyStamp> appliedPolicyStamps;

  int get completedNodeCount =>
      nodes.where((node) => node.status == TaskNodeStatus.succeeded).length;

  int get totalNodeCount => nodes.length;

  TaskExpectedAction get expectedAction {
    if (cancelled || phase == TaskPhase.done) return TaskExpectedAction.none;
    if (paused) return TaskExpectedAction.resume;
    if (failureCode != null) return TaskExpectedAction.resolveFailure;
    return switch (phase) {
      TaskPhase.planning when goal == null => TaskExpectedAction.captureGoal,
      TaskPhase.planning when plan == null => TaskExpectedAction.preparePlan,
      TaskPhase.planning => TaskExpectedAction.approvePlan,
      TaskPhase.execution => _executionExpectedAction,
      TaskPhase.validation when finalOutput == null =>
        TaskExpectedAction.composeFinal,
      TaskPhase.validation => TaskExpectedAction.validateFinal,
      TaskPhase.done => TaskExpectedAction.none,
    };
  }

  TaskExpectedAction get _executionExpectedAction {
    final current = nodes.where((node) {
      return node.status == TaskNodeStatus.running ||
          node.status == TaskNodeStatus.verifying ||
          node.status == TaskNodeStatus.repairing;
    }).firstOrNull;
    return switch (current?.status) {
      TaskNodeStatus.running => TaskExpectedAction.runNode,
      TaskNodeStatus.verifying => TaskExpectedAction.verifyNode,
      TaskNodeStatus.repairing => TaskExpectedAction.repairNode,
      _ => TaskExpectedAction.runNode,
    };
  }

  TaskSnapshot copyWith({
    TaskPhase? phase,
    int? revision,
    int? updatedAtMicros,
    Object? goal = _keep,
    Object? plan = _keep,
    bool? planApproved,
    List<TaskNodeState>? nodes,
    Object? currentNodeId = _keep,
    Object? finalOutput = _keep,
    Object? finalValidationEvidence = _keep,
    int? finalAttempt,
    int? finalRepairCount,
    bool? paused,
    bool? cancelled,
    Object? failureCode = _keep,
    Object? failureMessage = _keep,
    List<String>? appliedInvariantIds,
    List<TaskInvariantPolicyStamp>? appliedPolicyStamps,
  }) => TaskSnapshot(
    id: id,
    sessionId: sessionId,
    projectId: projectId,
    phase: phase ?? this.phase,
    revision: revision ?? this.revision,
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros ?? this.updatedAtMicros,
    goal: identical(goal, _keep) ? this.goal : goal as String?,
    plan: identical(plan, _keep) ? this.plan : plan as TaskPlan?,
    planApproved: planApproved ?? this.planApproved,
    nodes: nodes ?? this.nodes,
    currentNodeId: identical(currentNodeId, _keep)
        ? this.currentNodeId
        : currentNodeId as TaskNodeId?,
    finalOutput: identical(finalOutput, _keep)
        ? this.finalOutput
        : finalOutput as String?,
    finalValidationEvidence: identical(finalValidationEvidence, _keep)
        ? this.finalValidationEvidence
        : finalValidationEvidence as String?,
    finalAttempt: finalAttempt ?? this.finalAttempt,
    finalRepairCount: finalRepairCount ?? this.finalRepairCount,
    paused: paused ?? this.paused,
    cancelled: cancelled ?? this.cancelled,
    failureCode: identical(failureCode, _keep)
        ? this.failureCode
        : failureCode as String?,
    failureMessage: identical(failureMessage, _keep)
        ? this.failureMessage
        : failureMessage as String?,
    appliedInvariantIds: appliedInvariantIds ?? this.appliedInvariantIds,
    appliedPolicyStamps: appliedPolicyStamps ?? this.appliedPolicyStamps,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'id': id.value,
    'sessionId': sessionId,
    'projectId': projectId,
    'phase': phase.name,
    'revision': revision,
    'createdAtMicros': createdAtMicros,
    'updatedAtMicros': updatedAtMicros,
    'goal': goal,
    'plan': plan?.toJson(),
    'planApproved': planApproved,
    'nodes': nodes.map((node) => node.toJson()).toList(),
    'currentNodeId': currentNodeId?.value,
    'finalOutput': finalOutput,
    'finalValidationEvidence': finalValidationEvidence,
    'finalAttempt': finalAttempt,
    'finalRepairCount': finalRepairCount,
    'paused': paused,
    'cancelled': cancelled,
    'failureCode': failureCode,
    'failureMessage': failureMessage,
    'appliedInvariantIds': appliedInvariantIds,
    'appliedPolicyStamps': appliedPolicyStamps
        .map((stamp) => stamp.toJson())
        .toList(),
  };

  factory TaskSnapshot.fromJson(Map<String, Object?> json) {
    try {
      if (json['schemaVersion'] != 1) {
        throw const FormatException('Unsupported task snapshot version.');
      }
      final snapshot = TaskSnapshot(
        id: TaskId.parse(json['id']! as String),
        sessionId: json['sessionId']! as String,
        projectId: json['projectId'] as String?,
        phase: TaskPhase.values.byName(json['phase']! as String),
        revision: json['revision']! as int,
        createdAtMicros: json['createdAtMicros']! as int,
        updatedAtMicros: json['updatedAtMicros']! as int,
        goal: json['goal'] as String?,
        plan: json['plan'] == null
            ? null
            : TaskPlan.fromJson(
                (json['plan']! as Map<Object?, Object?>)
                    .cast<String, Object?>(),
              ),
        planApproved: json['planApproved']! as bool,
        nodes: (json['nodes']! as List<Object?>)
            .map(
              (value) => TaskNodeState.fromJson(
                (value! as Map<Object?, Object?>).cast<String, Object?>(),
              ),
            )
            .toList(),
        currentNodeId: json['currentNodeId'] == null
            ? null
            : TaskNodeId.parse(json['currentNodeId']! as String),
        finalOutput: json['finalOutput'] as String?,
        finalValidationEvidence: json['finalValidationEvidence'] as String?,
        finalAttempt: json['finalAttempt']! as int,
        finalRepairCount: json['finalRepairCount']! as int,
        paused: json['paused']! as bool,
        cancelled: json['cancelled']! as bool,
        failureCode: json['failureCode'] as String?,
        failureMessage: json['failureMessage'] as String?,
        appliedInvariantIds: (json['appliedInvariantIds']! as List<Object?>)
            .cast<String>(),
        appliedPolicyStamps:
            (json['appliedPolicyStamps'] as List<Object?>? ?? <Object?>[])
                .map(
                  (value) => TaskInvariantPolicyStamp.fromJson(
                    (value! as Map<Object?, Object?>).cast<String, Object?>(),
                  ),
                )
                .toList(),
      );
      snapshot.validate();
      return snapshot;
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid task snapshot.', error);
    }
  }

  void validate() {
    if (sessionId.trim().isEmpty ||
        revision < 0 ||
        createdAtMicros < 0 ||
        updatedAtMicros < createdAtMicros ||
        finalAttempt < 0 ||
        finalRepairCount < 0 ||
        finalRepairCount > 1) {
      throw const FormatException('Invalid task snapshot metadata.');
    }
    if (plan == null) {
      if (planApproved || nodes.isNotEmpty || currentNodeId != null) {
        throw const FormatException('Task state requires a plan.');
      }
    } else {
      final planIds = plan!.nodes.map((node) => node.id).toSet();
      final stateIds = nodes.map((node) => node.id).toSet();
      if (nodes.length != plan!.nodes.length ||
          stateIds.length != nodes.length ||
          !stateIds.containsAll(planIds) ||
          !planIds.containsAll(stateIds)) {
        throw const FormatException('Task nodes do not match the plan.');
      }
      if (currentNodeId != null && !stateIds.contains(currentNodeId)) {
        throw const FormatException('Current task node is unknown.');
      }
    }
    final policyKeys = appliedPolicyStamps
        .map((stamp) => '${stamp.scope.name}:${stamp.ownerId}')
        .toSet();
    if (policyKeys.length != appliedPolicyStamps.length) {
      throw const FormatException('Duplicate applied invariant policy stamp.');
    }
    final active = nodes.where((node) {
      return node.status == TaskNodeStatus.running ||
          node.status == TaskNodeStatus.verifying ||
          node.status == TaskNodeStatus.repairing;
    }).toList();
    if (active.length > 1 ||
        active.any((node) => node.id != currentNodeId) ||
        nodes.any(
          (node) =>
              node.attempt < 0 ||
              node.repairCount < 0 ||
              node.repairCount > 1 ||
              (node.status == TaskNodeStatus.verifying &&
                  (node.output?.trim().isEmpty ?? true)) ||
              (node.status == TaskNodeStatus.succeeded &&
                  ((node.output?.trim().isEmpty ?? true) ||
                      (node.verificationEvidence?.trim().isEmpty ?? true))),
        )) {
      throw const FormatException('Invalid task node state.');
    }
    if (phase != TaskPhase.planning && (!planApproved || plan == null)) {
      throw const FormatException('Task phase requires an approved plan.');
    }
    if ((phase == TaskPhase.validation || phase == TaskPhase.done) &&
        nodes.any((node) => node.status != TaskNodeStatus.succeeded)) {
      throw const FormatException('Validation requires successful nodes.');
    }
    if (phase == TaskPhase.done &&
        ((finalOutput?.trim().isEmpty ?? true) ||
            (finalValidationEvidence?.trim().isEmpty ?? true))) {
      throw const FormatException('Done task requires validation evidence.');
    }
  }
}

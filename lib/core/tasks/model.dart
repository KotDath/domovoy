import 'ids.dart';

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
    id: TaskNodeId(json['id']! as String),
    title: json['title']! as String,
    instructions: json['instructions']! as String,
    acceptanceCriteria: json['acceptanceCriteria']! as String,
    dependencies: (json['dependencies']! as List<Object?>)
        .cast<String>()
        .map(TaskNodeId.new)
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
  });

  final TaskNodeId id;
  final TaskNodeStatus status;
  final String? output;
  final String? verificationEvidence;
  final int attempt;

  TaskNodeState copyWith({
    TaskNodeStatus? status,
    Object? output = _keep,
    Object? verificationEvidence = _keep,
    int? attempt,
  }) => TaskNodeState(
    id: id,
    status: status ?? this.status,
    output: identical(output, _keep) ? this.output : output as String?,
    verificationEvidence: identical(verificationEvidence, _keep)
        ? this.verificationEvidence
        : verificationEvidence as String?,
    attempt: attempt ?? this.attempt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id.value,
    'status': status.name,
    'output': output,
    'verificationEvidence': verificationEvidence,
    'attempt': attempt,
  };

  factory TaskNodeState.fromJson(Map<String, Object?> json) => TaskNodeState(
    id: TaskNodeId(json['id']! as String),
    status: TaskNodeStatus.values.byName(json['status']! as String),
    output: json['output'] as String?,
    verificationEvidence: json['verificationEvidence'] as String?,
    attempt: json['attempt']! as int,
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
    this.paused = false,
    this.cancelled = false,
    this.failureCode,
    this.failureMessage,
    List<String> appliedInvariantIds = const <String>[],
  }) : nodes = List<TaskNodeState>.unmodifiable(nodes),
       appliedInvariantIds = List<String>.unmodifiable(appliedInvariantIds);

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
  final bool paused;
  final bool cancelled;
  final String? failureCode;
  final String? failureMessage;
  final List<String> appliedInvariantIds;

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
    final current = currentNodeId == null
        ? null
        : nodes.where((node) => node.id == currentNodeId).firstOrNull;
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
    bool? paused,
    bool? cancelled,
    Object? failureCode = _keep,
    Object? failureMessage = _keep,
    List<String>? appliedInvariantIds,
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
    paused: paused ?? this.paused,
    cancelled: cancelled ?? this.cancelled,
    failureCode: identical(failureCode, _keep)
        ? this.failureCode
        : failureCode as String?,
    failureMessage: identical(failureMessage, _keep)
        ? this.failureMessage
        : failureMessage as String?,
    appliedInvariantIds: appliedInvariantIds ?? this.appliedInvariantIds,
  );

  Map<String, Object?> toJson() => <String, Object?>{
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
    'paused': paused,
    'cancelled': cancelled,
    'failureCode': failureCode,
    'failureMessage': failureMessage,
    'appliedInvariantIds': appliedInvariantIds,
  };

  factory TaskSnapshot.fromJson(Map<String, Object?> json) => TaskSnapshot(
    id: TaskId(json['id']! as String),
    sessionId: json['sessionId']! as String,
    projectId: json['projectId'] as String?,
    phase: TaskPhase.values.byName(json['phase']! as String),
    revision: json['revision']! as int,
    createdAtMicros: json['createdAtMicros']! as int,
    updatedAtMicros: json['updatedAtMicros']! as int,
    goal: json['goal'] as String?,
    plan: json['plan'] == null
        ? null
        : TaskPlan.fromJson(json['plan']! as Map<String, Object?>),
    planApproved: json['planApproved']! as bool,
    nodes: (json['nodes']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(TaskNodeState.fromJson)
        .toList(),
    currentNodeId: json['currentNodeId'] == null
        ? null
        : TaskNodeId(json['currentNodeId']! as String),
    finalOutput: json['finalOutput'] as String?,
    finalValidationEvidence: json['finalValidationEvidence'] as String?,
    paused: json['paused']! as bool,
    cancelled: json['cancelled']! as bool,
    failureCode: json['failureCode'] as String?,
    failureMessage: json['failureMessage'] as String?,
    appliedInvariantIds: (json['appliedInvariantIds']! as List<Object?>)
        .cast<String>(),
  );
}

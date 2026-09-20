import 'ids.dart';
import 'model.dart';

enum TaskTransitionKind {
  goalCaptured,
  planProposed,
  planApproved,
  executionStarted,
  nodeStarted,
  nodeVerificationStarted,
  nodeSucceeded,
  nodeRepairStarted,
  nodeFailed,
  validationStarted,
  finalComposed,
  finalValidated,
  finalRepairStarted,
  finalFailed,
  paused,
  resumed,
  replanned,
  cancelled,
  interrupted,
}

enum TaskTransitionFailureCode {
  planApprovalRequired,
  invalidTransition,
  validationRequired,
  invariantViolation,
  taskPaused,
  revisionConflict,
  replanRequired,
  repairExhausted,
}

extension TaskTransitionFailureCodeWire on TaskTransitionFailureCode {
  String get wireName => switch (this) {
    TaskTransitionFailureCode.planApprovalRequired => 'PLAN_APPROVAL_REQUIRED',
    TaskTransitionFailureCode.invalidTransition => 'INVALID_TRANSITION',
    TaskTransitionFailureCode.validationRequired => 'VALIDATION_REQUIRED',
    TaskTransitionFailureCode.invariantViolation => 'INVARIANT_VIOLATION',
    TaskTransitionFailureCode.taskPaused => 'TASK_PAUSED',
    TaskTransitionFailureCode.revisionConflict => 'REVISION_CONFLICT',
    TaskTransitionFailureCode.replanRequired => 'REPLAN_REQUIRED',
    TaskTransitionFailureCode.repairExhausted => 'REPAIR_EXHAUSTED',
  };
}

final class TaskTransition {
  const TaskTransition({
    required this.kind,
    required this.expectedRevision,
    required this.occurredAtMicros,
    this.nodeId,
    this.text,
    this.plan,
    this.evidence,
    this.invariantIds = const <String>[],
  });

  final TaskTransitionKind kind;
  final int expectedRevision;
  final int occurredAtMicros;
  final TaskNodeId? nodeId;
  final String? text;
  final TaskPlan? plan;
  final String? evidence;
  final List<String> invariantIds;
}

final class TaskTransitionResult {
  const TaskTransitionResult.accepted(this.snapshot)
    : failureCode = null,
      message = null;

  const TaskTransitionResult.rejected(this.failureCode, this.message)
    : snapshot = null;

  final TaskSnapshot? snapshot;
  final TaskTransitionFailureCode? failureCode;
  final String? message;

  bool get isAccepted => snapshot != null;
}

final class TaskReducer {
  const TaskReducer();

  TaskTransitionResult reduce(TaskSnapshot current, TaskTransition transition) {
    if (transition.expectedRevision != current.revision) {
      return const TaskTransitionResult.rejected(
        TaskTransitionFailureCode.revisionConflict,
        'Состояние задачи изменилось. Обновите данные и повторите действие.',
      );
    }
    if (current.cancelled || current.phase == TaskPhase.done) {
      return const TaskTransitionResult.rejected(
        TaskTransitionFailureCode.invalidTransition,
        'Завершённая задача не допускает новых переходов.',
      );
    }
    if (current.paused &&
        transition.kind != TaskTransitionKind.resumed &&
        transition.kind != TaskTransitionKind.interrupted &&
        transition.kind != TaskTransitionKind.cancelled) {
      return const TaskTransitionResult.rejected(
        TaskTransitionFailureCode.taskPaused,
        'Задача приостановлена. Сначала возобновите её.',
      );
    }

    final result = switch (transition.kind) {
      TaskTransitionKind.goalCaptured => _captureGoal(current, transition),
      TaskTransitionKind.planProposed => _proposePlan(current, transition),
      TaskTransitionKind.planApproved => _approvePlan(current),
      TaskTransitionKind.executionStarted => _startExecution(current),
      TaskTransitionKind.nodeStarted => _startNode(current, transition),
      TaskTransitionKind.nodeVerificationStarted => _startNodeVerification(
        current,
        transition,
      ),
      TaskTransitionKind.nodeSucceeded => _succeedNode(current, transition),
      TaskTransitionKind.nodeRepairStarted => _repairNode(current, transition),
      TaskTransitionKind.nodeFailed => _failNode(current, transition),
      TaskTransitionKind.validationStarted => _startValidation(current),
      TaskTransitionKind.finalComposed => _composeFinal(current, transition),
      TaskTransitionKind.finalValidated => _validateFinal(current, transition),
      TaskTransitionKind.finalRepairStarted => _repairFinal(
        current,
        transition,
      ),
      TaskTransitionKind.finalFailed => _failFinal(current, transition),
      TaskTransitionKind.paused => _pause(current),
      TaskTransitionKind.resumed => _resume(current),
      TaskTransitionKind.replanned => _replan(current, transition),
      TaskTransitionKind.cancelled => _cancel(current),
      TaskTransitionKind.interrupted => _interrupt(current),
    };
    if (!result.isAccepted) return result;
    return TaskTransitionResult.accepted(
      result.snapshot!.copyWith(
        revision: current.revision + 1,
        updatedAtMicros: transition.occurredAtMicros,
      ),
    );
  }

  TaskTransitionResult _captureGoal(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    if (current.phase != TaskPhase.planning || current.goal != null) {
      return _invalid('Цель можно задать только один раз в начале planning.');
    }
    final text = transition.text?.trim() ?? '';
    if (text.isEmpty) return _invalid('Цель задачи не может быть пустой.');
    return _accepted(current.copyWith(goal: text));
  }

  TaskTransitionResult _proposePlan(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    if (current.phase != TaskPhase.planning || current.goal == null) {
      return _invalid('План можно предложить только после фиксации цели.');
    }
    final plan = transition.plan;
    if (plan == null) return _invalid('Переход не содержит план.');
    return _accepted(
      current.copyWith(
        plan: plan,
        planApproved: false,
        nodes: plan.nodes
            .map(
              (node) =>
                  TaskNodeState(id: node.id, status: TaskNodeStatus.pending),
            )
            .toList(),
        currentNodeId: null,
        finalOutput: null,
        finalValidationEvidence: null,
        finalAttempt: 0,
        finalRepairCount: 0,
        failureCode: null,
        failureMessage: null,
        appliedInvariantIds: transition.invariantIds,
      ),
    );
  }

  TaskTransitionResult _approvePlan(TaskSnapshot current) {
    if (current.phase != TaskPhase.planning || current.plan == null) {
      return _invalid('Нет плана, доступного для утверждения.');
    }
    return _accepted(current.copyWith(planApproved: true));
  }

  TaskTransitionResult _startExecution(TaskSnapshot current) {
    if (current.phase != TaskPhase.planning || !current.planApproved) {
      return const TaskTransitionResult.rejected(
        TaskTransitionFailureCode.planApprovalRequired,
        'Нельзя начать реализацию до утверждения плана.',
      );
    }
    final first = current.plan!.topologicalOrder().first.id;
    return _accepted(
      current.copyWith(
        phase: TaskPhase.execution,
        nodes: _markReadyNodes(current.nodes, current.plan!),
        currentNodeId: first,
      ),
    );
  }

  TaskTransitionResult _startNode(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    if (current.phase != TaskPhase.execution) {
      return _invalid('Узел можно запустить только на этапе execution.');
    }
    final node = _node(current, transition.nodeId);
    final activeElsewhere = current.nodes.any(
      (item) =>
          item.id != transition.nodeId &&
          (item.status == TaskNodeStatus.running ||
              item.status == TaskNodeStatus.verifying ||
              item.status == TaskNodeStatus.repairing),
    );
    if (node == null || node.status != TaskNodeStatus.ready) {
      return _invalid('Узел не готов к выполнению.');
    }
    if (activeElsewhere) {
      return _invalid('Последовательный workflow уже выполняет другой узел.');
    }
    return _accepted(
      current.copyWith(
        currentNodeId: node.id,
        nodes: _replace(
          current.nodes,
          node.copyWith(
            status: TaskNodeStatus.running,
            attempt: node.attempt + 1,
            output: null,
            verificationEvidence: null,
          ),
        ),
      ),
    );
  }

  TaskTransitionResult _startNodeVerification(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    final node = _node(current, transition.nodeId);
    if (current.phase != TaskPhase.execution ||
        node == null ||
        current.currentNodeId != node.id ||
        (node.status != TaskNodeStatus.running &&
            node.status != TaskNodeStatus.repairing) ||
        (transition.text?.trim().isEmpty ?? true)) {
      return _invalid('Проверка требует результат работающего узла.');
    }
    return _accepted(
      current.copyWith(
        nodes: _replace(
          current.nodes,
          node.copyWith(
            status: TaskNodeStatus.verifying,
            output: transition.text!.trim(),
          ),
        ),
      ),
    );
  }

  TaskTransitionResult _succeedNode(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    final node = _node(current, transition.nodeId);
    if (current.phase != TaskPhase.execution ||
        node == null ||
        node.status != TaskNodeStatus.verifying ||
        (transition.evidence?.trim().isEmpty ?? true)) {
      return _invalid('Узел можно завершить только после проверки с evidence.');
    }
    final succeeded = node.copyWith(
      status: TaskNodeStatus.succeeded,
      verificationEvidence: transition.evidence!.trim(),
    );
    final nextNodes = _markReadyNodes(
      _replace(current.nodes, succeeded),
      current.plan!,
    );
    final next = current.plan!
        .topologicalOrder()
        .map(
          (planNode) => nextNodes.firstWhere((item) => item.id == planNode.id),
        )
        .where((item) => item.status == TaskNodeStatus.ready)
        .firstOrNull;
    return _accepted(
      current.copyWith(
        nodes: nextNodes,
        currentNodeId: next?.id,
        failureCode: null,
        failureMessage: null,
      ),
    );
  }

  TaskTransitionResult _repairNode(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    final node = _node(current, transition.nodeId);
    if (node == null || node.status != TaskNodeStatus.verifying) {
      return _invalid('Repair доступен только после отклонённой проверки.');
    }
    if (node.repairCount >= 1) {
      return const TaskTransitionResult.rejected(
        TaskTransitionFailureCode.repairExhausted,
        'Единственная repair-попытка уже использована.',
      );
    }
    return _accepted(
      current.copyWith(
        nodes: _replace(
          current.nodes,
          node.copyWith(
            status: TaskNodeStatus.repairing,
            attempt: node.attempt + 1,
            repairCount: node.repairCount + 1,
            verificationEvidence: transition.evidence,
          ),
        ),
      ),
    );
  }

  TaskTransitionResult _failNode(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    final node = _node(current, transition.nodeId);
    if (node == null || node.status != TaskNodeStatus.verifying) {
      return _invalid('Текущий узел нельзя перевести в failed.');
    }
    if (node.repairCount < 1 || (transition.evidence?.trim().isEmpty ?? true)) {
      return _invalid(
        'Failed доступен только после repair-попытки с evidence.',
      );
    }
    return _accepted(
      current.copyWith(
        nodes: _replace(
          current.nodes,
          node.copyWith(
            status: TaskNodeStatus.failed,
            verificationEvidence: transition.evidence,
          ),
        ),
        failureCode: TaskTransitionFailureCode.repairExhausted.wireName,
        failureMessage:
            transition.text ?? 'Результат повторно не прошёл проверку.',
      ),
    );
  }

  TaskTransitionResult _startValidation(TaskSnapshot current) {
    if (current.phase != TaskPhase.execution ||
        current.nodes.isEmpty ||
        current.nodes.any((node) => node.status != TaskNodeStatus.succeeded)) {
      return const TaskTransitionResult.rejected(
        TaskTransitionFailureCode.validationRequired,
        'Финал недоступен, пока не завершены и не проверены все узлы.',
      );
    }
    return _accepted(
      current.copyWith(phase: TaskPhase.validation, currentNodeId: null),
    );
  }

  TaskTransitionResult _composeFinal(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    if (current.phase != TaskPhase.validation ||
        current.finalOutput != null ||
        (transition.text?.trim().isEmpty ?? true)) {
      return _invalid('Финальный результат создаётся только в validation.');
    }
    return _accepted(
      current.copyWith(
        finalOutput: transition.text!.trim(),
        finalAttempt: current.finalAttempt + 1,
      ),
    );
  }

  TaskTransitionResult _repairFinal(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    if (current.phase != TaskPhase.validation || current.finalOutput == null) {
      return _invalid('Repair финала требует проверяемый результат.');
    }
    if (current.finalRepairCount >= 1) {
      return const TaskTransitionResult.rejected(
        TaskTransitionFailureCode.repairExhausted,
        'Единственная repair-попытка финала уже использована.',
      );
    }
    return _accepted(
      current.copyWith(
        finalOutput: null,
        finalRepairCount: current.finalRepairCount + 1,
        failureMessage: transition.evidence,
      ),
    );
  }

  TaskTransitionResult _failFinal(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    if (current.phase != TaskPhase.validation ||
        current.finalOutput == null ||
        current.finalRepairCount < 1 ||
        (transition.evidence?.trim().isEmpty ?? true)) {
      return _invalid('Финал можно отклонить только после repair-попытки.');
    }
    return _accepted(
      current.copyWith(
        failureCode: TaskTransitionFailureCode.repairExhausted.wireName,
        failureMessage: transition.evidence!.trim(),
      ),
    );
  }

  TaskTransitionResult _validateFinal(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    if (current.phase != TaskPhase.validation ||
        current.finalOutput == null ||
        (transition.evidence?.trim().isEmpty ?? true)) {
      return const TaskTransitionResult.rejected(
        TaskTransitionFailureCode.validationRequired,
        'Done требует финальный результат и validation evidence.',
      );
    }
    return _accepted(
      current.copyWith(
        phase: TaskPhase.done,
        finalValidationEvidence: transition.evidence!.trim(),
      ),
    );
  }

  TaskTransitionResult _pause(TaskSnapshot current) {
    if (current.paused) return _invalid('Задача уже приостановлена.');
    return _accepted(
      current.copyWith(
        paused: true,
        nodes: _interruptActiveNodes(current.nodes),
      ),
    );
  }

  TaskTransitionResult _resume(TaskSnapshot current) {
    if (!current.paused) return _invalid('Задача не приостановлена.');
    final rearmed = current.plan == null
        ? current.nodes
        : _markReadyNodes(current.nodes, current.plan!);
    final next = current.plan
        ?.topologicalOrder()
        .map((node) => rearmed.firstWhere((state) => state.id == node.id))
        .where((state) => state.status == TaskNodeStatus.ready)
        .firstOrNull;
    return _accepted(
      current.copyWith(paused: false, nodes: rearmed, currentNodeId: next?.id),
    );
  }

  TaskTransitionResult _replan(
    TaskSnapshot current,
    TaskTransition transition,
  ) {
    final goal = transition.text?.trim();
    return _accepted(
      current.copyWith(
        phase: TaskPhase.planning,
        goal: goal == null || goal.isEmpty ? current.goal : goal,
        plan: null,
        planApproved: false,
        nodes: const <TaskNodeState>[],
        currentNodeId: null,
        finalOutput: null,
        finalValidationEvidence: null,
        finalAttempt: 0,
        finalRepairCount: 0,
        failureCode: null,
        failureMessage: null,
      ),
    );
  }

  TaskTransitionResult _cancel(TaskSnapshot current) {
    return _accepted(current.copyWith(cancelled: true, paused: false));
  }

  TaskTransitionResult _interrupt(TaskSnapshot current) {
    final nextNodes = _interruptActiveNodes(current.nodes);
    if (identical(nextNodes, current.nodes)) {
      return _invalid('В задаче нет незавершённого вызова для восстановления.');
    }
    return _accepted(
      current.copyWith(nodes: nextNodes, paused: true, currentNodeId: null),
    );
  }

  List<TaskNodeState> _interruptActiveNodes(List<TaskNodeState> nodes) {
    var changed = false;
    final result = nodes
        .map((node) {
          final active =
              node.status == TaskNodeStatus.running ||
              node.status == TaskNodeStatus.verifying ||
              node.status == TaskNodeStatus.repairing;
          if (!active) return node;
          changed = true;
          return node.copyWith(
            status: TaskNodeStatus.interrupted,
            output: null,
            verificationEvidence: null,
          );
        })
        .toList(growable: false);
    return changed ? result : nodes;
  }

  TaskNodeState? _node(TaskSnapshot snapshot, TaskNodeId? id) => id == null
      ? null
      : snapshot.nodes.where((node) => node.id == id).firstOrNull;

  List<TaskNodeState> _replace(
    List<TaskNodeState> nodes,
    TaskNodeState replacement,
  ) => nodes
      .map((node) => node.id == replacement.id ? replacement : node)
      .toList(growable: false);

  List<TaskNodeState> _markReadyNodes(
    List<TaskNodeState> states,
    TaskPlan plan,
  ) {
    final byId = <TaskNodeId, TaskNodeState>{
      for (final state in states) state.id: state,
    };
    return plan.nodes
        .map((node) {
          final state = byId[node.id]!;
          if (state.status != TaskNodeStatus.pending &&
              state.status != TaskNodeStatus.interrupted) {
            return state;
          }
          final ready = node.dependencies.every(
            (dependency) =>
                byId[dependency]?.status == TaskNodeStatus.succeeded,
          );
          return ready ? state.copyWith(status: TaskNodeStatus.ready) : state;
        })
        .toList(growable: false);
  }

  TaskTransitionResult _accepted(TaskSnapshot snapshot) =>
      TaskTransitionResult.accepted(snapshot);

  TaskTransitionResult _invalid(String message) =>
      TaskTransitionResult.rejected(
        TaskTransitionFailureCode.invalidTransition,
        message,
      );
}

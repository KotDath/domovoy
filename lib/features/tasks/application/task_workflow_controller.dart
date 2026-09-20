import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/tasks/tasks.dart';
import 'task_workflow_state.dart';

final class TaskWorkflowController extends ChangeNotifier {
  TaskWorkflowController({
    required this.repository,
    required this.invariantRepository,
    required this.gateway,
    AgentClock? clock,
    AgentIdFactory? ids,
  }) : clock = clock ?? SystemAgentClock(),
       ids = ids ?? AgentIdFactory(prefix: 'task');

  final TaskRepository repository;
  final TaskInvariantRepository invariantRepository;
  final TaskAgentGateway gateway;
  final AgentClock clock;
  final AgentIdFactory ids;
  final TaskReducer _reducer = const TaskReducer();
  final DeterministicTaskInvariantChecker _deterministic =
      const DeterministicTaskInvariantChecker();

  TaskWorkflowState _state = const TaskWorkflowState();
  Future<void>? _automatic;
  var _generation = 0;
  var _disposed = false;

  TaskWorkflowState get state => _state;
  Future<void> get whenIdle => _automatic ?? Future<void>.value();

  Future<TaskCommandResult> initialize(String sessionId) async {
    try {
      final snapshot = await repository.recoverActiveForSession(
        sessionId,
        occurredAtMicros: clock.nowMicros(),
      );
      _emit(_state.copyWith(snapshot: snapshot, failure: null));
      if (snapshot != null && !snapshot.paused) {
        final generation = ++_generation;
        if (snapshot.phase == TaskPhase.planning &&
            snapshot.goal != null &&
            snapshot.plan == null) {
          return _preparePlan(generation);
        }
        if (snapshot.planApproved) _launchAutomatic(generation);
      }
      return const TaskCommandResult.accepted();
    } on Object {
      return _fail('STORAGE_FAILURE', 'Не удалось восстановить задачу.');
    }
  }

  Future<TaskCommandResult> start({
    required String sessionId,
    String? projectId,
    required String goal,
  }) async {
    if (_state.snapshot != null && _isActive(_state.snapshot!)) {
      return _fail(
        TaskTransitionFailureCode.invalidTransition.wireName,
        'В этом чате уже есть активная задача.',
      );
    }
    final initial = TaskSnapshot.initial(
      id: TaskId(ids.next()),
      sessionId: sessionId,
      projectId: projectId,
      nowMicros: clock.nowMicros(),
    );
    try {
      await repository.save(initial, expectedRevision: 0);
      _emit(_state.copyWith(snapshot: initial, failure: null));
      final captured = await _transition(
        TaskTransitionKind.goalCaptured,
        text: goal,
      );
      if (!captured.isAccepted) return captured;
      return await _preparePlan(++_generation);
    } on TaskRepositoryException catch (error) {
      return _repositoryFailure(error);
    } on Object {
      return _fail('STORAGE_FAILURE', 'Не удалось создать задачу.');
    }
  }

  Future<TaskCommandResult> approvePlan() async {
    final result = await _transition(TaskTransitionKind.planApproved);
    if (!result.isAccepted) return result;
    _launchAutomatic(++_generation);
    return result;
  }

  Future<TaskCommandResult> pause() async {
    _generation += 1;
    await gateway.cancelActive();
    return _transition(TaskTransitionKind.paused);
  }

  Future<TaskCommandResult> resume() async {
    final result = await _transition(TaskTransitionKind.resumed);
    if (!result.isAccepted) return result;
    final snapshot = _state.snapshot!;
    final generation = ++_generation;
    if (snapshot.phase == TaskPhase.planning && snapshot.plan == null) {
      return _preparePlan(generation);
    }
    if (snapshot.planApproved) _launchAutomatic(generation);
    return result;
  }

  Future<TaskCommandResult> replan({String? goal}) async {
    _generation += 1;
    await gateway.cancelActive();
    final result = await _transition(TaskTransitionKind.replanned, text: goal);
    if (!result.isAccepted) return result;
    return _preparePlan(++_generation);
  }

  Future<TaskCommandResult> cancel() async {
    _generation += 1;
    await gateway.cancelActive();
    return _transition(TaskTransitionKind.cancelled);
  }

  TaskCommandResult diagnose(TaskTransitionKind kind) {
    final current = _state.snapshot;
    if (current == null) {
      return _fail(
        TaskTransitionFailureCode.invalidTransition.wireName,
        'Активная задача отсутствует.',
      );
    }
    final result = _reducer.reduce(
      current,
      TaskTransition(
        kind: kind,
        expectedRevision: current.revision,
        occurredAtMicros: clock.nowMicros(),
      ),
    );
    if (!result.isAccepted) return _reject(result);
    return _fail(
      TaskTransitionFailureCode.invalidTransition.wireName,
      'Диагностический переход уже допустим и не был применён.',
    );
  }

  Future<TaskCommandResult> saveTaskRules(List<TaskInvariantRule> rules) async {
    final snapshot = _state.snapshot;
    if (snapshot == null) {
      return _fail(
        TaskTransitionFailureCode.invalidTransition.wireName,
        'Сначала создайте задачу.',
      );
    }
    final current = await invariantRepository.forTask(snapshot.id);
    final policy = TaskInvariantPolicy(
      scope: TaskInvariantScope.task,
      ownerId: snapshot.id.value,
      revision: current == null ? 0 : current.revision + 1,
      updatedAtMicros: clock.nowMicros(),
      rules: rules,
    );
    try {
      await invariantRepository.saveTaskPolicy(
        policy,
        expectedRevision: current?.revision ?? 0,
      );
      _emit(_state.copyWith(failure: null));
      return const TaskCommandResult.accepted();
    } on TaskRepositoryException catch (error) {
      return _repositoryFailure(error);
    }
  }

  Future<TaskCommandResult> saveProjectRules(
    String projectId,
    List<TaskInvariantRule> rules,
  ) async {
    final current = await invariantRepository.forProject(projectId);
    final policy = TaskInvariantPolicy(
      scope: TaskInvariantScope.project,
      ownerId: projectId,
      revision: current == null ? 0 : current.revision + 1,
      updatedAtMicros: clock.nowMicros(),
      rules: rules,
    );
    try {
      await invariantRepository.saveProjectPolicy(
        policy,
        expectedRevision: current?.revision ?? 0,
      );
      _emit(_state.copyWith(failure: null));
      return const TaskCommandResult.accepted();
    } on TaskRepositoryException catch (error) {
      return _repositoryFailure(error);
    }
  }

  Future<TaskCommandResult> _preparePlan(int generation) async {
    final current = _state.snapshot;
    if (current == null || current.goal == null) {
      return _fail(
        TaskTransitionFailureCode.invalidTransition.wireName,
        'Невозможно подготовить план без цели.',
      );
    }
    try {
      final policies = await _resolvePolicies(current);
      final rules = policies.rules;
      final goalCheck = await _checkCandidate(current.goal!, rules, generation);
      if (goalCheck != null) return goalCheck;
      _setInvoking(true);
      final plan = await gateway.preparePlan(goal: current.goal!, rules: rules);
      if (!_isCurrent(generation)) return const TaskCommandResult.accepted();
      final refreshedPolicies = await _resolvePolicies(current);
      if (!_policyStampsMatch(policies.stamps, refreshedPolicies.stamps)) {
        return _fail(
          TaskTransitionFailureCode.replanRequired.wireName,
          'Инварианты изменились во время подготовки плана.',
        );
      }
      final planCheck = await _checkCandidate(
        jsonEncode(plan.toJson()),
        rules,
        generation,
      );
      if (planCheck != null) return planCheck;
      return await _transition(
        TaskTransitionKind.planProposed,
        plan: plan,
        invariantIds: rules.map((rule) => rule.id).toList(),
        policyStamps: policies.stamps,
      );
    } on Object {
      if (!_isCurrent(generation)) return const TaskCommandResult.accepted();
      return _fail('AGENT_FAILURE', 'Не удалось подготовить план.');
    } finally {
      if (_isCurrent(generation)) _setInvoking(false);
    }
  }

  void _launchAutomatic(int generation) {
    final operation = _runAutomatic(generation);
    _automatic = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_automatic, operation)) _automatic = null;
      }),
    );
  }

  Future<void> _runAutomatic(int generation) async {
    try {
      while (_isCurrent(generation)) {
        final current = _state.snapshot;
        if (current == null ||
            current.paused ||
            current.cancelled ||
            current.phase == TaskPhase.done ||
            current.failureCode != null) {
          return;
        }
        final policies = await _resolvePolicies(current);
        if (!_policyStampsMatch(current.appliedPolicyStamps, policies.stamps)) {
          _fail(
            TaskTransitionFailureCode.replanRequired.wireName,
            'Инварианты изменились. Требуется новый план и утверждение.',
          );
          return;
        }
        if (current.phase == TaskPhase.planning) {
          final result = await _transition(TaskTransitionKind.executionStarted);
          if (!result.isAccepted) return;
          continue;
        }
        if (current.phase == TaskPhase.execution) {
          if (current.nodes.every(
            (node) => node.status == TaskNodeStatus.succeeded,
          )) {
            final result = await _transition(
              TaskTransitionKind.validationStarted,
            );
            if (!result.isAccepted) return;
            continue;
          }
          if (!await _runNode(current, policies.rules, generation)) return;
          continue;
        }
        if (current.phase == TaskPhase.validation) {
          if (!await _runFinal(current, policies.rules, generation)) return;
          continue;
        }
      }
    } on Object {
      if (_isCurrent(generation)) {
        _fail('AGENT_FAILURE', 'Автоматическое выполнение остановлено.');
      }
    } finally {
      if (_isCurrent(generation)) _setInvoking(false);
    }
  }

  Future<bool> _runNode(
    TaskSnapshot snapshot,
    List<TaskInvariantRule> rules,
    int generation,
  ) async {
    final nodeState = snapshot.currentNodeId == null
        ? null
        : snapshot.nodes
              .where((node) => node.id == snapshot.currentNodeId)
              .firstOrNull;
    if (nodeState == null) {
      _fail('INVALID_TRANSITION', 'Нет готового узла для выполнения.');
      return false;
    }
    if (nodeState.status == TaskNodeStatus.ready) {
      final started = await _transition(
        TaskTransitionKind.nodeStarted,
        nodeId: nodeState.id,
      );
      if (!started.isAccepted) return false;
      snapshot = _state.snapshot!;
    }
    final activeState = snapshot.nodes.firstWhere(
      (node) => node.id == nodeState.id,
    );
    if (activeState.status != TaskNodeStatus.running &&
        activeState.status != TaskNodeStatus.repairing) {
      _fail('INVALID_TRANSITION', 'Узел не находится в рабочем состоянии.');
      return false;
    }
    final planNode = snapshot.plan!.nodes.firstWhere(
      (node) => node.id == activeState.id,
    );
    final dependencyOutputs = <TaskNodeId, String>{};
    for (final dependency in planNode.dependencies) {
      final state = snapshot.nodes.firstWhere((node) => node.id == dependency);
      dependencyOutputs[dependency] = state.output!;
    }
    _setInvoking(true);
    final output = await gateway.executeNode(
      goal: snapshot.goal!,
      plan: snapshot.plan!,
      node: planNode,
      dependencyOutputs: dependencyOutputs,
      rules: rules,
      previousOutput: activeState.status == TaskNodeStatus.repairing
          ? activeState.output
          : null,
      rejectionEvidence: activeState.status == TaskNodeStatus.repairing
          ? activeState.verificationEvidence
          : null,
    );
    if (!_isCurrent(generation)) return false;
    if (!await _ensureAppliedPoliciesCurrent(snapshot, generation)) {
      return false;
    }
    final verificationStarted = await _transition(
      TaskTransitionKind.nodeVerificationStarted,
      nodeId: activeState.id,
      text: output,
    );
    if (!verificationStarted.isAccepted) return false;
    final deterministic = _deterministic.check(output, rules);
    TaskVerification verification;
    if (!deterministic.isDeterministicallyClean) {
      verification = TaskVerification(
        accepted: false,
        evidence: _violationMessage(deterministic.violations),
      );
      _fail(
        TaskTransitionFailureCode.invariantViolation.wireName,
        verification.evidence,
      );
    } else {
      verification = await gateway.verifyNode(
        goal: snapshot.goal!,
        plan: snapshot.plan!,
        node: planNode,
        output: output,
        rules: rules,
      );
    }
    if (!_isCurrent(generation)) return false;
    if (!await _ensureAppliedPoliciesCurrent(snapshot, generation)) {
      return false;
    }
    final latest = _state.snapshot!.nodes.firstWhere(
      (node) => node.id == activeState.id,
    );
    if (verification.accepted) {
      return (await _transition(
        TaskTransitionKind.nodeSucceeded,
        nodeId: activeState.id,
        evidence: verification.evidence,
      )).isAccepted;
    }
    if (latest.repairCount < 1) {
      return (await _transition(
        TaskTransitionKind.nodeRepairStarted,
        nodeId: activeState.id,
        evidence: verification.evidence,
      )).isAccepted;
    }
    await _transition(
      TaskTransitionKind.nodeFailed,
      nodeId: activeState.id,
      text: 'Узел повторно не прошёл проверку.',
      evidence: verification.evidence,
    );
    return false;
  }

  Future<bool> _runFinal(
    TaskSnapshot snapshot,
    List<TaskInvariantRule> rules,
    int generation,
  ) async {
    if (snapshot.finalOutput == null) {
      _setInvoking(true);
      final output = await gateway.composeFinal(
        goal: snapshot.goal!,
        plan: snapshot.plan!,
        outputs: <TaskNodeId, String>{
          for (final node in snapshot.nodes) node.id: node.output!,
        },
        rules: rules,
        rejectionEvidence: snapshot.failureMessage,
      );
      if (!_isCurrent(generation)) return false;
      if (!await _ensureAppliedPoliciesCurrent(snapshot, generation)) {
        return false;
      }
      final composed = await _transition(
        TaskTransitionKind.finalComposed,
        text: output,
      );
      if (!composed.isAccepted) return false;
      snapshot = _state.snapshot!;
    }
    final output = snapshot.finalOutput!;
    final deterministic = _deterministic.check(output, rules);
    TaskVerification verification;
    if (!deterministic.isDeterministicallyClean) {
      verification = TaskVerification(
        accepted: false,
        evidence: _violationMessage(deterministic.violations),
      );
      _fail(
        TaskTransitionFailureCode.invariantViolation.wireName,
        verification.evidence,
      );
    } else {
      verification = await gateway.verifyFinal(
        goal: snapshot.goal!,
        plan: snapshot.plan!,
        output: output,
        rules: rules,
      );
    }
    if (!_isCurrent(generation)) return false;
    if (!await _ensureAppliedPoliciesCurrent(snapshot, generation)) {
      return false;
    }
    if (verification.accepted) {
      return (await _transition(
        TaskTransitionKind.finalValidated,
        evidence: verification.evidence,
      )).isAccepted;
    }
    if (snapshot.finalRepairCount < 1) {
      return (await _transition(
        TaskTransitionKind.finalRepairStarted,
        evidence: verification.evidence,
      )).isAccepted;
    }
    await _transition(
      TaskTransitionKind.finalFailed,
      evidence: verification.evidence,
    );
    return false;
  }

  Future<TaskCommandResult?> _checkCandidate(
    String candidate,
    List<TaskInvariantRule> rules,
    int generation,
  ) async {
    final deterministic = _deterministic.check(candidate, rules);
    if (!deterministic.isDeterministicallyClean) {
      return _fail(
        TaskTransitionFailureCode.invariantViolation.wireName,
        _violationMessage(deterministic.violations),
      );
    }
    if (!deterministic.requiresSemanticReview) return null;
    _setInvoking(true);
    final review = await gateway.reviewInvariants(
      candidate: candidate,
      rules: deterministic.semanticRules,
    );
    if (!_isCurrent(generation)) return const TaskCommandResult.accepted();
    if (!review.isAllowed) {
      return _fail(
        TaskTransitionFailureCode.invariantViolation.wireName,
        _violationMessage(review.violations),
      );
    }
    return null;
  }

  Future<_ResolvedPolicies> _resolvePolicies(TaskSnapshot snapshot) async {
    final project = snapshot.projectId == null
        ? null
        : await invariantRepository.forProject(snapshot.projectId!);
    final task = await invariantRepository.forTask(snapshot.id);
    final policies = <TaskInvariantPolicy>[?project, ?task];
    return _ResolvedPolicies(
      rules: policies.expand((policy) => policy.rules).toList(),
      stamps: policies
          .map(
            (policy) => TaskInvariantPolicyStamp(
              scope: policy.scope,
              ownerId: policy.ownerId,
              revision: policy.revision,
            ),
          )
          .toList(),
    );
  }

  bool _policyStampsMatch(
    List<TaskInvariantPolicyStamp> applied,
    List<TaskInvariantPolicyStamp> current,
  ) {
    String key(TaskInvariantPolicyStamp stamp) =>
        '${stamp.scope.name}:${stamp.ownerId}:${stamp.revision}';
    final left = applied.map(key).toList()..sort();
    final right = current.map(key).toList()..sort();
    return listEquals(left, right);
  }

  Future<bool> _ensureAppliedPoliciesCurrent(
    TaskSnapshot snapshot,
    int generation,
  ) async {
    final current = await _resolvePolicies(snapshot);
    if (!_isCurrent(generation)) return false;
    if (_policyStampsMatch(snapshot.appliedPolicyStamps, current.stamps)) {
      return true;
    }
    _fail(
      TaskTransitionFailureCode.replanRequired.wireName,
      'Инварианты изменились. Требуется новый план и утверждение.',
    );
    return false;
  }

  Future<TaskCommandResult> _transition(
    TaskTransitionKind kind, {
    String? text,
    TaskPlan? plan,
    TaskNodeId? nodeId,
    String? evidence,
    List<String> invariantIds = const <String>[],
    List<TaskInvariantPolicyStamp> policyStamps =
        const <TaskInvariantPolicyStamp>[],
  }) async {
    final current = _state.snapshot;
    if (current == null) {
      return _fail(
        TaskTransitionFailureCode.invalidTransition.wireName,
        'Активная задача отсутствует.',
      );
    }
    final result = _reducer.reduce(
      current,
      TaskTransition(
        kind: kind,
        expectedRevision: current.revision,
        occurredAtMicros: clock.nowMicros(),
        text: text,
        plan: plan,
        nodeId: nodeId,
        evidence: evidence,
        invariantIds: invariantIds,
        policyStamps: policyStamps,
      ),
    );
    if (!result.isAccepted) return _reject(result);
    try {
      await repository.save(
        result.snapshot!,
        expectedRevision: current.revision,
      );
      _emit(_state.copyWith(snapshot: result.snapshot, failure: null));
      return const TaskCommandResult.accepted();
    } on TaskRepositoryException catch (error) {
      return _repositoryFailure(error);
    }
  }

  TaskCommandResult _reject(TaskTransitionResult result) => _fail(
    result.failureCode?.wireName ?? 'INVALID_TRANSITION',
    result.message ?? 'Переход отклонён.',
  );

  TaskCommandResult _repositoryFailure(TaskRepositoryException error) =>
      _fail(switch (error.kind) {
        TaskRepositoryErrorKind.conflict =>
          TaskTransitionFailureCode.revisionConflict.wireName,
        TaskRepositoryErrorKind.corrupt => 'STORAGE_CORRUPT',
        TaskRepositoryErrorKind.unavailable => 'STORAGE_FAILURE',
      }, error.message);

  TaskCommandResult _fail(String code, String message) {
    final failure = TaskWorkflowFailure(code: code, message: message);
    _emit(_state.copyWith(failure: failure));
    return TaskCommandResult.rejected(failure);
  }

  String _violationMessage(List<TaskInvariantViolation> violations) =>
      violations
          .map((violation) => '${violation.ruleId}: ${violation.reason}')
          .join('\n');

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  bool _isActive(TaskSnapshot snapshot) =>
      !snapshot.cancelled && snapshot.phase != TaskPhase.done;

  void _setInvoking(bool value) {
    if (_state.isInvokingAgent == value) return;
    _emit(_state.copyWith(isInvokingAgent: value));
  }

  void _emit(TaskWorkflowState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    unawaited(gateway.cancelActive());
    super.dispose();
  }
}

final class _ResolvedPolicies {
  _ResolvedPolicies({required this.rules, required this.stamps});

  final List<TaskInvariantRule> rules;
  final List<TaskInvariantPolicyStamp> stamps;
}

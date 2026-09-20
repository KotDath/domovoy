import 'package:domovoy/core/tasks/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TaskPlan', () {
    test('returns stable topological order', () {
      final plan = TaskPlan(<TaskPlanNode>[
        _node('build', dependencies: const <String>['plan']),
        _node('plan'),
        _node('verify', dependencies: const <String>['build']),
      ]);

      expect(plan.topologicalOrder().map((node) => node.id.value), <String>[
        'plan',
        'build',
        'verify',
      ]);
    });

    test('rejects missing dependency, duplicate, cycle, and size', () {
      expect(
        () => TaskPlan(<TaskPlanNode>[
          _node('one', dependencies: const <String>['missing']),
        ]),
        throwsFormatException,
      );
      expect(
        () => TaskPlan(<TaskPlanNode>[_node('one'), _node('one')]),
        throwsFormatException,
      );
      expect(
        () => TaskPlan(<TaskPlanNode>[
          _node('one', dependencies: const <String>['two']),
          _node('two', dependencies: const <String>['one']),
        ]),
        throwsFormatException,
      );
      expect(
        () => TaskPlan(
          List<TaskPlanNode>.generate(7, (index) => _node('n$index')),
        ),
        throwsFormatException,
      );
    });

    test('round trips through JSON', () {
      final plan = TaskPlan(<TaskPlanNode>[
        _node('one'),
        _node('two', dependencies: const <String>['one']),
      ]);

      final restored = TaskPlan.fromJson(plan.toJson());

      expect(restored.nodes.length, 2);
      expect(restored.nodes.last.dependencies.single.value, 'one');
    });
  });

  group('Task invariants', () {
    const checker = DeterministicTaskInvariantChecker();

    test('reports required, forbidden, and maximum violations', () {
      final result = checker.check(
        'Use Provider and mutable global state',
        <TaskInvariantRule>[
          TaskInvariantRule(
            id: 'architecture',
            scope: TaskInvariantScope.project,
            category: TaskInvariantCategory.architecture,
            description: 'Use reducer.',
            checker: TaskInvariantChecker.requiredTerms,
            terms: const <String>['reducer'],
          ),
          TaskInvariantRule(
            id: 'business',
            scope: TaskInvariantScope.task,
            category: TaskInvariantCategory.businessRule,
            description: 'No globals.',
            checker: TaskInvariantChecker.forbiddenTerms,
            terms: const <String>['global state'],
          ),
          TaskInvariantRule(
            id: 'length',
            scope: TaskInvariantScope.task,
            category: TaskInvariantCategory.custom,
            description: 'Short response.',
            checker: TaskInvariantChecker.maximumCharacters,
            maximumCharacters: 10,
          ),
        ],
      );

      expect(result.isAllowed, isFalse);
      expect(result.violations.map((violation) => violation.ruleId), <String>[
        'architecture',
        'business',
        'length',
      ]);
    });

    test('defers semantic rules without pretending they are deterministic', () {
      final rule = TaskInvariantRule(
        id: 'semantic',
        scope: TaskInvariantScope.task,
        category: TaskInvariantCategory.technicalDecision,
        description: 'Keep the selected architecture.',
        checker: TaskInvariantChecker.semantic,
      );

      final result = checker.check('candidate', <TaskInvariantRule>[rule]);

      expect(result.isDeterministicallyClean, isTrue);
      expect(result.requiresSemanticReview, isTrue);
      expect(result.isAllowed, isFalse);
      expect(result.semanticRules, <TaskInvariantRule>[rule]);
    });
  });

  group('TaskReducer', () {
    const reducer = TaskReducer();

    test('rejects execution before approval with stable code', () {
      final current = _withPlan(_withGoal(_initial()));

      final result = reducer.reduce(
        current,
        _transition(current, TaskTransitionKind.executionStarted),
      );

      expect(result.isAccepted, isFalse);
      expect(
        result.failureCode,
        TaskTransitionFailureCode.planApprovalRequired,
      );
      expect(result.failureCode!.wireName, 'PLAN_APPROVAL_REQUIRED');
    });

    test('routes approved nodes and validation automatically', () {
      var current = _withPlan(_withGoal(_initial()));
      current = _accept(reducer, current, TaskTransitionKind.planApproved);
      current = _accept(reducer, current, TaskTransitionKind.executionStarted);
      expect(current.phase, TaskPhase.execution);
      expect(current.nodes.first.status, TaskNodeStatus.ready);

      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeStarted,
        nodeId: const TaskNodeId('one'),
      );
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeVerificationStarted,
        nodeId: const TaskNodeId('one'),
        text: 'first output',
      );
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeSucceeded,
        nodeId: const TaskNodeId('one'),
        evidence: 'accepted',
      );
      expect(current.nodes.last.status, TaskNodeStatus.ready);

      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeStarted,
        nodeId: const TaskNodeId('two'),
      );
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeVerificationStarted,
        nodeId: const TaskNodeId('two'),
        text: 'second output',
      );
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeSucceeded,
        nodeId: const TaskNodeId('two'),
        evidence: 'accepted',
      );
      current = _accept(reducer, current, TaskTransitionKind.validationStarted);
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.finalComposed,
        text: '# result',
      );
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.finalValidated,
        evidence: 'final accepted',
      );

      expect(current.phase, TaskPhase.done);
      expect(current.expectedAction, TaskExpectedAction.none);
      expect(current.finalValidationEvidence, 'final accepted');
    });

    test('rejects done before node validation', () {
      var current = _withPlan(_withGoal(_initial()));
      current = _accept(reducer, current, TaskTransitionKind.planApproved);
      current = _accept(reducer, current, TaskTransitionKind.executionStarted);

      final result = reducer.reduce(
        current,
        _transition(current, TaskTransitionKind.validationStarted),
      );

      expect(result.failureCode, TaskTransitionFailureCode.validationRequired);
      expect(result.failureCode!.wireName, 'VALIDATION_REQUIRED');
    });

    test('pause blocks transitions and resume preserves phase and goal', () {
      var current = _withGoal(_initial());
      current = _accept(reducer, current, TaskTransitionKind.paused);

      final blocked = reducer.reduce(
        current,
        _transition(current, TaskTransitionKind.planProposed, plan: _plan()),
      );

      expect(blocked.failureCode, TaskTransitionFailureCode.taskPaused);
      final resumed = _accept(reducer, current, TaskTransitionKind.resumed);
      expect(resumed.phase, TaskPhase.planning);
      expect(resumed.goal, 'Build a result');
      expect(resumed.expectedAction, TaskExpectedAction.preparePlan);
    });

    test('rejects stale revision', () {
      final current = _initial();

      final result = reducer.reduce(
        current,
        TaskTransition(
          kind: TaskTransitionKind.goalCaptured,
          expectedRevision: 7,
          occurredAtMicros: 2,
          text: 'goal',
        ),
      );

      expect(result.failureCode, TaskTransitionFailureCode.revisionConflict);
    });

    test('interrupt discards partial output and requires resume', () {
      var current = _withPlan(_withGoal(_initial()));
      current = _accept(reducer, current, TaskTransitionKind.planApproved);
      current = _accept(reducer, current, TaskTransitionKind.executionStarted);
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeStarted,
        nodeId: const TaskNodeId('one'),
      );
      current = _accept(reducer, current, TaskTransitionKind.interrupted);

      expect(current.paused, isTrue);
      expect(current.nodes.first.status, TaskNodeStatus.interrupted);
      expect(current.nodes.first.output, isNull);
      expect(current.expectedAction, TaskExpectedAction.resume);

      current = _accept(reducer, current, TaskTransitionKind.resumed);
      expect(current.nodes.first.status, TaskNodeStatus.ready);
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeStarted,
        nodeId: const TaskNodeId('one'),
      );
      expect(current.nodes.first.status, TaskNodeStatus.running);
      expect(current.nodes.first.attempt, 2);
      expect(current.nodes.first.repairCount, 0);
    });

    test('pause interrupts an active node and resume rearms it', () {
      var current = _withPlan(_withGoal(_initial()));
      current = _accept(reducer, current, TaskTransitionKind.planApproved);
      current = _accept(reducer, current, TaskTransitionKind.executionStarted);
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeStarted,
        nodeId: const TaskNodeId('one'),
      );

      current = _accept(reducer, current, TaskTransitionKind.paused);
      expect(current.nodes.first.status, TaskNodeStatus.interrupted);
      current = _accept(reducer, current, TaskTransitionKind.resumed);

      expect(current.phase, TaskPhase.execution);
      expect(current.nodes.first.status, TaskNodeStatus.ready);
      expect(current.currentNodeId, const TaskNodeId('one'));
    });

    test('sequential scheduler refuses a second active root', () {
      final parallelPlan = TaskPlan(<TaskPlanNode>[_node('one'), _node('two')]);
      var current = _withGoal(_initial());
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.planProposed,
        plan: parallelPlan,
      );
      current = _accept(reducer, current, TaskTransitionKind.planApproved);
      current = _accept(reducer, current, TaskTransitionKind.executionStarted);
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeStarted,
        nodeId: const TaskNodeId('one'),
      );

      final result = reducer.reduce(
        current,
        _transition(
          current,
          TaskTransitionKind.nodeStarted,
          nodeId: const TaskNodeId('two'),
        ),
      );

      expect(result.isAccepted, isFalse);
      expect(current.expectedAction, TaskExpectedAction.runNode);
    });

    test('one repair is separate from interrupted attempts', () {
      var current = _withPlan(_withGoal(_initial()));
      current = _accept(reducer, current, TaskTransitionKind.planApproved);
      current = _accept(reducer, current, TaskTransitionKind.executionStarted);
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeStarted,
        nodeId: const TaskNodeId('one'),
      );
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeVerificationStarted,
        nodeId: const TaskNodeId('one'),
        text: 'bad output',
      );
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeRepairStarted,
        nodeId: const TaskNodeId('one'),
        evidence: 'rejected once',
      );
      expect(current.nodes.first.repairCount, 1);
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeVerificationStarted,
        nodeId: const TaskNodeId('one'),
        text: 'still bad',
      );
      current = _accept(
        reducer,
        current,
        TaskTransitionKind.nodeFailed,
        nodeId: const TaskNodeId('one'),
        evidence: 'rejected twice',
      );

      expect(current.nodes.first.status, TaskNodeStatus.failed);
      expect(current.failureCode, 'REPAIR_EXHAUSTED');
    });

    test('snapshot round trips through JSON', () {
      final current = _withPlan(_withGoal(_initial()));

      final restored = TaskSnapshot.fromJson(current.toJson());

      expect(restored.id, current.id);
      expect(restored.goal, current.goal);
      expect(restored.plan!.nodes.length, 2);
    });

    test('snapshot decoder rejects fabricated states as FormatException', () {
      final json = _withPlan(_withGoal(_initial())).toJson();
      json['planApproved'] = true;
      json['plan'] = null;

      expect(() => TaskSnapshot.fromJson(json), throwsFormatException);

      final unknownPhase = _initial().toJson();
      unknownPhase['phase'] = 'future';
      expect(() => TaskSnapshot.fromJson(unknownPhase), throwsFormatException);
    });
  });
}

TaskPlanNode _node(String id, {List<String> dependencies = const <String>[]}) =>
    TaskPlanNode(
      id: TaskNodeId(id),
      title: 'Node $id',
      instructions: 'Do $id',
      acceptanceCriteria: 'Verify $id',
      dependencies: dependencies.map(TaskNodeId.new).toList(),
    );

TaskPlan _plan() => TaskPlan(<TaskPlanNode>[
  _node('one'),
  _node('two', dependencies: const <String>['one']),
]);

TaskSnapshot _initial() => TaskSnapshot.initial(
  id: const TaskId('task-1'),
  sessionId: 'session-1',
  nowMicros: 1,
);

TaskSnapshot _withGoal(TaskSnapshot current) => _accept(
  const TaskReducer(),
  current,
  TaskTransitionKind.goalCaptured,
  text: 'Build a result',
);

TaskSnapshot _withPlan(TaskSnapshot current) => _accept(
  const TaskReducer(),
  current,
  TaskTransitionKind.planProposed,
  plan: _plan(),
);

TaskTransition _transition(
  TaskSnapshot current,
  TaskTransitionKind kind, {
  TaskNodeId? nodeId,
  String? text,
  String? evidence,
  TaskPlan? plan,
}) => TaskTransition(
  kind: kind,
  expectedRevision: current.revision,
  occurredAtMicros: current.updatedAtMicros + 1,
  nodeId: nodeId,
  text: text,
  evidence: evidence,
  plan: plan,
);

TaskSnapshot _accept(
  TaskReducer reducer,
  TaskSnapshot current,
  TaskTransitionKind kind, {
  TaskNodeId? nodeId,
  String? text,
  String? evidence,
  TaskPlan? plan,
}) {
  final result = reducer.reduce(
    current,
    _transition(
      current,
      kind,
      nodeId: nodeId,
      text: text,
      evidence: evidence,
      plan: plan,
    ),
  );
  expect(result.isAccepted, isTrue, reason: result.message);
  return result.snapshot!;
}

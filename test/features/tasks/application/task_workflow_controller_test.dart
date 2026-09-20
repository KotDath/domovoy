import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/tasks/tasks.dart';
import 'package:domovoy/features/tasks/application/tasks.dart';
import 'package:domovoy/infrastructure/tasks/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_jsonl_storage.dart';

void main() {
  group('TaskWorkflowController', () {
    test(
      'runs approved plan through verification to done automatically',
      () async {
        final harness = _Harness();

        final planned = await harness.controller.start(
          sessionId: 'session-1',
          projectId: 'project-1',
          goal: 'Create a verified answer',
        );

        expect(planned.isAccepted, isTrue);
        expect(harness.controller.state.snapshot?.phase, TaskPhase.planning);
        expect(harness.controller.state.snapshot?.planApproved, isFalse);
        expect(harness.gateway.calls, <String>['plan']);

        final approved = await harness.controller.approvePlan();
        expect(approved.isAccepted, isTrue);
        await harness.controller.whenIdle;

        final done = harness.controller.state.snapshot!;
        expect(done.phase, TaskPhase.done);
        expect(done.finalOutput, 'final answer');
        expect(done.finalValidationEvidence, 'final accepted');
        expect(harness.gateway.calls, <String>[
          'plan',
          'execute:work',
          'verify:work',
          'compose',
          'verify-final',
        ]);
      },
    );

    test(
      'diagnostic execution before approval returns stable guard code',
      () async {
        final harness = _Harness();
        await harness.controller.start(
          sessionId: 'session-1',
          goal: 'Plan first',
        );

        final result = harness.controller.diagnose(
          TaskTransitionKind.executionStarted,
        );

        expect(result.failure?.code, 'PLAN_APPROVAL_REQUIRED');
        expect(harness.controller.state.snapshot?.phase, TaskPhase.planning);
        expect(harness.gateway.calls, <String>['plan']);
      },
    );

    test('deterministic invariant rejects goal before any LLM call', () async {
      final harness = _Harness();
      await harness.store.saveProjectPolicy(
        TaskInvariantPolicy(
          scope: TaskInvariantScope.project,
          ownerId: 'project-1',
          revision: 0,
          updatedAtMicros: 1,
          rules: <TaskInvariantRule>[
            TaskInvariantRule(
              id: 'no-react',
              scope: TaskInvariantScope.project,
              category: TaskInvariantCategory.stack,
              description: 'Flutter only.',
              checker: TaskInvariantChecker.forbiddenTerms,
              terms: const <String>['React'],
            ),
          ],
        ),
        expectedRevision: 0,
      );

      final result = await harness.controller.start(
        sessionId: 'session-1',
        projectId: 'project-1',
        goal: 'Implement this in React',
      );

      expect(result.failure?.code, 'INVARIANT_VIOLATION');
      expect(result.failure?.message, contains('no-react'));
      expect(harness.gateway.calls, isEmpty);
      expect(harness.controller.state.snapshot?.plan, isNull);
    });

    test(
      'pause cancels an invocation and resume continues from checkpoint',
      () async {
        final gateway = _FakeTaskGateway()..blockNextExecution = true;
        final harness = _Harness(gateway: gateway);
        await harness.controller.start(
          sessionId: 'session-1',
          goal: 'Pause safely',
        );
        await harness.controller.approvePlan();
        await gateway.executionStarted.future;

        final paused = await harness.controller.pause();
        expect(paused.isAccepted, isTrue);
        expect(harness.controller.state.snapshot?.paused, isTrue);
        expect(
          harness.controller.state.snapshot?.nodes.single.status,
          TaskNodeStatus.interrupted,
        );

        gateway.blockNextExecution = false;
        final resumed = await harness.controller.resume();
        expect(resumed.isAccepted, isTrue);
        await harness.controller.whenIdle;

        expect(harness.controller.state.snapshot?.phase, TaskPhase.done);
        expect(harness.controller.state.snapshot?.goal, 'Pause safely');
        expect(gateway.cancelCount, 1);
        expect(gateway.calls.where((call) => call == 'execute:work').length, 2);
      },
    );

    test('policy revision change requires replan before execution', () async {
      final harness = _Harness();
      final first = TaskInvariantPolicy(
        scope: TaskInvariantScope.project,
        ownerId: 'project-1',
        revision: 0,
        updatedAtMicros: 1,
      );
      await harness.store.saveProjectPolicy(first, expectedRevision: 0);
      await harness.controller.start(
        sessionId: 'session-1',
        projectId: 'project-1',
        goal: 'Respect revisions',
      );
      await harness.store.saveProjectPolicy(
        TaskInvariantPolicy(
          scope: first.scope,
          ownerId: first.ownerId,
          revision: 1,
          updatedAtMicros: 2,
          rules: <TaskInvariantRule>[
            TaskInvariantRule(
              id: 'architecture',
              scope: TaskInvariantScope.project,
              category: TaskInvariantCategory.architecture,
              description: 'Keep the selected architecture.',
              checker: TaskInvariantChecker.semantic,
            ),
          ],
        ),
        expectedRevision: 0,
      );

      await harness.controller.approvePlan();
      await harness.controller.whenIdle;

      expect(harness.controller.state.failure?.code, 'REPLAN_REQUIRED');
      expect(harness.controller.state.snapshot?.phase, TaskPhase.planning);
      expect(harness.gateway.calls, <String>['plan']);
    });

    test('repairs a rejected node exactly once before continuing', () async {
      final gateway = _FakeTaskGateway(
        nodeVerifications: <TaskVerification>[
          const TaskVerification(accepted: false, evidence: 'needs repair'),
          const TaskVerification(accepted: true, evidence: 'repaired'),
        ],
      );
      final harness = _Harness(gateway: gateway);
      await harness.controller.start(
        sessionId: 'session-1',
        goal: 'Repair once',
      );
      await harness.controller.approvePlan();
      await harness.controller.whenIdle;

      final node = harness.controller.state.snapshot!.nodes.single;
      expect(node.status, TaskNodeStatus.succeeded);
      expect(node.repairCount, 1);
      expect(node.attempt, 2);
      expect(harness.controller.state.snapshot?.phase, TaskPhase.done);
    });

    test(
      'restart continues an approved checkpoint without restating goal',
      () async {
        final harness = _Harness();
        await harness.controller.start(
          sessionId: 'session-1',
          goal: 'Continue after restart',
        );
        final draft = harness.controller.state.snapshot!;
        final approved = const TaskReducer()
            .reduce(
              draft,
              TaskTransition(
                kind: TaskTransitionKind.planApproved,
                expectedRevision: draft.revision,
                occurredAtMicros: draft.updatedAtMicros + 1,
              ),
            )
            .snapshot!;
        await harness.store.save(approved, expectedRevision: draft.revision);
        final restartedGateway = _FakeTaskGateway();
        final restarted = TaskWorkflowController(
          repository: harness.store,
          invariantRepository: harness.store,
          gateway: restartedGateway,
          clock: harness.clock,
        );

        final initialized = await restarted.initialize('session-1');
        expect(initialized.isAccepted, isTrue);
        await restarted.whenIdle;

        expect(restarted.state.snapshot?.phase, TaskPhase.done);
        expect(restarted.state.snapshot?.goal, 'Continue after restart');
        expect(restartedGateway.calls, isNot(contains('plan')));
      },
    );

    test('stops after the single final repair is rejected', () async {
      final gateway = _FakeTaskGateway(
        finalVerifications: const <TaskVerification>[
          TaskVerification(accepted: false, evidence: 'bad final'),
          TaskVerification(accepted: false, evidence: 'still bad'),
        ],
      );
      final harness = _Harness(gateway: gateway);
      await harness.controller.start(
        sessionId: 'session-1',
        goal: 'Bound final repair',
      );
      await harness.controller.approvePlan();
      await harness.controller.whenIdle;

      final snapshot = harness.controller.state.snapshot!;
      expect(snapshot.phase, TaskPhase.validation);
      expect(snapshot.finalRepairCount, 1);
      expect(snapshot.failureCode, 'REPAIR_EXHAUSTED');
      expect(gateway.calls.where((call) => call == 'compose').length, 2);
      expect(gateway.calls.where((call) => call == 'verify-final').length, 2);
    });
  });
}

final class _Harness {
  _Harness({_FakeTaskGateway? gateway})
    : gateway = gateway ?? _FakeTaskGateway(),
      store = JsonlTaskStore(storage: FakeMemoryJsonlStorage()),
      clock = FakeAgentClock(startMicros: 10) {
    controller = TaskWorkflowController(
      repository: store,
      invariantRepository: store,
      gateway: this.gateway,
      clock: clock,
      ids: AgentIdFactory(prefix: 'test-task'),
    );
  }

  final _FakeTaskGateway gateway;
  final JsonlTaskStore store;
  final FakeAgentClock clock;
  late final TaskWorkflowController controller;
}

final class _FakeTaskGateway implements TaskAgentGateway {
  _FakeTaskGateway({
    List<TaskVerification> nodeVerifications = const <TaskVerification>[],
    List<TaskVerification> finalVerifications = const <TaskVerification>[],
  }) : nodeVerifications = List<TaskVerification>.from(nodeVerifications),
       finalVerifications = List<TaskVerification>.from(finalVerifications);

  final List<String> calls = <String>[];
  final List<TaskVerification> nodeVerifications;
  final List<TaskVerification> finalVerifications;
  final Completer<void> executionStarted = Completer<void>();
  Completer<String>? _blockedExecution;
  var blockNextExecution = false;
  var cancelCount = 0;

  @override
  Future<void> cancelActive() async {
    cancelCount += 1;
    final blocked = _blockedExecution;
    if (blocked != null && !blocked.isCompleted) {
      blocked.completeError(StateError('cancelled'));
    }
    _blockedExecution = null;
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
    return 'final answer';
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
  }) {
    calls.add('execute:${node.id.value}');
    if (!executionStarted.isCompleted) executionStarted.complete();
    if (blockNextExecution) {
      _blockedExecution = Completer<String>();
      return _blockedExecution!.future;
    }
    return Future<String>.value('node output ${node.id.value}');
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
        title: 'Work',
        instructions: 'Complete the work.',
        acceptanceCriteria: 'The work is complete.',
      ),
    ]);
  }

  @override
  Future<TaskInvariantReview> reviewInvariants({
    required String candidate,
    required List<TaskInvariantRule> rules,
  }) async {
    calls.add('review-invariants');
    return TaskInvariantReview();
  }

  @override
  Future<TaskVerification> verifyFinal({
    required String goal,
    required TaskPlan plan,
    required String output,
    required List<TaskInvariantRule> rules,
  }) async {
    calls.add('verify-final');
    return finalVerifications.isEmpty
        ? const TaskVerification(accepted: true, evidence: 'final accepted')
        : finalVerifications.removeAt(0);
  }

  @override
  Future<TaskVerification> verifyNode({
    required String goal,
    required TaskPlan plan,
    required TaskPlanNode node,
    required String output,
    required List<TaskInvariantRule> rules,
  }) async {
    calls.add('verify:${node.id.value}');
    return nodeVerifications.isEmpty
        ? const TaskVerification(accepted: true, evidence: 'node accepted')
        : nodeVerifications.removeAt(0);
  }
}

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
        expect(harness.controller.state.isInvokingAgent, isFalse);
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

    test(
      'pause remains authoritative when provider cancellation fails',
      () async {
        final gateway = _FakeTaskGateway()
          ..blockNextExecution = true
          ..throwOnCancel = true;
        final harness = _Harness(gateway: gateway);
        await harness.controller.start(
          sessionId: 'session-1',
          goal: 'Pause despite teardown failure',
        );
        await harness.controller.approvePlan();
        await gateway.executionStarted.future;

        final paused = await harness.controller.pause();

        expect(paused.isAccepted, isTrue);
        expect(harness.controller.state.snapshot?.paused, isTrue);
        expect(harness.controller.state.isInvokingAgent, isFalse);
        expect(gateway.cancelCount, 1);
      },
    );

    test('pause does not wait forever for provider cancellation', () async {
      final gateway = _FakeTaskGateway()
        ..blockNextExecution = true
        ..hangOnCancel = true;
      final harness = _Harness(
        gateway: gateway,
        cancelTimeout: const Duration(milliseconds: 1),
      );
      await harness.controller.start(
        sessionId: 'session-1',
        goal: 'Bound cancellation wait',
      );
      await harness.controller.approvePlan();
      await gateway.executionStarted.future;

      final paused = await harness.controller.pause();

      expect(paused.isAccepted, isTrue);
      expect(harness.controller.state.snapshot?.paused, isTrue);
      expect(harness.controller.state.isInvokingAgent, isFalse);
    });

    test('agent failure persists a recoverable paused checkpoint', () async {
      final gateway = _FakeTaskGateway()..executionFailuresRemaining = 1;
      final harness = _Harness(gateway: gateway);
      await harness.controller.start(
        sessionId: 'session-1',
        goal: 'Recover after provider failure',
      );
      await harness.controller.approvePlan();
      await harness.controller.whenIdle;

      expect(harness.controller.state.failure?.code, 'AGENT_FAILURE');
      expect(harness.controller.state.snapshot?.paused, isTrue);
      expect(
        harness.controller.state.snapshot?.nodes.single.status,
        TaskNodeStatus.interrupted,
      );
      expect(harness.controller.state.isInvokingAgent, isFalse);

      final resumed = await harness.controller.resume();
      expect(resumed.isAccepted, isTrue);
      await harness.controller.whenIdle;
      expect(harness.controller.state.snapshot?.phase, TaskPhase.done);
    });

    test(
      'answer length invariant does not reject the plan JSON envelope',
      () async {
        final harness = _Harness();
        await harness.store.saveProjectPolicy(
          TaskInvariantPolicy(
            scope: TaskInvariantScope.project,
            ownerId: 'project-1',
            revision: 0,
            updatedAtMicros: 1,
            rules: <TaskInvariantRule>[
              TaskInvariantRule(
                id: 'short-answer',
                scope: TaskInvariantScope.project,
                category: TaskInvariantCategory.businessRule,
                description: 'The answer must be shorter than 60 characters.',
                checker: TaskInvariantChecker.maximumCharacters,
                maximumCharacters: 60,
              ),
            ],
          ),
          expectedRevision: 0,
        );

        final result = await harness.controller.start(
          sessionId: 'session-1',
          projectId: 'project-1',
          goal: 'Write a brief answer',
        );

        expect(result.isAccepted, isTrue);
        expect(harness.controller.state.snapshot?.plan, isNotNull);
        expect(harness.controller.state.failure, isNull);
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

    test('default task ids stay unique across controller restarts', () async {
      final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
      final first = TaskWorkflowController(
        repository: store,
        invariantRepository: store,
        gateway: _FakeTaskGateway(),
      );
      addTearDown(first.dispose);
      expect(
        (await first.start(
          sessionId: 'session-1',
          goal: 'First task',
        )).isAccepted,
        isTrue,
      );
      final firstId = first.state.snapshot!.id;
      await first.cancel();

      final restarted = TaskWorkflowController(
        repository: store,
        invariantRepository: store,
        gateway: _FakeTaskGateway(),
      );
      addTearDown(restarted.dispose);
      final second = await restarted.start(
        sessionId: 'session-2',
        goal: 'Second task',
      );

      expect(second.isAccepted, isTrue);
      expect(restarted.state.snapshot!.id, isNot(firstId));
    });

    test('recovery failure clears the previous chat snapshot', () async {
      final store = JsonlTaskStore(storage: FakeMemoryJsonlStorage());
      final repository = _FailingRecoveryTaskRepository(
        store,
        failedSessionId: 'session-2',
      );
      final controller = TaskWorkflowController(
        repository: repository,
        invariantRepository: store,
        gateway: _FakeTaskGateway(),
        ids: AgentIdFactory(prefix: 'test-task'),
      );
      addTearDown(controller.dispose);
      await controller.start(sessionId: 'session-1', goal: 'Private task');

      final result = await controller.initialize('session-2');

      expect(result.isAccepted, isFalse);
      expect(result.failure?.code, 'STORAGE_FAILURE');
      expect(controller.state.snapshot, isNull);
    });

    test(
      'switching chats pauses the old task and restores its checkpoint',
      () async {
        final gateway = _FakeTaskGateway()..blockNextExecution = true;
        final harness = _Harness(gateway: gateway);
        await harness.controller.start(
          sessionId: 'session-1',
          goal: 'Keep this checkpoint',
        );
        await harness.controller.approvePlan();
        await gateway.executionStarted.future;

        final switched = await harness.controller.initialize('session-2');

        expect(switched.isAccepted, isTrue);
        expect(harness.controller.state.snapshot, isNull);
        final stored = await harness.store.activeForSession('session-1');
        expect(stored?.paused, isTrue);
        expect(stored?.nodes.single.status, TaskNodeStatus.interrupted);

        final restored = await harness.controller.initialize('session-1');
        expect(restored.isAccepted, isTrue);
        expect(harness.controller.state.snapshot?.goal, 'Keep this checkpoint');
        expect(harness.controller.state.snapshot?.paused, isTrue);
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

final class _FailingRecoveryTaskRepository implements TaskRepository {
  _FailingRecoveryTaskRepository(
    this.delegate, {
    required this.failedSessionId,
  });

  final TaskRepository delegate;
  final String failedSessionId;

  @override
  Future<TaskSnapshot?> activeForSession(String sessionId) =>
      delegate.activeForSession(sessionId);

  @override
  Future<TaskSnapshot?> load(TaskId id) => delegate.load(id);

  @override
  Future<TaskSnapshot?> recoverActiveForSession(
    String sessionId, {
    required int occurredAtMicros,
  }) {
    if (sessionId == failedSessionId) {
      throw StateError('simulated recovery failure');
    }
    return delegate.recoverActiveForSession(
      sessionId,
      occurredAtMicros: occurredAtMicros,
    );
  }

  @override
  Future<void> save(TaskSnapshot snapshot, {required int expectedRevision}) =>
      delegate.save(snapshot, expectedRevision: expectedRevision);
}

final class _Harness {
  _Harness({_FakeTaskGateway? gateway, Duration? cancelTimeout})
    : gateway = gateway ?? _FakeTaskGateway(),
      store = JsonlTaskStore(storage: FakeMemoryJsonlStorage()),
      clock = FakeAgentClock(startMicros: 10) {
    controller = TaskWorkflowController(
      repository: store,
      invariantRepository: store,
      gateway: this.gateway,
      cancelTimeout: cancelTimeout ?? const Duration(seconds: 2),
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
  var throwOnCancel = false;
  var hangOnCancel = false;
  var executionFailuresRemaining = 0;
  var cancelCount = 0;

  @override
  Future<void> cancelActive() async {
    cancelCount += 1;
    if (hangOnCancel) return Completer<void>().future;
    if (throwOnCancel) throw StateError('provider teardown failed');
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
    if (executionFailuresRemaining > 0) {
      executionFailuresRemaining -= 1;
      return Future<String>.error(StateError('provider failed'));
    }
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

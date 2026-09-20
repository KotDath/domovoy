import 'dart:convert';

import 'package:domovoy/core/tasks/tasks.dart';
import 'package:domovoy/infrastructure/tasks/tasks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';

void main() {
  group('JsonlTaskStore', () {
    test('replays snapshots and finds the active task after restart', () async {
      final storage = FakeMemoryJsonlStorage();
      final first = JsonlTaskStore(storage: storage);
      final initial = _initial();
      await first.save(initial, expectedRevision: 0);
      final revised = _transition(
        initial,
        TaskTransitionKind.goalCaptured,
        text: 'Persist this goal',
      );
      await first.save(revised, expectedRevision: initial.revision);

      final restarted = JsonlTaskStore(storage: storage);
      final restored = await restarted.load(initial.id);

      expect(restored?.goal, 'Persist this goal');
      expect(restored?.revision, 1);
      expect(
        (await restarted.activeForSession(initial.sessionId))?.id,
        initial.id,
      );
    });

    test('enforces revision and one active task per session', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = JsonlTaskStore(storage: storage);
      final initial = _initial();
      await repository.save(initial, expectedRevision: 0);

      await expectLater(
        repository.save(
          _transition(initial, TaskTransitionKind.goalCaptured, text: 'stale'),
          expectedRevision: 9,
        ),
        _repositoryError(TaskRepositoryErrorKind.conflict),
      );
      await expectLater(
        repository.save(
          TaskSnapshot.initial(
            id: const TaskId('second'),
            sessionId: initial.sessionId,
            nowMicros: 4,
          ),
          expectedRevision: 0,
        ),
        _repositoryError(TaskRepositoryErrorKind.conflict),
      );
    });

    test(
      'ignores an incomplete tail but fails closed on complete corruption',
      () async {
        final storage = FakeMemoryJsonlStorage();
        final repository = JsonlTaskStore(storage: storage);
        final initial = _initial();
        await repository.save(initial, expectedRevision: 0);
        final key = const TaskJsonlKeyCodec().task(initial.id);
        storage.appendText(key, '{partial');

        expect((await repository.load(initial.id))?.id, initial.id);

        storage.appendText(key, '}\n');
        await expectLater(
          repository.load(initial.id),
          _repositoryError(TaskRepositoryErrorKind.corrupt),
        );
      },
    );

    test('rejects a complete line containing an illegal snapshot', () async {
      final storage = FakeMemoryJsonlStorage();
      final id = const TaskId('illegal');
      final snapshot = _initial(id: id).toJson()
        ..['planApproved'] = true
        ..['plan'] = null;
      final line = jsonEncode(<String, Object?>{
        'type': 'domovoy.task_snapshot',
        'version': 1,
        'taskId': id.value,
        'sessionId': 'session-1',
        'sequence': 0,
        'expectedRevision': 0,
        'snapshotRevision': 0,
        'snapshot': snapshot,
      });
      storage.replaceText(const TaskJsonlKeyCodec().task(id), '$line\n');
      final repository = JsonlTaskStore(storage: storage);

      await expectLater(
        repository.load(id),
        _repositoryError(TaskRepositoryErrorKind.corrupt),
      );
    });

    test('persists task and project policies independently with CAS', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = JsonlTaskStore(storage: storage);
      final taskPolicy = TaskInvariantPolicy(
        scope: TaskInvariantScope.task,
        ownerId: 'task-1',
        revision: 0,
        updatedAtMicros: 1,
        rules: <TaskInvariantRule>[_rule('task-rule', TaskInvariantScope.task)],
      );
      final projectPolicy = TaskInvariantPolicy(
        scope: TaskInvariantScope.project,
        ownerId: 'project-1',
        revision: 0,
        updatedAtMicros: 1,
        rules: <TaskInvariantRule>[
          _rule('project-rule', TaskInvariantScope.project),
        ],
      );
      await repository.saveTaskPolicy(taskPolicy, expectedRevision: 0);
      await repository.saveProjectPolicy(projectPolicy, expectedRevision: 0);

      expect(
        (await repository.forTask(const TaskId('task-1')))?.rules.single.id,
        'task-rule',
      );
      expect(
        (await repository.forProject('project-1'))?.rules.single.id,
        'project-rule',
      );

      final revised = TaskInvariantPolicy(
        scope: TaskInvariantScope.task,
        ownerId: taskPolicy.ownerId,
        revision: 1,
        updatedAtMicros: 2,
        rules: taskPolicy.rules,
      );
      await expectLater(
        repository.saveTaskPolicy(revised, expectedRevision: 7),
        _repositoryError(TaskRepositoryErrorKind.conflict),
      );
      await repository.saveTaskPolicy(revised, expectedRevision: 0);
      expect(
        (await JsonlTaskStore(
          storage: storage,
        ).forTask(const TaskId('task-1')))?.revision,
        1,
      );
    });

    test(
      'persists an interrupted checkpoint during restart recovery',
      () async {
        final storage = FakeMemoryJsonlStorage();
        final repository = JsonlTaskStore(storage: storage);
        var current = _initial();
        await repository.save(current, expectedRevision: 0);
        current = await _advance(
          repository,
          current,
          TaskTransitionKind.goalCaptured,
          text: 'Recover me',
        );
        final plan = TaskPlan(<TaskPlanNode>[_node('work')]);
        current = await _advance(
          repository,
          current,
          TaskTransitionKind.planProposed,
          plan: plan,
        );
        current = await _advance(
          repository,
          current,
          TaskTransitionKind.planApproved,
        );
        current = await _advance(
          repository,
          current,
          TaskTransitionKind.executionStarted,
        );
        current = await _advance(
          repository,
          current,
          TaskTransitionKind.nodeStarted,
          nodeId: const TaskNodeId('work'),
        );

        final restarted = JsonlTaskStore(storage: storage);
        final recovered = await restarted.recoverActiveForSession(
          current.sessionId,
          occurredAtMicros: current.updatedAtMicros + 1,
        );

        expect(recovered?.paused, isTrue);
        expect(recovered?.nodes.single.status, TaskNodeStatus.interrupted);
        expect(recovered?.revision, current.revision + 1);
        expect((await restarted.load(current.id))?.paused, isTrue);
      },
    );

    test('isolates corrupt tasks from unrelated chat sessions', () async {
      final storage = FakeMemoryJsonlStorage();
      const corruptId = TaskId('corrupt');
      final snapshot = _initial(id: corruptId).toJson()
        ..['planApproved'] = true;
      storage.replaceText(
        const TaskJsonlKeyCodec().task(corruptId),
        '${jsonEncode(<String, Object?>{'type': 'domovoy.task_snapshot', 'version': 1, 'taskId': corruptId.value, 'sessionId': 'session-1', 'sequence': 0, 'expectedRevision': 0, 'snapshotRevision': 0, 'snapshot': snapshot})}\n',
      );
      final repository = JsonlTaskStore(storage: storage);
      final other = _initial(id: const TaskId('other'), sessionId: 'session-2');

      await repository.save(other, expectedRevision: 0);

      expect((await repository.activeForSession('session-2'))?.id, other.id);
      await expectLater(
        repository.activeForSession('session-1'),
        _repositoryError(TaskRepositoryErrorKind.corrupt),
      );
    });

    test(
      'rejects identity changes and a second active task on update',
      () async {
        final storage = FakeMemoryJsonlStorage();
        final repository = JsonlTaskStore(storage: storage);
        final dormant = _initial(
          id: const TaskId('dormant'),
        ).copyWith(cancelled: true);
        final active = _initial(id: const TaskId('active'));
        await repository.save(dormant, expectedRevision: 0);
        await repository.save(active, expectedRevision: 0);

        await expectLater(
          repository.save(
            dormant.copyWith(revision: 1, updatedAtMicros: 2, cancelled: false),
            expectedRevision: 0,
          ),
          _repositoryError(TaskRepositoryErrorKind.conflict),
        );
        await expectLater(
          repository.save(
            _copyIdentity(dormant, sessionId: 'other-session'),
            expectedRevision: 0,
          ),
          _repositoryError(TaskRepositoryErrorKind.conflict),
        );
      },
    );

    test(
      'ignores torn UTF-8 tails and treats cleanup as best effort',
      () async {
        final storage = FakeMemoryJsonlStorage()..failCleanup = true;
        final repository = JsonlTaskStore(storage: storage);
        final initial = _initial();
        await repository.save(initial, expectedRevision: 0);
        final tail = utf8.encode('{"value":"Привет');
        storage.appendBytes(
          const TaskJsonlKeyCodec().task(initial.id),
          tail.sublist(0, tail.length - 1),
        );

        expect((await repository.load(initial.id))?.id, initial.id);
      },
    );

    test('fails closed on fragment-only streams and wrong policy keys', () async {
      final storage = FakeMemoryJsonlStorage();
      const fragmentId = TaskId('fragment');
      storage.replaceText(
        const TaskJsonlKeyCodec().task(fragmentId),
        '{incomplete',
      );
      final repository = JsonlTaskStore(storage: storage);
      await expectLater(
        repository.load(fragmentId),
        _repositoryError(TaskRepositoryErrorKind.corrupt),
      );

      final policy = TaskInvariantPolicy(
        scope: TaskInvariantScope.task,
        ownerId: 'actual-owner',
        revision: 0,
        updatedAtMicros: 1,
      );
      storage.replaceText(
        const TaskJsonlKeyCodec().taskPolicy(const TaskId('wrong-owner')),
        '${jsonEncode(<String, Object?>{'type': 'domovoy.task_invariant_policy', 'version': 1, 'ownerId': policy.ownerId, 'scope': policy.scope.name, 'sequence': 0, 'expectedRevision': 0, 'policyRevision': 0, 'policy': policy.toJson()})}\n',
      );
      await expectLater(
        repository.forTask(const TaskId('wrong-owner')),
        _repositoryError(TaskRepositoryErrorKind.corrupt),
      );
    });

    test('key codec round trips opaque ids without unsafe path characters', () {
      const codec = TaskJsonlKeyCodec();
      const id = TaskId('task:with/slashes and spaces');

      final key = codec.task(id);

      expect(key, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(codec.tryTask(key), id);
    });
  });
}

TaskSnapshot _initial({
  TaskId id = const TaskId('task-1'),
  String sessionId = 'session-1',
}) => TaskSnapshot.initial(
  id: id,
  sessionId: sessionId,
  projectId: 'project-1',
  nowMicros: 1,
);

TaskSnapshot _transition(
  TaskSnapshot current,
  TaskTransitionKind kind, {
  String? text,
  TaskPlan? plan,
  TaskNodeId? nodeId,
}) {
  final result = const TaskReducer().reduce(
    current,
    TaskTransition(
      kind: kind,
      expectedRevision: current.revision,
      occurredAtMicros: current.updatedAtMicros + 1,
      text: text,
      plan: plan,
      nodeId: nodeId,
    ),
  );
  expect(result.isAccepted, isTrue, reason: result.message);
  return result.snapshot!;
}

Future<TaskSnapshot> _advance(
  JsonlTaskStore repository,
  TaskSnapshot current,
  TaskTransitionKind kind, {
  String? text,
  TaskPlan? plan,
  TaskNodeId? nodeId,
}) async {
  final next = _transition(
    current,
    kind,
    text: text,
    plan: plan,
    nodeId: nodeId,
  );
  await repository.save(next, expectedRevision: current.revision);
  return next;
}

TaskPlanNode _node(String id) => TaskPlanNode(
  id: TaskNodeId(id),
  title: id,
  instructions: 'Complete $id.',
  acceptanceCriteria: 'Verified $id.',
);

TaskSnapshot _copyIdentity(TaskSnapshot source, {required String sessionId}) =>
    TaskSnapshot(
      id: source.id,
      sessionId: sessionId,
      projectId: source.projectId,
      phase: source.phase,
      revision: source.revision + 1,
      createdAtMicros: source.createdAtMicros,
      updatedAtMicros: source.updatedAtMicros + 1,
      goal: source.goal,
      plan: source.plan,
      planApproved: source.planApproved,
      nodes: source.nodes,
      currentNodeId: source.currentNodeId,
      finalOutput: source.finalOutput,
      finalValidationEvidence: source.finalValidationEvidence,
      finalAttempt: source.finalAttempt,
      finalRepairCount: source.finalRepairCount,
      paused: source.paused,
      cancelled: source.cancelled,
      failureCode: source.failureCode,
      failureMessage: source.failureMessage,
      appliedInvariantIds: source.appliedInvariantIds,
    );

TaskInvariantRule _rule(String id, TaskInvariantScope scope) =>
    TaskInvariantRule(
      id: id,
      scope: scope,
      category: TaskInvariantCategory.stack,
      description: 'Keep Flutter.',
      checker: TaskInvariantChecker.forbiddenTerms,
      terms: const <String>['React'],
    );

Matcher _repositoryError(TaskRepositoryErrorKind kind) => throwsA(
  isA<TaskRepositoryException>().having((error) => error.kind, 'kind', kind),
);

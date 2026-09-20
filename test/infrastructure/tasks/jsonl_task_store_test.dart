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

    test('key codec round trips opaque ids without unsafe path characters', () {
      const codec = TaskJsonlKeyCodec();
      const id = TaskId('task:with/slashes and spaces');

      final key = codec.task(id);

      expect(key, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(codec.tryTask(key), id);
    });
  });
}

TaskSnapshot _initial({TaskId id = const TaskId('task-1')}) =>
    TaskSnapshot.initial(
      id: id,
      sessionId: 'session-1',
      projectId: 'project-1',
      nowMicros: 1,
    );

TaskSnapshot _transition(
  TaskSnapshot current,
  TaskTransitionKind kind, {
  String? text,
}) {
  final result = const TaskReducer().reduce(
    current,
    TaskTransition(
      kind: kind,
      expectedRevision: current.revision,
      occurredAtMicros: current.updatedAtMicros + 1,
      text: text,
    ),
  );
  expect(result.isAccepted, isTrue, reason: result.message);
  return result.snapshot!;
}

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

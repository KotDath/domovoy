import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InMemoryProjectRepository', () {
    test('optimistic save, tombstone, catalog order, cancellation', () async {
      final repo = InMemoryProjectRepository();
      final older = _record('z', updated: 8);
      final tieB = _record('b', updated: 9);
      final tieA = _record('a', updated: 9);
      for (final record in [older, tieB, tieA]) {
        await repo.save(
          record,
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        );
      }
      final snapshot = await repo.list();
      expect(snapshot.available.map((item) => item.id.value), ['a', 'b', 'z']);

      await expectLater(
        repo.save(
          tieA.copyWith(revision: 1),
          expectedRevision: 0,
          cancellation: (CancellationSource()..cancel()).token,
        ),
        throwsA(
          isA<ProjectException>().having(
            (error) => error.error.kind,
            'kind',
            ProjectErrorKind.cancelled,
          ),
        ),
      );
      expect((await repo.load(tieA.id))!.revision, 0);

      await repo.save(
        tieA.copyWith(revision: 1, updatedAtMicros: 11),
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      await expectLater(
        repo.save(
          tieA.copyWith(revision: 1, updatedAtMicros: 12),
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<ProjectException>().having(
            (error) => error.error.kind,
            'kind',
            ProjectErrorKind.conflict,
          ),
        ),
      );

      await repo.delete(
        tieA.id,
        expectedRevision: 1,
        cancellation: CancellationSource().token,
      );
      expect(await repo.load(tieA.id), isNull);
      await expectLater(
        repo.save(
          tieA,
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<ProjectException>()),
      );
    });

    test('name collision is typed and isolates corrupt neighbors', () async {
      final repo = InMemoryProjectRepository();
      await repo.save(
        _record('one', name: 'Alpha', suffix: false),
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      await expectLater(
        repo.save(
          _record('two', name: 'alpha', suffix: false),
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<ProjectException>().having(
            (error) => error.error.kind,
            'kind',
            ProjectErrorKind.collision,
          ),
        ),
      );
      repo.replacePayload(ProjectId('bad'), <String, Object?>{'nope': true});
      final snapshot = await repo.list();
      expect(snapshot.available, hasLength(1));
      expect(snapshot.issues, hasLength(1));
      expect(snapshot.issues.single.reason.message, isNot(contains('nope')));
    });
  });
}

ProjectRecord _record(
  String id, {
  int updated = 1,
  String name = 'Name',
  bool suffix = true,
}) {
  return ProjectRecord(
    id: ProjectId(id),
    revision: 0,
    name: suffix ? '$name $id' : name,
    root: ExternalGrantRootReference(DirectoryGrantId('g-$id')),
    createdAtMicros: 1,
    updatedAtMicros: updated,
  );
}

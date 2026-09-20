import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

void main() {
  final open = CancellationSource().token;

  group('InMemoryMemoryEntryRepository', () {
    test('saves, loads, and enforces optimistic revisions', () async {
      final repo = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
      final entry = workingEntry(createdAtMicros: 1, updatedAtMicros: 1);
      await repo.save(entry, expectedRevision: 0, cancellation: open);
      expect(await repo.load(entry.id, cancellation: open), entry);

      final revised = entry.revise(
        content: 'Retrieval must be deterministic and auditable.',
        updatedAtMicros: 2,
      );
      await repo.save(revised, expectedRevision: 0, cancellation: open);
      expect((await repo.load(entry.id, cancellation: open))!.revision, 1);
      await expectLater(
        repo.save(revised, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.conflict),
      );
    });

    test('rejects a mismatched layer namespace', () async {
      final repo = InMemoryMemoryEntryRepository(layer: MemoryLayer.longTerm);
      await expectLater(
        repo.save(workingEntry(), expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('enforces entry transitions on save', () async {
      final repo = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
      final entry = workingEntry(
        createdAtMicros: 1,
        updatedAtMicros: 1,
        sourceValues: const <String>['s1', 's2'],
      );
      await repo.save(entry, expectedRevision: 0, cancellation: open);
      final dropped = workingEntry(
        revision: 1,
        createdAtMicros: 1,
        updatedAtMicros: 2,
        sourceValues: const <String>['s1'],
      );
      await expectLater(
        repo.save(dropped, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('tombstone prevents resurrection and hides the entry', () async {
      final repo = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
      final entry = workingEntry();
      await repo.save(entry, expectedRevision: 0, cancellation: open);
      await repo.delete(entry.id, expectedRevision: 0, cancellation: open);
      expect(await repo.load(entry.id, cancellation: open), isNull);
      await expectLater(
        repo.save(entry, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.conflict),
      );
      expect(repo.hasTombstoneForTest, isTrue);
    });

    test('lists active entries and filters by project', () async {
      final repo = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
      final active = workingEntry(id: 'entry-a', project: 'p1');
      final forgotten = workingEntry(
        id: 'entry-b',
        project: 'p1',
        status: MemoryEntryStatus.forgotten,
      );
      final other = workingEntry(id: 'entry-c', project: 'p2');
      for (final entry in <MemoryEntry>[active, forgotten, other]) {
        await repo.save(entry, expectedRevision: 0, cancellation: open);
      }
      final activeOnly = await repo.list(cancellation: open);
      expect(activeOnly.map((entry) => entry.id.value), <String>[
        'entry-a',
        'entry-c',
      ]);
      final withForgotten = await repo.list(
        includeForgotten: true,
        cancellation: open,
      );
      expect(withForgotten, hasLength(3));
      final projectOne = await repo.list(
        projectId: active.projectId!,
        cancellation: open,
      );
      expect(projectOne.map((entry) => entry.id.value), <String>['entry-a']);
    });

    test('honours cancellation', () async {
      final repo = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
      final cancelled = CancellationSource()..cancel();
      await expectLater(
        repo.load(MemoryEntryId('entry-a'), cancellation: cancelled.token),
        _memoryError(MemoryErrorKind.cancelled),
      );
    });
  });

  group('InMemoryMemoryCandidateRepository', () {
    test('saves, transitions, and filters by status', () async {
      final repo = InMemoryMemoryCandidateRepository();
      final pending = createCandidate(id: 'candidate-a', project: 'p1');
      final accepted = pending.confirm(updatedAtMicros: 2);
      await repo.save(pending, expectedRevision: 0, cancellation: open);
      await repo.save(accepted, expectedRevision: 0, cancellation: open);

      final acceptedOnly = await repo.list(
        status: MemoryCandidateStatus.accepted,
        cancellation: open,
      );
      expect(acceptedOnly.single.id.value, 'candidate-a');
      expect(
        await repo.list(
          status: MemoryCandidateStatus.pending,
          cancellation: open,
        ),
        isEmpty,
      );
      final projectOne = await repo.list(
        projectId: pending.projectId,
        cancellation: open,
      );
      expect(projectOne, hasLength(1));
    });

    test('rejects illegal transitions and tombstones', () async {
      final repo = InMemoryMemoryCandidateRepository();
      final pending = createCandidate();
      await repo.save(pending, expectedRevision: 0, cancellation: open);
      await expectLater(
        repo.save(
          pending.confirm(updatedAtMicros: 2),
          expectedRevision: 5,
          cancellation: open,
        ),
        _memoryError(MemoryErrorKind.conflict),
      );
      await repo.delete(pending.id, expectedRevision: 0, cancellation: open);
      await expectLater(
        repo.save(pending, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.conflict),
      );
    });
  });

  group('MemoryRepositories', () {
    test('routes by layer', () {
      final working = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
      final longTerm = InMemoryMemoryEntryRepository(
        layer: MemoryLayer.longTerm,
      );
      final candidates = InMemoryMemoryCandidateRepository();
      final repositories = MemoryRepositories(
        workingRepository: working,
        longTermRepository: longTerm,
        candidateRepository: candidates,
      );
      expect(repositories.entryRepository(MemoryLayer.working), same(working));
      expect(
        repositories.entryRepository(MemoryLayer.longTerm),
        same(longTerm),
      );
      expect(repositories.candidateRepository, same(candidates));
    });

    test('rejects repositories bound to the wrong layer', () {
      final working = InMemoryMemoryEntryRepository(layer: MemoryLayer.working);
      final candidates = InMemoryMemoryCandidateRepository();
      expect(
        () => MemoryRepositories(
          workingRepository: working,
          longTermRepository: working,
          candidateRepository: candidates,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });
  });
}

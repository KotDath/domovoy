import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/infrastructure/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';
import '../../support/memory_jsonl_storage.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

void main() {
  final open = CancellationSource().token;

  group('JsonlMemoryCandidateRepository', () {
    test('round-trips create, update, and noop shapes', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).candidateRepository;
      final create = createCandidate(id: 'c-create');
      final update = updateCandidate(
        id: 'c-update',
        targetEntryId: MemoryEntryId('entry-1'),
      );
      final noop = noopCandidate(
        id: 'c-noop',
        targetEntryId: MemoryEntryId('entry-2'),
      );
      for (final candidate in <MemoryCandidate>[create, update, noop]) {
        await repository.save(
          candidate,
          expectedRevision: 0,
          cancellation: open,
        );
      }
      final restarted = MemoryJsonlStack(storage: storage).candidateRepository;
      expect(await restarted.load(create.id, cancellation: open), create);
      expect(await restarted.load(update.id, cancellation: open), update);
      expect(await restarted.load(noop.id, cancellation: open), noop);
      expect(await restarted.list(cancellation: open), <MemoryCandidate>[
        create,
        noop,
        update,
      ]);
    });

    test('filters listing by status and project', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).candidateRepository;
      final pending = createCandidate(id: 'a', project: 'p1');
      final acceptedPending = createCandidate(id: 'b', project: 'p1');
      final accepted = acceptedPending.confirm(updatedAtMicros: 2);
      final otherProject = createCandidate(id: 'c', project: 'p2');
      for (final entry in <MemoryCandidate>[pending, otherProject]) {
        await repository.save(entry, expectedRevision: 0, cancellation: open);
      }
      await repository.save(
        acceptedPending,
        expectedRevision: 0,
        cancellation: open,
      );
      await repository.save(accepted, expectedRevision: 0, cancellation: open);
      expect(
        await repository.list(
          status: MemoryCandidateStatus.pending,
          cancellation: open,
        ),
        <MemoryCandidate>[pending, otherProject],
      );
      expect(
        await repository.list(projectId: pending.projectId, cancellation: open),
        <MemoryCandidate>[pending, accepted],
      );
    });

    test('enforces optimistic revisions and legal transitions', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).candidateRepository;
      final pending = createCandidate(sourceValues: const <String>['s1', 's2']);
      await repository.save(pending, expectedRevision: 0, cancellation: open);
      final accepted = pending.confirm(updatedAtMicros: 2);
      await repository.save(accepted, expectedRevision: 0, cancellation: open);
      await expectLater(
        repository.save(accepted, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.conflict),
      );
      final provenancePending = createCandidate(
        id: 'candidate-provenance',
        sourceValues: const <String>['s1', 's2'],
      );
      await repository.save(
        provenancePending,
        expectedRevision: 0,
        cancellation: open,
      );
      final droppedProvenance = createCandidate(
        id: 'candidate-provenance',
        revision: 1,
        sourceValues: const <String>['s1'],
      );
      await expectLater(
        repository.save(
          droppedProvenance,
          expectedRevision: 0,
          cancellation: open,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('tombstones and blocks resurrection', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).candidateRepository;
      final candidate = createCandidate();
      await repository.save(candidate, expectedRevision: 0, cancellation: open);
      await repository.delete(
        candidate.id,
        expectedRevision: 0,
        cancellation: open,
      );
      expect(await repository.load(candidate.id, cancellation: open), isNull);
      await expectLater(
        repository.save(candidate, expectedRevision: 0, cancellation: open),
        _memoryError(MemoryErrorKind.conflict),
      );
    });

    test('sanitizes corrupt candidate payloads', () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = MemoryJsonlStack(storage: storage).candidateRepository;
      final candidate = createCandidate();
      await repository.save(candidate, expectedRevision: 0, cancellation: open);
      const codec = MemoryJsonlEnvelopeCodec();
      storage.replaceText(
        const MemoryJsonlKeyCodec().encode(
          MemoryJsonlStream.candidate,
          'candidate-1',
        ),
        codec.encodeLine(
          MemoryJsonlEnvelope(
            stream: MemoryJsonlStream.candidate,
            recordId: 'candidate-1',
            sequence: 0,
            operation: MemoryJsonlOperation.upsert,
            expectedRevision: 0,
            recordRevision: 0,
            record: const <String, Object?>{'not': 'a candidate'},
          ),
        ),
      );
      await expectLater(
        repository.load(candidate.id, cancellation: open),
        _memoryError(MemoryErrorKind.persistence),
      );
    });
  });
}

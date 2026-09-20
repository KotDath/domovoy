import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

void main() {
  group('MemoryCandidate structural rules', () {
    test('create requires content and no target', () {
      expect(createCandidate().operation, MemoryProposalOperation.create);
      expect(
        () => createCandidate(content: null),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => createCandidate(targetEntryId: MemoryEntryId('entry-1')),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('update requires a target and content', () {
      final target = MemoryEntryId('entry-1');
      expect(updateCandidate(targetEntryId: target).targetEntryId, target);
      expect(
        () => updateCandidate(targetEntryId: target, content: null),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('noop tolerates missing content and target', () {
      final noop = noopCandidate();
      expect(noop.operation, MemoryProposalOperation.noop);
      expect(noop.content, isNull);
      expect(noop.targetEntryId, isNull);
      expect(noop.sourceIds, isEmpty);
    });

    test('enforces layer, scope, and kind invariants', () {
      expect(
        () => createCandidate(
          layer: MemoryLayer.longTerm,
          scope: MemoryScope.project,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => createCandidate(kind: MemoryKind.preference),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => createCandidate(
          layer: MemoryLayer.longTerm,
          scope: MemoryScope.global,
          kind: MemoryKind.preference,
        ),
        returnsNormally,
      );
    });

    test('content candidates require unique provenance', () {
      expect(
        () => createCandidate(sourceValues: const <String>[]),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => createCandidate(sourceValues: const <String>['s1', 's1']),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('rejects secrets in candidate content', () {
      expect(
        () => createCandidate(content: 'api_key=abcdefghij'),
        _memoryError(MemoryErrorKind.secretDetected),
      );
    });

    test('is immutable', () {
      final candidate = createCandidate();
      expect(
        () => candidate.sourceIds.add(MemorySourceId('source-2')),
        throwsUnsupportedError,
      );
    });
  });

  group('MemoryCandidate lifecycle', () {
    test('confirm accepts a pending candidate', () {
      final accepted = createCandidate().confirm(updatedAtMicros: 2);
      expect(accepted.status, MemoryCandidateStatus.accepted);
      expect(accepted.isTerminal, isTrue);
      expect(accepted.revision, 1);
      expect(accepted.createdAtMicros, 1);
    });

    test('noop candidates cannot be confirmed', () {
      expect(
        () => noopCandidate().confirm(updatedAtMicros: 2),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('reject discards a pending candidate without deletion', () {
      final rejected = createCandidate().reject(updatedAtMicros: 2);
      expect(rejected.status, MemoryCandidateStatus.rejected);
      expect(rejected.isTerminal, isTrue);
    });

    test('edit keeps the candidate pending and preserves identity fields', () {
      final edited = createCandidate().edit(
        content: 'Retrieval must be deterministic and auditable.',
        kind: MemoryKind.decision,
        updatedAtMicros: 2,
      );
      expect(edited.status, MemoryCandidateStatus.pending);
      expect(edited.revision, 1);
      expect(edited.kind, MemoryKind.decision);
      expect(edited.operation, MemoryProposalOperation.create);
      expect(edited.layer, MemoryLayer.working);
      expect(edited.projectId?.value, 'project-1');
      expect(edited.createdAtMicros, 1);
    });

    test('edit must change the candidate', () {
      expect(
        () => createCandidate().edit(updatedAtMicros: 2),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('terminal candidates cannot transition', () {
      final accepted = createCandidate().confirm(updatedAtMicros: 2);
      expect(
        () => accepted.confirm(updatedAtMicros: 3),
        _memoryError(MemoryErrorKind.conflict),
      );
      expect(
        () => accepted.reject(updatedAtMicros: 3),
        _memoryError(MemoryErrorKind.conflict),
      );
      expect(
        () => accepted.edit(content: 'x', updatedAtMicros: 3),
        _memoryError(MemoryErrorKind.conflict),
      );
    });

    test('transition validator rejects identity drift', () {
      final previous = createCandidate();
      final drifted = createCandidate(
        revision: 1,
        layer: MemoryLayer.longTerm,
        scope: MemoryScope.global,
        kind: MemoryKind.fact,
        project: 'project-1',
        status: MemoryCandidateStatus.accepted,
      );
      expect(
        () => validateMemoryCandidateTransition(previous, drifted),
        _memoryError(MemoryErrorKind.configuration),
      );
    });
  });

  group('candidate to entry materialization', () {
    test('create candidates produce a fresh active entry', () {
      final accepted = createCandidate().confirm(updatedAtMicros: 2);
      final entry = memoryEntryFromCandidate(
        candidate: accepted,
        entryId: MemoryEntryId('entry-1'),
        revision: 0,
        createdAtMicros: 10,
        updatedAtMicros: 10,
      );
      expect(entry.layer, MemoryLayer.working);
      expect(entry.scope, MemoryScope.project);
      expect(entry.kind, MemoryKind.requirement);
      expect(entry.content, accepted.content);
      expect(entry.sourceIds, accepted.sourceIds);
      expect(entry.projectId, accepted.projectId);
      expect(entry.isActive, isTrue);
      expect(entry.supersedesEntryId, isNull);
    });

    test('update candidates supersede the target entry', () {
      final target = MemoryEntryId('entry-1');
      final accepted = updateCandidate(
        targetEntryId: target,
      ).confirm(updatedAtMicros: 2);
      final entry = memoryEntryFromCandidate(
        candidate: accepted,
        entryId: MemoryEntryId('entry-2'),
        revision: 1,
        createdAtMicros: 10,
        updatedAtMicros: 11,
      );
      expect(entry.revision, 1);
      expect(entry.supersedesEntryId, target);
    });

    test('in-place update materialization does not supersede itself', () {
      final target = MemoryEntryId('entry-1');
      final accepted = updateCandidate(
        targetEntryId: target,
      ).confirm(updatedAtMicros: 2);
      final entry = memoryEntryFromCandidate(
        candidate: accepted,
        entryId: target,
        revision: 3,
        createdAtMicros: 10,
        updatedAtMicros: 11,
      );
      expect(entry.revision, 3);
      expect(entry.supersedesEntryId, isNull);
    });

    test('noop and pending candidates cannot materialize', () {
      final noop = noopCandidate(status: MemoryCandidateStatus.accepted);
      expect(
        () => memoryEntryFromCandidate(
          candidate: noop,
          entryId: MemoryEntryId('entry-1'),
          revision: 0,
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => memoryEntryFromCandidate(
          candidate: createCandidate(),
          entryId: MemoryEntryId('entry-1'),
          revision: 0,
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });
  });

  group('MemoryCandidate JSON', () {
    test('round-trips create, update, and noop shapes', () {
      const codec = MemoryCandidateCodec();
      final create = createCandidate();
      final update = updateCandidate(targetEntryId: MemoryEntryId('entry-1'));
      final noop = noopCandidate(targetEntryId: MemoryEntryId('entry-2'));
      expect(create.toJson()['version'], MemoryCandidate.currentJsonVersion);
      expect(codec.decode(codec.encode(create)), create);
      expect(codec.decode(codec.encode(update)), update);
      expect(codec.decode(codec.encode(noop)), noop);
    });

    test('rejects unknown fields', () {
      const codec = MemoryCandidateCodec();
      final json = Map<String, Object?>.from(codec.encode(createCandidate()))
        ..['extra'] = 1;
      expect(
        () => codec.decode(json),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('equality and hashing follow the value', () {
      expect(createCandidate(), createCandidate());
      expect(createCandidate().hashCode, createCandidate().hashCode);
      expect(createCandidate(), isNot(createCandidate(revision: 1)));
    });
  });
}

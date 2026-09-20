import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

void main() {
  group('MemoryEntry invariants', () {
    test('accepts working and long-term records', () {
      final working = workingEntry();
      final longTerm = longTermEntry();
      expect(working.layer, MemoryLayer.working);
      expect(working.scope, MemoryScope.project);
      expect(working.projectId?.value, 'project-1');
      expect(working.isActive, isTrue);
      expect(working.isRetrievable, isTrue);
      expect(longTerm.layer, MemoryLayer.longTerm);
      expect(longTerm.scope, MemoryScope.global);
      expect(longTerm.projectId, isNull);
    });

    test('rejects layer/scope/project mismatches', () {
      expect(
        () => MemoryEntry(
          id: MemoryEntryId('e'),
          revision: 0,
          layer: MemoryLayer.working,
          scope: MemoryScope.global,
          kind: MemoryKind.fact,
          content: 'fact',
          sourceIds: [MemorySourceId('s')],
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemoryEntry(
          id: MemoryEntryId('e'),
          revision: 0,
          layer: MemoryLayer.longTerm,
          scope: MemoryScope.global,
          kind: MemoryKind.fact,
          content: 'fact',
          sourceIds: [MemorySourceId('s')],
          createdAtMicros: 1,
          updatedAtMicros: 1,
          projectId: workingEntry().projectId,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('rejects kinds that are illegal for the layer', () {
      expect(
        () => workingEntry(kind: MemoryKind.preference),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => longTermEntry(kind: MemoryKind.requirement),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('requires unique, non-empty provenance', () {
      expect(
        () => workingEntry(sourceValues: const <String>[]),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => workingEntry(sourceValues: const <String>['s1', 's1']),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('rejects negative revision and non-monotonic timestamps', () {
      expect(
        () => workingEntry(revision: -1),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => workingEntry(createdAtMicros: 5, updatedAtMicros: 4),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => workingEntry(createdAtMicros: -1, updatedAtMicros: 1),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('rejects self-supersession', () {
      expect(
        () => workingEntry(supersedesEntryId: MemoryEntryId('entry-working-1')),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('content and provenance are immutable', () {
      final entry = workingEntry(sourceValues: const <String>['s1']);
      expect(
        () => entry.sourceIds.add(MemorySourceId('s2')),
        throwsUnsupportedError,
      );
      expect(entry.content, 'Retrieval must be deterministic.');
    });
  });

  group('MemoryEntry lifecycle', () {
    test('forget tombstones in a successor revision', () {
      final entry = workingEntry(createdAtMicros: 1, updatedAtMicros: 1);
      final forgotten = entry.forget(updatedAtMicros: 5);
      expect(forgotten.revision, 1);
      expect(forgotten.status, MemoryEntryStatus.forgotten);
      expect(forgotten.isForgotten, isTrue);
      expect(forgotten.isRetrievable, isFalse);
      expect(forgotten.content, entry.content);
      expect(forgotten.kind, entry.kind);
      expect(forgotten.layer, entry.layer);
      expect(forgotten.scope, entry.scope);
      expect(forgotten.projectId, entry.projectId);
      expect(forgotten.createdAtMicros, entry.createdAtMicros);
      expect(forgotten.sourceIds, entry.sourceIds);
    });

    test('forgotten entries are terminal', () {
      final forgotten = workingEntry().forget(updatedAtMicros: 2);
      expect(
        () => forgotten.forget(updatedAtMicros: 3),
        _memoryError(MemoryErrorKind.conflict),
      );
      expect(
        () => forgotten.revise(content: 'new', updatedAtMicros: 3),
        _memoryError(MemoryErrorKind.conflict),
      );
    });

    test('revise changes content and kind but preserves identity fields', () {
      final entry = workingEntry(createdAtMicros: 1, updatedAtMicros: 1);
      final revised = entry.revise(
        content: 'Retrieval must be deterministic and auditable.',
        updatedAtMicros: 4,
      );
      expect(revised.revision, 1);
      expect(revised.content, 'Retrieval must be deterministic and auditable.');
      expect(revised.kind, entry.kind);
      expect(revised.layer, entry.layer);
      expect(revised.scope, entry.scope);
      expect(revised.projectId, entry.projectId);
      expect(revised.createdAtMicros, entry.createdAtMicros);
    });

    test('revise may extend provenance but not drop it', () {
      final entry = workingEntry(sourceValues: const <String>['s1', 's2']);
      final extended = entry.revise(
        sourceIds: sources(const <String>['s1', 's2', 's3']),
        updatedAtMicros: 2,
      );
      expect(extended.sourceIds, hasLength(3));
      expect(
        () => entry.revise(
          sourceIds: sources(const <String>['s1']),
          updatedAtMicros: 2,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('revise rejects no-op and backwards timestamps', () {
      final entry = workingEntry(createdAtMicros: 1, updatedAtMicros: 5);
      expect(
        () => entry.revise(updatedAtMicros: 6),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => entry.revise(
          content: 'Retrieval must be deterministic!',
          updatedAtMicros: 4,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });
  });

  group('MemoryEntry transition validator', () {
    test('rejects revision, identity, and provenance violations', () {
      final previous = workingEntry(
        createdAtMicros: 1,
        updatedAtMicros: 5,
        sourceValues: const <String>['s1', 's2'],
      );
      expect(
        () => validateMemoryEntryTransition(
          previous,
          workingEntry(
            revision: 2,
            createdAtMicros: 1,
            updatedAtMicros: 6,
            sourceValues: const <String>['s1', 's2'],
          ),
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => validateMemoryEntryTransition(
          previous,
          workingEntry(
            revision: 1,
            project: 'project-2',
            createdAtMicros: 1,
            updatedAtMicros: 6,
            sourceValues: const <String>['s1', 's2'],
          ),
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => validateMemoryEntryTransition(
          previous,
          workingEntry(
            revision: 1,
            createdAtMicros: 1,
            updatedAtMicros: 6,
            sourceValues: const <String>['s1'],
          ),
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('forgotten predecessors are terminal', () {
      final previous = workingEntry().forget(updatedAtMicros: 2);
      final next = previous._unforgettable();
      expect(
        () => validateMemoryEntryTransition(previous, next),
        _memoryError(MemoryErrorKind.conflict),
      );
    });
  });

  group('MemoryEntry JSON', () {
    test('round-trips working and global records', () {
      const codec = MemoryEntryCodec();
      final working = workingEntry();
      final longTerm = longTermEntry(
        supersedesEntryId: MemoryEntryId('entry-old'),
      );
      expect(working.toJson()['version'], MemoryEntry.currentJsonVersion);
      expect(codec.decode(codec.encode(working)), working);
      expect(codec.decode(codec.encode(longTerm)), longTerm);
      expect(codec.encode(working)['layer'], MemoryLayer.working.name);
    });

    test('rejects unknown fields and values', () {
      const codec = MemoryEntryCodec();
      final json = Map<String, Object?>.from(codec.encode(workingEntry()))
        ..['extra'] = true;
      expect(
        () => codec.decode(json),
        _memoryError(MemoryErrorKind.configuration),
      );
      final badEnum = Map<String, Object?>.from(codec.encode(workingEntry()))
        ..['layer'] = 'episodic';
      expect(
        () => codec.decode(badEnum),
        _memoryError(MemoryErrorKind.protocol),
      );
    });

    test('equality and hashing follow the value', () {
      expect(workingEntry(), workingEntry());
      expect(workingEntry().hashCode, workingEntry().hashCode);
      expect(workingEntry(), isNot(workingEntry(revision: 1)));
    });
  });
}

extension on MemoryEntry {
  MemoryEntry _unforgettable() {
    return MemoryEntry(
      id: id,
      revision: revision + 1,
      layer: layer,
      scope: scope,
      kind: kind,
      content: content,
      sourceIds: sourceIds,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros + 1,
      projectId: projectId,
      supersedesEntryId: supersedesEntryId,
    );
  }
}

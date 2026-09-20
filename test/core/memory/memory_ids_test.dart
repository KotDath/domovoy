import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

void main() {
  group('memory identifiers', () {
    test('round-trip through JSON and trim whitespace', () {
      final entry = MemoryEntryId('entry-1');
      final candidate = MemoryCandidateId('candidate-1');
      final source = MemorySourceId('source-1');
      expect(MemoryEntryId.fromJson(entry.toJson()), entry);
      expect(MemoryCandidateId.fromJson(candidate.toJson()), candidate);
      expect(MemorySourceId.fromJson(source.toJson()), source);
      expect(MemoryEntryId('  entry-1  '), entry);
      expect(MemoryEntryId.jsonType, 'memory.entry_id');
      expect(MemoryCandidateId.jsonType, 'memory.candidate_id');
      expect(MemorySourceId.jsonType, 'memory.source_id');
    });

    test('reject blank identities', () {
      expect(
        () => MemoryEntryId('   '),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemoryCandidateId(''),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemorySourceId('\n'),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('malformed JSON is a sanitized codec failure', () {
      expect(
        () => MemoryEntryId.fromJson(<String, Object?>{
          'type': 'memory.entry_id',
        }),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => MemorySourceId.fromJson('not-an-object'),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('equality and hashing follow the value', () {
      expect(MemoryEntryId('a'), MemoryEntryId('a'));
      expect(MemoryEntryId('a').hashCode, MemoryEntryId('a').hashCode);
      expect(MemoryEntryId('a'), isNot(MemoryEntryId('b')));
    });
  });
}

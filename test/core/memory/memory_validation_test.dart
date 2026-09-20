import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:flutter_test/flutter_test.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

void main() {
  group('content normalization', () {
    test('trims and preserves internal structure', () {
      expect(normalizeMemoryContent('  keep\nthis\t  '), 'keep\nthis');
      expect(
        normalizeMemoryContent('The user prefers dark mode.'),
        'The user prefers dark mode.',
      );
    });

    test('rejects blank, control, and oversized content', () {
      expect(
        () => normalizeMemoryContent('   '),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => normalizeMemoryContent('bad\u0000value'),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => normalizeMemoryContent('bad\u0001value'),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => normalizeMemoryContent(List<String>.filled(5000, 'a').join()),
        _memoryError(MemoryErrorKind.configuration),
      );
    });
  });

  group('secret rejection', () {
    test('detects provider keys and assignments', () {
      final secrets = <String>[
        'key sk-abcdefghijklmnopqrstuvwx',
        'token: abcdefghij',
        'api_key=abcdefghij',
        'authorization: bearer abcdefghij',
        '-----BEGIN RSA PRIVATE KEY-----',
        'AKIAABCDEFGHIJKLMNOP',
        'ghp_abcdefghijklmnopqrstuvwxyz01',
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      ];
      for (final secret in secrets) {
        expect(containsMemorySecret(secret), isTrue, reason: secret);
        expect(
          () => assertNoMemorySecret(secret),
          _memoryError(MemoryErrorKind.secretDetected),
          reason: secret,
        );
      }
    });

    test('does not flag ordinary memory content', () {
      expect(
        containsMemorySecret('The user prefers concise answers.'),
        isFalse,
      );
      expect(containsMemorySecret('Works in the Berlin office.'), isFalse);
      expect(
        containsMemorySecret('Remember to rotate credentials quarterly.'),
        isFalse,
      );
    });

    test('entry construction rejects secrets', () {
      expect(
        () => MemoryEntry(
          id: MemoryEntryId('entry-secret'),
          revision: 0,
          layer: MemoryLayer.longTerm,
          scope: MemoryScope.global,
          kind: MemoryKind.fact,
          content: 'token: abcdefghij',
          sourceIds: [MemorySourceId('source-1')],
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        _memoryError(MemoryErrorKind.secretDetected),
      );
    });
  });

  group('layer and scope invariants', () {
    test('accepts matching pairs', () {
      expect(
        () => validateMemoryLayerScope(
          layer: MemoryLayer.working,
          scope: MemoryScope.project,
          projectId: ProjectId('p1'),
        ),
        returnsNormally,
      );
      expect(
        () => validateMemoryLayerScope(
          layer: MemoryLayer.longTerm,
          scope: MemoryScope.global,
          projectId: null,
        ),
        returnsNormally,
      );
    });

    test('rejects mismatched pairs and membership', () {
      expect(
        () => validateMemoryLayerScope(
          layer: MemoryLayer.working,
          scope: MemoryScope.global,
          projectId: null,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => validateMemoryLayerScope(
          layer: MemoryLayer.longTerm,
          scope: MemoryScope.project,
          projectId: ProjectId('p1'),
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => validateMemoryLayerScope(
          layer: MemoryLayer.working,
          scope: MemoryScope.project,
          projectId: null,
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => validateMemoryLayerScope(
          layer: MemoryLayer.longTerm,
          scope: MemoryScope.global,
          projectId: ProjectId('p1'),
        ),
        _memoryError(MemoryErrorKind.configuration),
      );
    });

    test('source identities must be unique', () {
      expect(
        () => validateMemorySourceIds([
          MemorySourceId('s1'),
          MemorySourceId('s1'),
        ]),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => validateMemorySourceIds([
          MemorySourceId('s1'),
          MemorySourceId('s2'),
        ]),
        returnsNormally,
      );
    });
  });

  group('query normalization', () {
    test('trims and bounds queries', () {
      expect(normalizeMemoryQuery('  retrieval rules '), 'retrieval rules');
      expect(normalizeMemoryQuery(''), '');
      expect(
        () => normalizeMemoryQuery(List<String>.filled(600, 'q').join()),
        _memoryError(MemoryErrorKind.configuration),
      );
      expect(
        () => normalizeMemoryQuery('bad\u0000query'),
        _memoryError(MemoryErrorKind.configuration),
      );
    });
  });
}

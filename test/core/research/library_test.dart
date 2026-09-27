import 'dart:convert';
import 'dart:math';

import 'package:domovoy/core/research/research.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../infrastructure/mcp/servers/library/library_test_support.dart';

/// Deep, mutable copy of a record JSON for corruption-style tests.
Map<String, Object?> _mutableRecordJson(LibraryRecord record) =>
    jsonDecode(jsonEncode(record.toJson())) as Map<String, Object?>;

void main() {
  group('LibraryId', () {
    test('generates unpredictable well-formed identities', () {
      final random = Random(7);
      final ids = <String>{
        for (var index = 0; index < 32; index += 1)
          LibraryId.generate(random).value,
      };

      expect(ids, hasLength(32));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^lib_[a-z0-9]{32}$')));
        expect(LibraryId.tryParse(id)?.value, id);
      }
    });

    test('rejects malformed identities without echoing unbounded input', () {
      expect(LibraryId.tryParse(''), isNull);
      expect(LibraryId.tryParse('lib_'), isNull);
      expect(LibraryId.tryParse('lib_ABCDEF0123456789'), isNull);
      expect(LibraryId.tryParse('lib_short'), isNull);
      expect(LibraryId.tryParse('other_0123456789abcdef'), isNull);
      expect(
        () => LibraryId('x' * 5000),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.invalidInput,
          ),
        ),
      );
    });
  });

  group('LibraryRecord', () {
    test('round-trips through its versioned JSON form', () {
      final record = LibraryRecord(
        libraryId: 'lib_0123456789abcdef0123456789abcdef',
        runId: 'run_1',
        topic: 'Research topic',
        papers: <Paper>[libraryPaper()],
        digest: libraryDigest(),
        savedAt: DateTime.utc(2025, 1, 6, 12, 5),
      );

      final decoded = LibraryRecord.fromJson(record.toJson());

      expect(decoded, record);
      expect(decoded.revision, 0);
      expect(decoded.recordRef, 'domovoy://library/${record.libraryId.value}');
      expect(decoded.toJson()['schemaVersion'], libraryRecordSchemaVersion);
    });

    test('rejects an unknown record schema version explicitly', () {
      final json = <String, Object?>{
        ...LibraryRecord(
          libraryId: 'lib_0123456789abcdef0123456789abcdef',
          topic: 'Research topic',
          papers: <Paper>[libraryPaper()],
          digest: libraryDigest(),
          savedAt: DateTime.utc(2025, 1, 6, 12, 5),
        ).toJson(),
        'schemaVersion': 2,
      };

      expect(
        () => LibraryRecord.fromJson(json),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.versionMismatch,
          ),
        ),
      );
    });

    test('rejects unknown fields instead of silently dropping them', () {
      final json = <String, Object?>{
        ...LibraryRecord(
          libraryId: 'lib_0123456789abcdef0123456789abcdef',
          topic: 'Research topic',
          papers: <Paper>[libraryPaper()],
          digest: libraryDigest(),
          savedAt: DateTime.utc(2025, 1, 6, 12, 5),
        ).toJson(),
        'pdfUrl': 'https://example.com/paper.pdf',
      };

      expect(
        () => LibraryRecord.fromJson(json),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.invalidInput,
          ),
        ),
      );
    });

    test('rejects unexpected fields nested inside a stored paper snapshot', () {
      final json = _mutableRecordJson(
        LibraryRecord(
          libraryId: 'lib_0123456789abcdef0123456789abcdef',
          topic: 'Research topic',
          papers: <Paper>[libraryPaper()],
          digest: libraryDigest(),
          savedAt: DateTime.utc(2025, 1, 6, 12, 5),
        ),
      );
      final papers = json['papers']! as List<Object?>;
      (papers.first! as Map<String, Object?>)['pdfUrl'] =
          'https://example.com/paper.pdf';

      expect(
        () => LibraryRecord.fromJson(json),
        throwsA(
          isA<LibraryException>()
              .having(
                (error) => error.error.kind,
                'kind',
                LibraryErrorKind.invalidInput,
              )
              .having(
                (error) => error.error.message,
                'message',
                contains('pdfUrl'),
              ),
        ),
      );
    });

    test('rejects unexpected fields nested inside a stored digest item', () {
      final json = _mutableRecordJson(
        LibraryRecord(
          libraryId: 'lib_0123456789abcdef0123456789abcdef',
          topic: 'Research topic',
          papers: <Paper>[libraryPaper()],
          digest: libraryDigest(),
          savedAt: DateTime.utc(2025, 1, 6, 12, 5),
        ),
      );
      final digest = json['digest']! as Map<String, Object?>;
      final items = digest['items']! as List<Object?>;
      (items.first! as Map<String, Object?>)['apiKey'] = 'secret';

      expect(
        () => LibraryRecord.fromJson(json),
        throwsA(
          isA<LibraryException>()
              .having(
                (error) => error.error.kind,
                'kind',
                LibraryErrorKind.invalidInput,
              )
              .having(
                (error) => error.error.message,
                'message',
                contains('apiKey'),
              ),
        ),
      );
    });

    test('requires the topic to match the digest topic', () {
      expect(
        () => LibraryRecord(
          libraryId: 'lib_0123456789abcdef0123456789abcdef',
          topic: 'Another topic',
          papers: <Paper>[libraryPaper()],
          digest: libraryDigest(),
          savedAt: DateTime.utc(2025, 1, 6, 12, 5),
        ),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.message,
            'message',
            contains('digest topic'),
          ),
        ),
      );
    });

    test('rejects a digest item that is not part of the supplied papers', () {
      expect(
        () => LibraryRecord(
          libraryId: 'lib_0123456789abcdef0123456789abcdef',
          topic: 'Research topic',
          papers: <Paper>[libraryPaper()],
          digest: libraryDigest(
            items: <DigestItem>[
              DigestItem(arxivId: '2502.99999', finding: 'Foreign finding'),
            ],
          ),
          savedAt: DateTime.utc(2025, 1, 6, 12, 5),
        ),
        throwsA(
          isA<LibraryException>()
              .having(
                (error) => error.error.kind,
                'kind',
                LibraryErrorKind.invalidInput,
              )
              .having(
                (error) => error.error.message,
                'message',
                contains('2502.99999'),
              ),
        ),
      );
    });

    test('rejects a repeated paper snapshot', () {
      expect(
        () => LibraryRecord(
          libraryId: 'lib_0123456789abcdef0123456789abcdef',
          topic: 'Research topic',
          papers: <Paper>[libraryPaper(), libraryPaper()],
          digest: libraryDigest(),
          savedAt: DateTime.utc(2025, 1, 6, 12, 5),
        ),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.invalidInput,
          ),
        ),
      );
    });

    test('fingerprint ignores paper order but keeps digest order', () {
      final left = LibraryRecord(
        libraryId: 'lib_0123456789abcdef0123456789abcdef',
        topic: 'Research topic',
        papers: <Paper>[
          libraryPaper(arxivId: '2501.00001'),
          libraryPaper(arxivId: '2501.00002'),
        ],
        digest: libraryDigest(
          items: <DigestItem>[
            DigestItem(arxivId: '2501.00001', finding: 'First'),
            DigestItem(arxivId: '2501.00002', finding: 'Second'),
          ],
        ),
        savedAt: DateTime.utc(2025, 1, 6, 12, 5),
      );
      final reorderedPapers = LibraryRecord(
        libraryId: 'lib_fedcba9876543210fedcba9876543210',
        topic: 'Research topic',
        papers: <Paper>[
          libraryPaper(arxivId: '2501.00002'),
          libraryPaper(arxivId: '2501.00001'),
        ],
        digest: libraryDigest(
          items: <DigestItem>[
            DigestItem(arxivId: '2501.00001', finding: 'First'),
            DigestItem(arxivId: '2501.00002', finding: 'Second'),
          ],
        ),
        savedAt: DateTime.utc(2025, 1, 6, 13, 5),
      );
      final reorderedDigest = LibraryRecord(
        libraryId: 'lib_0123456789abcdef0123456789abcdef',
        topic: 'Research topic',
        papers: <Paper>[
          libraryPaper(arxivId: '2501.00001'),
          libraryPaper(arxivId: '2501.00002'),
        ],
        digest: libraryDigest(
          items: <DigestItem>[
            DigestItem(arxivId: '2501.00002', finding: 'Second'),
            DigestItem(arxivId: '2501.00001', finding: 'First'),
          ],
        ),
        savedAt: DateTime.utc(2025, 1, 6, 12, 5),
      );

      expect(
        reorderedPapers.payloadFingerprint,
        left.payloadFingerprint,
        reason: 'the paper snapshot is a set, not a sequence',
      );
      expect(
        reorderedDigest.payloadFingerprint,
        isNot(left.payloadFingerprint),
        reason: 'the digest payload is stored exactly as validated',
      );
    });

    test('summarizes a record into a compact card', () {
      final record = LibraryRecord(
        libraryId: 'lib_0123456789abcdef0123456789abcdef',
        runId: 'run_7',
        topic: 'Research topic',
        papers: <Paper>[libraryPaper()],
        digest: libraryDigest(),
        savedAt: DateTime.utc(2025, 1, 6, 12, 5),
      );

      final card = summarizeLibraryRecord(record);

      expect(card.libraryId, record.libraryId);
      expect(card.runId, 'run_7');
      expect(card.paperCount, 1);
      expect(card.itemCount, 1);
      expect(card.arxivIds, <String>['2501.01234']);
      expect(card.recordRef, record.recordRef);
      expect(card.toJson()['savedAt'], '2025-01-06T12:05:00.000Z');
    });
  });

  group('LibraryPageCursor', () {
    test('round-trips through an opaque encoding', () {
      final cursor = LibraryPageCursor(
        query: 'topic',
        savedAt: DateTime.utc(2025, 1, 6, 12, 5, 1, 250),
        libraryId: LibraryId('lib_0123456789abcdef0123456789abcdef'),
      );

      final decoded = LibraryPageCursor.tryDecode(cursor.encode());

      expect(decoded, cursor);
      expect(cursor.encode(), isNot(contains('lib_')));
    });

    test('rejects malformed cursors', () {
      String encode(Map<String, Object?> value) =>
          base64Url.encode(utf8.encode(jsonEncode(value)));

      expect(LibraryPageCursor.tryDecode('not base64!'), isNull);
      expect(LibraryPageCursor.tryDecode(''), isNull);
      expect(
        LibraryPageCursor.tryDecode(base64Url.encode(utf8.encode('[1,2,3]'))),
        isNull,
      );
      expect(
        LibraryPageCursor.tryDecode(
          encode(<String, Object?>{
            'v': 2,
            'q': null,
            't': '2025-01-06T12:05:00.000Z',
            'id': 'lib_0123456789abcdef0123456789abcdef',
          }),
        ),
        isNull,
      );
      expect(
        LibraryPageCursor.tryDecode(
          encode(<String, Object?>{
            'v': 1,
            'q': null,
            't': 'not a date',
            'id': 'lib_0123456789abcdef0123456789abcdef',
          }),
        ),
        isNull,
      );
      expect(
        LibraryPageCursor.tryDecode(
          encode(<String, Object?>{
            'v': 1,
            'q': null,
            't': '2025-01-06T12:05:00.000Z',
            'id': 'not-a-library-id',
          }),
        ),
        isNull,
      );
      expect(
        LibraryPageCursor.tryDecode(
          encode(<String, Object?>{
            'v': 1,
            'q': null,
            't': '2025-01-06T12:05:00.000Z',
            'id': 'lib_0123456789abcdef0123456789abcdef',
            'extra': true,
          }),
        ),
        isNull,
      );
      expect(
        LibraryPageCursor.tryDecode(
          LibraryPageCursor(
            query: null,
            savedAt: DateTime.utc(2025),
            libraryId: LibraryId('lib_0123456789abcdef0123456789abcdef'),
          ).encode(),
        ),
        isNotNull,
      );
    });

    test('normalizes free-text queries', () {
      expect(normalizeLibraryQuery(null), isNull);
      expect(normalizeLibraryQuery('   '), isNull);
      expect(normalizeLibraryQuery('  Topic  '), 'topic');
    });
  });
}

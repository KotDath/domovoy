import 'package:domovoy/core/research/research.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mcp_fixture_servers.dart';

void main() {
  group('Paper', () {
    test('serializes the agreed wire shape', () {
      expect(samplePaper().toJson(), <String, Object?>{
        'schemaVersion': 1,
        'arxivId': '2501.01234',
        'version': 'v2',
        'title': 'Example title',
        'authors': <String>['A. Researcher'],
        'abstract': 'Original arXiv abstract',
        'categories': <String>['cs.AI'],
        'publishedAt': '2025-01-03T12:00:00.000Z',
        'updatedAt': '2025-01-06T12:00:00.000Z',
        'abstractUrl': 'https://arxiv.org/abs/2501.01234',
      });
    });

    test('round-trips through JSON', () {
      final paper = samplePaper();
      expect(Paper.fromJson(paper.toJson()), paper);
    });

    test('rejects unknown schema versions explicitly', () {
      final json = samplePaper().toJson();
      json['schemaVersion'] = 99;
      expect(
        () => Paper.fromJson(json),
        throwsA(
          isA<ResearchException>().having(
            (error) => error.error.kind,
            'kind',
            ResearchErrorKind.unsupportedVersion,
          ),
        ),
      );
    });

    test(
      'normalizes prefixed identifiers and reads the version separately',
      () {
        final id = normalizeArxivId(' arXiv:2501.01234v12 ');
        expect(id, '2501.01234');
        expect(versionFromArxivInput('arXiv:2501.01234v12'), 'v12');
        expect(versionFromArxivInput('2501.01234'), isNull);
        expect(normalizeArxivId('math.GT/0309136'), 'math.GT/0309136');
      },
    );

    test('rejects URLs and malformed identifiers', () {
      for (final raw in <String>[
        'https://arxiv.org/abs/2501.01234',
        '2501.01234?x=1',
        'not-an-id',
        '',
      ]) {
        expect(
          () => normalizeArxivId(raw),
          throwsA(isA<ResearchException>()),
          reason: raw,
        );
      }
    });

    test('derives abstractUrl and rejects a mismatching one', () {
      final paper = samplePaper();
      expect(paper.abstractUrl.toString(), 'https://arxiv.org/abs/2501.01234');
      final json = paper.toJson();
      json['abstractUrl'] = 'https://evil.example.com/paper';
      expect(
        () => Paper.fromJson(json),
        throwsA(
          isA<ResearchException>().having(
            (error) => error.error.kind,
            'kind',
            ResearchErrorKind.invalidArxivId,
          ),
        ),
      );
    });

    test('requires non-blank title, authors and abstract', () {
      expect(
        () => Paper(
          arxivId: '2501.01234',
          title: '   ',
          authors: const <String>['A. Researcher'],
          abstractText: 'Abstract',
          categories: const <String>[],
          publishedAt: DateTime.utc(2025, 1, 3),
          updatedAt: DateTime.utc(2025, 1, 3),
        ),
        throwsA(isA<ResearchException>()),
      );
      expect(
        () => Paper(
          arxivId: '2501.01234',
          title: 'Title',
          authors: const <String>[],
          abstractText: 'Abstract',
          categories: const <String>[],
          publishedAt: DateTime.utc(2025, 1, 3),
          updatedAt: DateTime.utc(2025, 1, 3),
        ),
        throwsA(isA<ResearchException>()),
      );
    });
  });

  group('Digest', () {
    test('serializes the agreed wire shape', () {
      expect(sampleDigest().toJson(), <String, Object?>{
        'schemaVersion': 1,
        'topic': 'Research topic',
        'sourceScope': 'abstract',
        'overview': 'Short synthesis',
        'items': <Object?>[
          <String, Object?>{
            'arxivId': '2501.01234',
            'abstractUrl': 'https://arxiv.org/abs/2501.01234',
            'finding': 'Claim grounded in the supplied abstract',
            'limitation': 'Only the abstract was reviewed',
          },
        ],
        'generatedAt': '2025-01-06T12:05:00.000Z',
      });
    });

    test('round-trips through JSON and keeps derived URLs', () {
      final digest = sampleDigest();
      expect(Digest.fromJson(digest.toJson()), digest);
    });

    test('rejects unknown schema versions and source scopes', () {
      final json = sampleDigest().toJson();
      json['schemaVersion'] = 7;
      expect(
        () => Digest.fromJson(json),
        throwsA(
          isA<ResearchException>().having(
            (error) => error.error.kind,
            'kind',
            ResearchErrorKind.unsupportedVersion,
          ),
        ),
      );
      final scopeJson = sampleDigest().toJson();
      scopeJson['sourceScope'] = 'full_text';
      expect(
        () => Digest.fromJson(scopeJson),
        throwsA(isA<ResearchException>()),
      );
    });

    test('rejects digest items that were not supplied to the tool', () {
      final digest = sampleDigest(
        papers: <Paper>[samplePaper(arxivId: '2501.01234')],
      );
      expect(
        () => verifyDigestItemsBelongToPapers(digest, <Paper>[
          samplePaper(arxivId: '2501.99999'),
        ]),
        throwsA(isA<ResearchException>()),
      );
      expect(
        () => verifyDigestItemsBelongToPapers(digest, <Paper>[
          samplePaper(arxivId: '2501.01234'),
        ]),
        returnsNormally,
      );
    });

    test('rejects a digest item URL that is not derived from its ID', () {
      final json = sampleDigest().toJson();
      final items = json['items']! as List<Object?>;
      (items.first! as Map<String, Object?>)['abstractUrl'] =
          'https://example.com/2501.01234';
      expect(
        () => Digest.fromJson(json),
        throwsA(
          isA<ResearchException>().having(
            (error) => error.error.kind,
            'kind',
            ResearchErrorKind.invalidArxivId,
          ),
        ),
      );
    });
  });

  group('strict v1 field sets', () {
    ResearchErrorKind errorKindOf(Object? Function() action) {
      try {
        action();
      } on ResearchException catch (error) {
        return error.error.kind;
      }
      fail('expected a ResearchException');
    }

    test('Paper.fromJson stays tolerant while the strict check rejects', () {
      final json = samplePaper().toJson();
      json['pdfUrl'] = 'https://example.com/paper.pdf';

      expect(
        Paper.fromJson(json).toJson().containsKey('pdfUrl'),
        isFalse,
        reason: 'the shared reader intentionally ignores extra fields',
      );
      expect(
        errorKindOf(() => verifyPaperV1Fields(json)),
        ResearchErrorKind.invalidField,
      );
      expect(
        () => verifyPaperV1Fields(samplePaper().toJson()),
        returnsNormally,
      );
      expect(
        errorKindOf(() => verifyPaperV1Fields(<Object?>[])),
        ResearchErrorKind.format,
      );
    });

    test('Digest strict check rejects top-level and item extra fields', () {
      final withTopLevel = sampleDigest().toJson();
      withTopLevel['pdfUrl'] = 'https://example.com/paper.pdf';
      expect(
        errorKindOf(() => verifyDigestV1Fields(withTopLevel)),
        ResearchErrorKind.invalidField,
      );

      final withItem = sampleDigest().toJson();
      final items = withItem['items']! as List<Object?>;
      (items.first! as Map<String, Object?>)['apiKey'] = 'secret';
      expect(
        errorKindOf(() => verifyDigestV1Fields(withItem)),
        ResearchErrorKind.invalidField,
      );

      expect(
        () => verifyDigestV1Fields(sampleDigest().toJson()),
        returnsNormally,
      );
    });

    test('strict field sets cover the complete v1 contracts', () {
      expect(
        samplePaper().toJson().keys.toSet(),
        paperV1Fields,
        reason: 'Paper v1 fields must match the serialized shape',
      );
      final digest = sampleDigest().toJson();
      expect(digest.keys.toSet(), digestV1Fields);
      final items = digest['items']! as List<Object?>;
      expect(
        (items.first! as Map<String, Object?>).keys.toSet(),
        digestItemV1Fields,
      );
    });
  });
}

import 'package:domovoy/infrastructure/mcp/servers/arxiv/arxiv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'arxiv_test_support.dart';

void main() {
  const parser = ArxivAtomParser();

  group('ArxivAtomParser', () {
    test('parses a normal feed into normalized Paper v1 objects', () {
      final feed = atomFeed(
        totalResults: '2',
        startIndex: '0',
        entries: <String>[
          atomEntry(
            id: 'http://arxiv.org/abs/2501.01234v2',
            title: '  Example\n  title  ',
            summary: 'Line one.\nLine two.',
            authors: const <String>['A. Researcher', 'B. Author'],
            primaryCategory: 'cs.AI',
            categories: const <String>['cs.LG', 'cs.AI'],
            published: '2025-01-03T12:00:00-05:00',
            updated: '2025-01-06T12:00:00-04:00',
          ),
          atomEntry(
            id: 'http://arxiv.org/abs/math.GT/0309136v1',
            title: 'Legacy paper',
            summary: 'Legacy abstract',
            authors: const <String>['C. Author'],
            categories: const <String>['math.GT'],
            published: '2003-09-13T00:00:00Z',
            updated: '2003-09-13T00:00:00Z',
          ),
        ],
      );

      final parsed = parser.parse(feed);

      expect(parsed.totalResults, 2);
      expect(parsed.startIndex, 0);
      expect(parsed.itemsPerPage, 2);
      expect(parsed.papers, hasLength(2));
      expect(
        parsed.papers.first,
        paperFixture(
          arxivId: '2501.01234',
          version: 'v2',
          title: 'Example title',
          authors: const <String>['A. Researcher', 'B. Author'],
          abstractText: 'Line one. Line two.',
          categories: const <String>['cs.AI', 'cs.LG'],
          publishedAt: DateTime.utc(2025, 1, 3, 17),
          updatedAt: DateTime.utc(2025, 1, 6, 16),
        ),
      );
      expect(parsed.papers.first.displayId, '2501.01234v2');
      expect(
        parsed.papers.first.abstractUrl.toString(),
        'https://arxiv.org/abs/2501.01234',
      );
      expect(parsed.papers[1].arxivId.value, 'math.GT/0309136');
      expect(parsed.papers[1].version, 'v1');
      expect(
        parsed.papers[1].abstractUrl.toString(),
        'https://arxiv.org/abs/math.GT/0309136',
      );
    });

    test('decodes entities and rejects unknown ones', () {
      final feed = atomFeed(
        entries: <String>[
          atomEntry(
            title: 'A &amp; B &#x27;quoted&#x27; &#8212; dash',
            escape: false,
          ),
        ],
      );
      expect(parser.parse(feed).papers.single.title, "A & B 'quoted' — dash");

      final broken = atomFeed(
        entries: <String>[atomEntry(title: 'A &unknown; B', escape: false)],
      );
      expect(() => parser.parse(broken), throwsA(isA<ArxivFailure>()));
      expect(
        () => parser.parse('<feed><title>A & B</title></feed>'),
        throwsA(isA<ArxivFailure>()),
      );
    });

    test('keeps duplicate versions as separate parsed entries', () {
      final feed = atomFeed(
        entries: <String>[
          atomEntry(id: 'http://arxiv.org/abs/2501.01234v1'),
          atomEntry(
            id: 'http://arxiv.org/abs/2501.01234v2',
            title: 'Updated title',
          ),
        ],
      );
      final parsed = parser.parse(feed);
      expect(parsed.papers, hasLength(2));
      expect(parsed.papers.map((paper) => paper.version), <String?>[
        'v1',
        'v2',
      ]);
    });

    test('parses an empty feed', () {
      final parsed = parser.parse(atomFeed(totalResults: '0'));
      expect(parsed.papers, isEmpty);
      expect(parsed.totalResults, 0);
    });

    test('rejects malformed XML', () {
      for (final body in <String>[
        '',
        '   ',
        'not xml at all',
        '<feed><entry></feed>',
        '<feed><title>broken</title>',
        '<feed><title>a</title></feed><feed/>',
        '<feed><![CDATA[unterminated</feed>',
        '<feed><!DOCTYPE feed [<!ENTITY x "y">]><title>&x;</title></feed>',
        '<feed><title>a<!-- unterminated</title></feed>',
        '<other/>',
      ]) {
        expect(
          () => parser.parse(body),
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.protocol,
            ),
          ),
          reason: body,
        );
      }
    });

    test('rejects malformed entry fields', () {
      final cases = <String>[
        atomEntry(id: ''),
        atomEntry(id: 'https://evil.example/abs/2501.01234v1'),
        atomEntry(id: 'http://arxiv.org/abs/not-an-id'),
        atomEntry(id: 'http://arxiv.org/abs/1234.123'),
        atomEntry(title: ''),
        atomEntry(summary: ''),
        atomEntry(authors: const <String>[''], includeAuthors: true),
        atomEntry(includeAuthors: false),
        atomEntry(published: 'not-a-date'),
        atomEntry(updated: ''),
        atomEntry(categories: const <String>['a b']),
      ];
      for (final entry in cases) {
        expect(
          () => parser.parse(atomFeed(entries: <String>[entry])),
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.protocol,
            ),
          ),
          reason: entry,
        );
      }
    });

    test('rejects malformed feed counters', () {
      for (final feed in <String>[
        atomFeed(totalResults: 'many'),
        atomFeed(startIndex: '-3'),
        atomFeed(itemsPerPage: 'x'),
      ]) {
        expect(
          () => parser.parse(feed),
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.protocol,
            ),
          ),
          reason: feed,
        );
      }
    });

    test('turns an API error feed into a sanitized input failure', () {
      final feed = atomFeed(
        totalResults: '1',
        entries: <String>[
          atomEntry(
            id: 'http://arxiv.org/api/errors#incorrect_id_format_for_1234.1234',
            title: 'Error',
            summary: 'incorrect id format for 1234.1234',
          ),
        ],
      );
      final failure = _failureOf(() => parser.parse(feed));
      expect(failure.kind, ArxivFailureKind.invalidInput);
      expect(failure.message, contains('incorrect_id_format_for'));
      expect(failure.message, isNot(contains('1234.1234')));
    });

    test('rejects oversized output', () {
      final longTitle = 'x' * 2100;
      expect(
        () => parser.parse(
          atomFeed(entries: <String>[atomEntry(title: longTitle)]),
        ),
        throwsA(
          isA<ArxivFailure>().having(
            (failure) => failure.kind,
            'kind',
            ArxivFailureKind.protocol,
          ),
        ),
      );

      const tightEntries = ArxivAtomParser(maxEntries: 2);
      final three = atomFeed(
        entries: <String>[atomEntry(), atomEntry(), atomEntry()],
      );
      expect(
        () => tightEntries.parse(three),
        throwsA(
          isA<ArxivFailure>().having(
            (failure) => failure.kind,
            'kind',
            ArxivFailureKind.protocol,
          ),
        ),
      );

      const tightText = ArxivAtomParser(maxTextCharacters: 16);
      expect(
        () => tightText.parse(atomFeed(entries: <String>[atomEntry()])),
        throwsA(isA<ArxivFailure>()),
      );
    });

    test('parses self-closing tags and ignores namespaces', () {
      final feed = atomFeed(
        entries: <String>[
          atomEntry(
            extra:
                '<link rel="alternate" '
                'href="http://arxiv.org/abs/2501.01234v1" type="text/html"/>'
                '<author><name>D. Author</name></author>',
          ),
        ],
      );
      final paper = parser.parse(feed).papers.single;
      expect(paper.authors, <String>['A. Researcher', 'D. Author']);
    });
  });
}

ArxivFailure _failureOf(void Function() action) {
  try {
    action();
  } on ArxivFailure catch (failure) {
    return failure;
  }
  fail('Expected an ArxivFailure');
}

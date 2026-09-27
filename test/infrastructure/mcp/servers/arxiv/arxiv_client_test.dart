import 'dart:async';

import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/mcp/servers/arxiv/arxiv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'arxiv_test_support.dart';

void main() {
  late FakeArxivClock clock;

  setUp(() {
    clock = FakeArxivClock();
  });

  ArxivClient clientWith(
    FakeArxivHttpAdapter adapter, {
    FakeArxivClock? fakeClock,
    Duration requestTimeout = const Duration(seconds: 15),
    Duration minRequestInterval = const Duration(seconds: 3),
    Duration cacheTtl = const Duration(minutes: 10),
    int cacheCapacity = 32,
    int maxResponseCharacters = 2 * 1024 * 1024,
  }) {
    return ArxivClient(
      http: adapter,
      clock: fakeClock ?? clock,
      requestTimeout: requestTimeout,
      minRequestInterval: minRequestInterval,
      cacheTtl: cacheTtl,
      cacheCapacity: cacheCapacity,
      maxResponseCharacters: maxResponseCharacters,
    );
  }

  FakeArxivHttpAdapter feedAdapter(List<String> feeds) {
    return FakeArxivHttpAdapter(
      clock: clock,
      responder: (url, index) async => atomResponse(feeds[index]),
    );
  }

  group('ArxivClient.search', () {
    test('builds the documented query and returns normalized papers', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(totalResults: '1', entries: <String>[atomEntry()]),
      ]);
      final client = clientWith(adapter);

      final page = await client.search(
        ArxivSearchRequest(
          query: 'quantum computing',
          category: 'cs.AI',
          submittedAfter: DateTime.utc(2024, 1, 1),
          sortBy: ArxivSortBy.submittedDate,
          limit: 5,
        ),
      );

      expect(adapter.requests, hasLength(1));
      final uri = adapter.requests.single;
      expect(
        uri.queryParameters['search_query'],
        'all:quantum AND all:computing AND cat:cs.AI AND '
        'submittedDate:[202401010000 TO 999912312359]',
      );
      expect(uri.queryParameters['start'], '0');
      expect(uri.queryParameters['max_results'], '5');
      expect(uri.queryParameters['sortBy'], 'submittedDate');
      expect(uri.queryParameters['sortOrder'], 'descending');
      expect(
        uri.query,
        contains('submittedDate%3A%5B202401010000+TO+999912312359%5D'),
      );
      expect(page.papers, <Paper>[paperFixture()]);
      expect(page.totalResults, 1);
      expect(page.truncated, isFalse);
    });

    test(
      'percent-encodes free-text queries and strips grammar symbols',
      () async {
        final adapter = feedAdapter(<String>[
          atomFeed(entries: <String>[atomEntry()]),
        ]);
        final client = clientWith(adapter);

        await client.search(
          ArxivSearchRequest(query: 'ti:(electron AND "thermal")', limit: 1),
        );

        expect(
          adapter.requests.single.queryParameters['search_query'],
          'all:ti AND all:electron AND all:AND AND all:thermal',
        );
      },
    );

    test('dedupes versions keeping the newest and first-seen order', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(
          entries: <String>[
            atomEntry(id: 'http://arxiv.org/abs/2501.00001v1'),
            atomEntry(id: 'http://arxiv.org/abs/2501.01234v1', title: 'Older'),
            atomEntry(id: 'http://arxiv.org/abs/2501.01234v2', title: 'Newer'),
          ],
        ),
      ]);
      final client = clientWith(adapter);

      final page = await client.search(ArxivSearchRequest(query: 'electron'));

      expect(page.papers, hasLength(2));
      expect(page.papers[0].arxivId.value, '2501.00001');
      expect(page.papers[1].arxivId.value, '2501.01234');
      expect(page.papers[1].version, 'v2');
      expect(page.papers[1].title, 'Newer');
    });

    test('orders date sorts deterministically', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(
          entries: <String>[
            atomEntry(
              id: 'http://arxiv.org/abs/2501.00002v1',
              published: '2025-01-02T00:00:00Z',
              updated: '2025-01-02T00:00:00Z',
            ),
            atomEntry(
              id: 'http://arxiv.org/abs/2501.00001v1',
              published: '2025-01-03T00:00:00Z',
              updated: '2025-01-03T00:00:00Z',
            ),
            atomEntry(
              id: 'http://arxiv.org/abs/2501.00003v1',
              published: '2025-01-03T00:00:00Z',
              updated: '2025-01-03T00:00:00Z',
            ),
          ],
        ),
      ]);
      final client = clientWith(adapter);

      final page = await client.search(
        ArxivSearchRequest(
          query: 'electron',
          sortBy: ArxivSortBy.submittedDate,
        ),
      );

      expect(page.papers.map((paper) => paper.arxivId.value), <String>[
        '2501.00001',
        '2501.00003',
        '2501.00002',
      ]);
    });

    test('honors limit and reports truncation from totalResults', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(
          totalResults: '120',
          entries: <String>[
            atomEntry(id: 'http://arxiv.org/abs/2501.00001v1'),
            atomEntry(id: 'http://arxiv.org/abs/2501.00002v1'),
            atomEntry(id: 'http://arxiv.org/abs/2501.00003v1'),
          ],
        ),
      ]);
      final client = clientWith(adapter);

      final page = await client.search(
        ArxivSearchRequest(query: 'electron', limit: 2),
      );

      expect(page.papers, hasLength(2));
      expect(page.totalResults, 120);
      expect(page.truncated, isTrue);
      expect(adapter.requests.single.queryParameters['max_results'], '2');
    });

    test('truncates a feed that carries more entries than requested', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(
          entries: <String>[
            for (var i = 1; i <= 5; i++)
              atomEntry(id: 'http://arxiv.org/abs/2501.0000${i}v1'),
          ],
        ),
      ]);
      final client = clientWith(adapter);

      final page = await client.search(
        ArxivSearchRequest(query: 'electron', limit: 3),
      );

      expect(page.papers, hasLength(3));
      expect(page.truncated, isTrue);
    });

    test('returns an empty page for an empty feed', () async {
      final adapter = feedAdapter(<String>[atomFeed(totalResults: '0')]);
      final client = clientWith(adapter);

      final page = await client.search(
        ArxivSearchRequest(query: 'nothing-matches'),
      );

      expect(page.isEmpty, isTrue);
      expect(page.truncated, isFalse);
      expect(page.totalResults, 0);
    });

    test('rejects invalid input before any request', () async {
      final adapter = feedAdapter(<String>[]);
      final client = clientWith(adapter);

      Future<void> expectInvalid(ArxivSearchRequest request) async {
        await expectLater(
          client.search(request),
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.invalidInput,
            ),
          ),
        );
      }

      await expectInvalid(ArxivSearchRequest(query: '   '));
      await expectInvalid(ArxivSearchRequest(query: 'x' * 501));
      await expectInvalid(ArxivSearchRequest(query: 'electron\u0000x'));
      await expectInvalid(ArxivSearchRequest(query: '!!!'));
      await expectInvalid(
        ArxivSearchRequest(query: 'electron', category: 'CS.AI!'),
      );
      await expectInvalid(
        ArxivSearchRequest(query: 'electron', category: 'cs.AI/../x'),
      );
      await expectInvalid(ArxivSearchRequest(query: 'electron', limit: 0));
      await expectInvalid(ArxivSearchRequest(query: 'electron', limit: 31));
      await expectInvalid(
        ArxivSearchRequest(
          query: 'electron',
          submittedAfter: DateTime.utc(1980, 1, 1),
        ),
      );
      await expectInvalid(
        ArxivSearchRequest(query: List<String>.filled(17, 'term').join(' ')),
      );
      expect(adapter.requests, isEmpty);
    });

    test('turns malformed responses into protocol failures', () async {
      final adapter = feedAdapter(<String>[
        '<feed><entry></feed>',
        atomFeed(entries: <String>[atomEntry(includeAuthors: false)]),
      ]);
      final client = clientWith(adapter);

      for (var i = 0; i < 2; i++) {
        await expectLater(
          client.search(ArxivSearchRequest(query: 'electron $i')),
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.protocol,
            ),
          ),
        );
      }
    });

    test('rejects an oversized response body', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(entries: <String>[atomEntry()]),
      ]);
      final client = clientWith(adapter, maxResponseCharacters: 64);

      await expectLater(
        client.search(ArxivSearchRequest(query: 'electron')),
        throwsA(
          isA<ArxivFailure>().having(
            (failure) => failure.kind,
            'kind',
            ArxivFailureKind.protocol,
          ),
        ),
      );
    });

    test('429 respects Retry-After before the next request', () async {
      final adapter = adapterWithResponses(clock, <ArxivHttpResponse>[
        atomResponse(
          'slow down',
          statusCode: 429,
          headers: <String, String>{'retry-after': '7'},
        ),
        atomResponse(atomFeed(entries: <String>[atomEntry()])),
      ]);
      final client = clientWith(adapter);

      final failure = await _failureOf(
        client.search(ArxivSearchRequest(query: 'first')),
      );
      expect(failure.kind, ArxivFailureKind.rateLimited);
      expect(failure.retryAfter, const Duration(seconds: 7));

      await client.search(ArxivSearchRequest(query: 'second'));

      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requestTimes[1].difference(adapter.requestTimes[0]),
        const Duration(seconds: 7),
      );
    });

    test('5xx is a network failure and backs off on Retry-After', () async {
      final adapter = adapterWithResponses(clock, <ArxivHttpResponse>[
        atomResponse(
          'busy',
          statusCode: 503,
          headers: <String, String>{'retry-after': '5'},
        ),
        atomResponse(atomFeed(entries: <String>[atomEntry()])),
      ]);
      final client = clientWith(adapter);

      final failure = await _failureOf(
        client.search(ArxivSearchRequest(query: 'first')),
      );
      expect(failure.kind, ArxivFailureKind.network);
      expect(failure.message, contains('503'));

      await client.search(ArxivSearchRequest(query: 'second'));
      expect(
        adapter.requestTimes[1].difference(adapter.requestTimes[0]),
        const Duration(seconds: 5),
      );
    });

    test(
      'Retry-After is anchored to the response, not the request start',
      () async {
        for (final status in <int>[429, 503]) {
          final localClock = FakeArxivClock();
          final adapter = FakeArxivHttpAdapter(
            clock: localClock,
            responder: (url, index) async {
              if (index == 0) {
                // The API took five seconds to answer; Retry-After starts when
                // the response arrives, so the next request is ten seconds
                // after that moment (fifteen after the first attempt).
                localClock.advance(const Duration(seconds: 5));
                return atomResponse(
                  'slow down',
                  statusCode: status,
                  headers: <String, String>{'retry-after': '10'},
                );
              }
              return atomResponse(atomFeed(entries: <String>[atomEntry()]));
            },
          );
          final client = clientWith(adapter, fakeClock: localClock);

          final failure = await _failureOf(
            client.search(ArxivSearchRequest(query: 'first $status')),
          );
          expect(
            failure.kind,
            status == 429
                ? ArxivFailureKind.rateLimited
                : ArxivFailureKind.network,
            reason: 'HTTP $status',
          );

          await client.search(ArxivSearchRequest(query: 'second $status'));

          expect(adapter.requests, hasLength(2), reason: 'HTTP $status');
          expect(
            adapter.requestTimes[1].difference(adapter.requestTimes[0]),
            const Duration(seconds: 15),
            reason: 'HTTP $status',
          );
        }
      },
    );

    test('timeout is distinguishable from a domain failure', () async {
      final pending = Completer<ArxivHttpResponse>();
      final adapter = FakeArxivHttpAdapter(
        clock: clock,
        responder: (url, index) => pending.future,
      );
      final client = clientWith(
        adapter,
        requestTimeout: const Duration(milliseconds: 40),
      );

      final failure = await _failureOf(
        client.search(ArxivSearchRequest(query: 'electron')),
      );
      expect(failure.kind, ArxivFailureKind.timeout);
    });

    test('serializes requests and spaces them by three seconds', () async {
      final gate = Completer<void>();
      final adapter = FakeArxivHttpAdapter(
        clock: clock,
        responder: (url, index) async {
          if (index == 0) {
            await gate.future;
          }
          return atomResponse(atomFeed(entries: <String>[atomEntry()]));
        },
      );
      final client = clientWith(adapter);

      final first = client.search(ArxivSearchRequest(query: 'first'));
      await Future<void>.delayed(Duration.zero);
      final second = client.search(ArxivSearchRequest(query: 'second'));
      await Future<void>.delayed(Duration.zero);

      expect(adapter.requests, hasLength(1));
      expect(adapter.maxActive, 1);

      gate.complete();
      await first;
      await second;

      expect(adapter.requests, hasLength(2));
      expect(adapter.maxActive, 1);
      expect(
        adapter.requestTimes[1].difference(adapter.requestTimes[0]) >=
            const Duration(seconds: 3),
        isTrue,
      );
    });

    test(
      'a call that times out in the queue never reaches the adapter',
      () async {
        final gate = Completer<void>();
        final adapter = FakeArxivHttpAdapter(
          clock: clock,
          responder: (url, index) async {
            if (index == 0) {
              await gate.future;
            }
            return atomResponse(atomFeed(entries: <String>[atomEntry()]));
          },
        );
        final client = clientWith(
          adapter,
          requestTimeout: const Duration(milliseconds: 120),
        );

        final first = client.search(ArxivSearchRequest(query: 'first'));
        final firstSettled = first.then<void>((_) {}, onError: (Object _) {});
        await Future<void>.delayed(Duration.zero);

        // The second call is queued behind the gated first one and times out
        // while still waiting; its deadline must cancel the attempt itself.
        final second = client.search(ArxivSearchRequest(query: 'second'));
        await expectLater(
          second,
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.timeout,
            ),
          ),
        );
        expect(adapter.requests, hasLength(1));

        gate.complete();
        await firstSettled;
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // The expired queued attempt must never send an API request.
        expect(adapter.requests, hasLength(1));

        // The queue itself stays usable for a fresh call.
        await client.search(ArxivSearchRequest(query: 'third'));
        expect(adapter.requests, hasLength(2));
      },
    );

    test(
      'a call expired during a long rate-limit wait never sends a late request',
      () async {
        final adapter = FakeArxivHttpAdapter(
          clock: clock,
          responder: (url, index) async {
            if (index == 0) {
              clock.advance(const Duration(seconds: 1));
              return atomResponse(
                'slow down',
                statusCode: 429,
                headers: <String, String>{'retry-after': '60'},
              );
            }
            return atomResponse(atomFeed(entries: <String>[atomEntry()]));
          },
        );
        final client = clientWith(
          adapter,
          requestTimeout: const Duration(milliseconds: 80),
        );

        final first = await _failureOf(
          client.search(ArxivSearchRequest(query: 'first')),
        );
        expect(first.kind, ArxivFailureKind.rateLimited);
        expect(adapter.requests, hasLength(1));

        // The next call enters the 60-second backoff wait; its caller deadline
        // fires while the clock sleep is still blocked.
        clock.gateSleeps = true;
        final second = client.search(ArxivSearchRequest(query: 'second'));
        await expectLater(
          second,
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.timeout,
            ),
          ),
        );
        expect(adapter.requests, hasLength(1));

        // Releasing the backoff must not turn the expired wait into a late
        // arXiv request.
        clock.releaseSleeps();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(adapter.requests, hasLength(1));

        // A fresh call after the backoff still works, and the expired attempt
        // must not have consumed the request slot or the 3s spacing.
        clock.gateSleeps = false;
        final third = await client.search(ArxivSearchRequest(query: 'third'));
        expect(third.papers, hasLength(1));
        expect(adapter.requests, hasLength(2));
        expect(clock.sleeps, <Duration>[const Duration(seconds: 60)]);
      },
    );

    test(
      'serves a cache hit without a second request and expires by TTL',
      () async {
        final adapter = feedAdapter(<String>[
          atomFeed(entries: <String>[atomEntry()]),
          atomFeed(entries: <String>[atomEntry(title: 'After TTL')]),
        ]);
        final client = clientWith(adapter);

        final request = ArxivSearchRequest(query: 'electron');
        final first = await client.search(request);
        final second = await client.search(
          ArxivSearchRequest(query: 'electron'),
        );
        expect(adapter.requests, hasLength(1));
        expect(second.papers.single, first.papers.single);

        clock.advance(const Duration(minutes: 11));
        final third = await client.search(request);
        expect(adapter.requests, hasLength(2));
        expect(third.papers.single.title, 'After TTL');
      },
    );

    test('cache is bounded by capacity', () async {
      final adapter = FakeArxivHttpAdapter(
        clock: clock,
        responder: (url, index) async =>
            atomResponse(atomFeed(entries: <String>[atomEntry()])),
      );
      final client = clientWith(adapter, cacheCapacity: 1);

      await client.search(ArxivSearchRequest(query: 'first'));
      await client.search(ArxivSearchRequest(query: 'second'));
      await client.search(ArxivSearchRequest(query: 'first'));

      expect(adapter.requests, hasLength(3));
    });
  });

  group('ArxivClient.getPaper', () {
    test('uses id_list and selects the latest version', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(
          entries: <String>[
            atomEntry(id: 'http://arxiv.org/abs/2501.01234v1'),
            atomEntry(
              id: 'http://arxiv.org/abs/2501.01234v2',
              title: 'Version two',
            ),
          ],
        ),
      ]);
      final client = clientWith(adapter);

      final paper = await client.getPaper('2501.01234');

      expect(paper.version, 'v2');
      expect(paper.title, 'Version two');
      expect(adapter.requests.single.queryParameters['id_list'], '2501.01234');
      expect(adapter.requests.single.queryParameters['max_results'], '1');
      expect(adapter.requests.single.queryParameters['start'], '0');
    });

    test('returns the explicitly requested version', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(
          entries: <String>[
            atomEntry(id: 'http://arxiv.org/abs/2501.01234v1'),
            atomEntry(id: 'http://arxiv.org/abs/2501.01234v2'),
          ],
        ),
      ]);
      final client = clientWith(adapter);

      final paper = await client.getPaper('arXiv:2501.01234v1');

      expect(paper.version, 'v1');
      expect(
        adapter.requests.single.queryParameters['id_list'],
        '2501.01234v1',
      );
    });

    test('reports missing papers and versions as notFound', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(totalResults: '0'),
        atomFeed(entries: <String>[atomEntry()]),
      ]);
      final client = clientWith(adapter);

      final missing = await _failureOf(client.getPaper('2501.99999'));
      expect(missing.kind, ArxivFailureKind.notFound);

      final missingVersion = await _failureOf(client.getPaper('2501.01234v9'));
      expect(missingVersion.kind, ArxivFailureKind.notFound);
    });

    test('rejects malformed identifiers without a request', () async {
      final adapter = feedAdapter(<String>[]);
      final client = clientWith(adapter);

      for (final raw in <String>[
        '',
        'https://arxiv.org/abs/2501.01234',
        'not-an-id',
        '2501.01234?x=1',
        'x' * 65,
      ]) {
        await expectLater(
          client.getPaper(raw),
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.invalidInput,
            ),
          ),
          reason: raw,
        );
      }
      expect(adapter.requests, isEmpty);
    });

    test('maps an API error feed to an input failure', () async {
      final adapter = feedAdapter(<String>[
        atomFeed(
          entries: <String>[
            atomEntry(
              id: 'http://arxiv.org/api/errors#incorrect_id_format_for_1',
              title: 'Error',
              summary: 'incorrect id format',
            ),
          ],
        ),
      ]);
      final client = clientWith(adapter);

      final failure = await _failureOf(client.getPaper('2501.01234'));
      expect(failure.kind, ArxivFailureKind.invalidInput);
    });
  });
}

Future<ArxivFailure> _failureOf(Future<Object?> future) async {
  try {
    await future;
  } on ArxivFailure catch (failure) {
    return failure;
  }
  fail('Expected an ArxivFailure');
}

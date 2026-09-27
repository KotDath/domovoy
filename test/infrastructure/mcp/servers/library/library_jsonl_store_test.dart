import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_replay.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage.dart';
import 'package:domovoy/infrastructure/mcp/servers/library/library.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/memory_jsonl_storage.dart';
import 'library_test_support.dart';

/// Storage whose publish step fails while reads keep working.
final class _FailingPublishStorage implements JsonlStreamStorage {
  _FailingPublishStorage(this.inner);

  final FakeMemoryJsonlStorage inner;

  @override
  Future<void> cleanup(String key) => inner.cleanup(key);

  @override
  Future<List<String>> listKeys() => inner.listKeys();

  @override
  Future<void> publish(String key, List<int> contents) async {
    throw StateError('publish failed');
  }

  @override
  Future<Stream<List<int>>?> read(String key) => inner.read(key);
}

void main() {
  late FakeMemoryJsonlStorage storage;
  late FakeLibraryClock clock;
  late JsonlLibraryStore store;
  late CancellationToken token;

  setUp(() {
    storage = FakeMemoryJsonlStorage();
    clock = FakeLibraryClock();
    store = JsonlLibraryStore(
      storage: storage,
      clock: clock,
      ids: SequentialLibraryIdGenerator(),
    );
    token = CancellationSource().token;
  });

  Future<LibrarySaveResult> save({
    String topic = 'Research topic',
    List<Paper>? papers,
    Digest? digest,
    String? runId,
    CancellationToken? cancellation,
  }) {
    return store.save(
      topic: topic,
      papers: papers ?? <Paper>[libraryPaper()],
      digest: digest ?? libraryDigest(),
      runId: runId,
      cancellation: cancellation ?? token,
    );
  }

  Future<String> rawStream(LibraryId id) async {
    final chunks = await storage.read(JsonlLibraryStore.streamKeyFor(id));
    final bytes = await chunks!.toList();
    return utf8.decode(bytes.expand((chunk) => chunk).toList());
  }

  group('save', () {
    test('persists a record that survives a store restart', () async {
      final saved = await save(runId: 'run_1');

      final reopened = JsonlLibraryStore(
        storage: storage,
        clock: clock,
        ids: SequentialLibraryIdGenerator(),
      );
      final loaded = await reopened.find(
        saved.record.libraryId,
        cancellation: token,
      );

      expect(saved.created, isTrue);
      expect(loaded, saved.record);
      expect(loaded!.topic, 'Research topic');
      expect(loaded.runId, 'run_1');
      expect(loaded.papers.single.arxivId.value, '2501.01234');
      expect(loaded.digest.items.single.arxivId.value, '2501.01234');
      expect(loaded.savedAt, DateTime.utc(2025, 1, 6, 12, 5));
    });

    test('writes no PDF, path or secret material into the stream', () async {
      final saved = await save(runId: 'run_1');

      final text = await rawStream(saved.record.libraryId);

      expect(text, contains('domovoy.library_record_operation'));
      expect(text, contains('"schemaVersion":1'));
      for (final forbidden in <String>[
        'pdf',
        'PDF',
        'apiKey',
        'secret',
        'token',
        '/tmp',
        'file://',
      ]) {
        expect(text, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test('reuses the same libraryId for a repeated runId payload', () async {
      final first = await save(runId: 'run_1');
      final second = await save(runId: 'run_1');

      expect(first.created, isTrue);
      expect(second.created, isFalse);
      expect(second.record.libraryId, first.record.libraryId);
      expect(second.record.payloadFingerprint, first.record.payloadFingerprint);
      expect(storage.keys, hasLength(1));
    });

    test('keeps runId idempotency across a store restart', () async {
      final first = await save(runId: 'run_1');
      final reopened = JsonlLibraryStore(
        storage: storage,
        clock: clock,
        ids: SequentialLibraryIdGenerator(),
      );

      final repeated = await reopened.save(
        topic: 'Research topic',
        papers: <Paper>[libraryPaper()],
        digest: libraryDigest(),
        runId: 'run_1',
        cancellation: token,
      );

      expect(repeated.created, isFalse);
      expect(repeated.record.libraryId, first.record.libraryId);
      expect(storage.keys, hasLength(1));
    });

    test('returns the same record when the paper order differs', () async {
      final first = await save(
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
        runId: 'run_1',
      );
      final second = await save(
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
        runId: 'run_1',
      );

      expect(second.created, isFalse);
      expect(second.record.libraryId, first.record.libraryId);
      expect(storage.keys, hasLength(1));
    });

    test('conflicts when a runId is retried with a different digest', () async {
      final first = await save(runId: 'run_1');
      final before = await rawStream(first.record.libraryId);

      await expectLater(
        save(
          digest: libraryDigest(overview: 'Completely different synthesis'),
          runId: 'run_1',
        ),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.conflict,
          ),
        ),
      );

      expect(storage.keys, hasLength(1));
      expect(await rawStream(first.record.libraryId), before);
    });

    test('conflicts when a runId is retried with a different topic', () async {
      await save(runId: 'run_1');

      await expectLater(
        save(
          topic: 'Another topic',
          digest: libraryDigest(topic: 'Another topic'),
          runId: 'run_1',
        ),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.conflict,
          ),
        ),
      );
      expect(storage.keys, hasLength(1));
    });

    test(
      'conflicts when a runId is retried with a different paper set',
      () async {
        await save(runId: 'run_1');

        await expectLater(
          save(
            papers: <Paper>[
              libraryPaper(),
              libraryPaper(arxivId: '2501.00002'),
            ],
            digest: libraryDigest(
              items: <DigestItem>[
                DigestItem(arxivId: '2501.01234', finding: 'First'),
                DigestItem(arxivId: '2501.00002', finding: 'Second'),
              ],
            ),
            runId: 'run_1',
          ),
          throwsA(
            isA<LibraryException>().having(
              (error) => error.error.kind,
              'kind',
              LibraryErrorKind.conflict,
            ),
          ),
        );
        expect(storage.keys, hasLength(1));
      },
    );

    test('manual saves without runId always get fresh identities', () async {
      final first = await save();
      final second = await save();

      expect(first.created, isTrue);
      expect(second.created, isTrue);
      expect(second.record.libraryId, isNot(first.record.libraryId));
      expect(storage.keys, hasLength(2));
    });

    test('rejects an oversized record before writing anything', () async {
      final limited = JsonlLibraryStore(
        storage: storage,
        limits: const LibraryLimits(
          maxPaperBytes: 1024,
          maxPapersBytes: 2048,
          maxDigestBytes: 2048,
          maxRecordBytes: 4096,
          maxStreamBytes: 8192,
        ).validate(),
        clock: clock,
        ids: SequentialLibraryIdGenerator(),
      );

      await expectLater(
        limited.save(
          topic: 'Research topic',
          papers: <Paper>[libraryPaper(abstractText: 'x' * 6000)],
          digest: libraryDigest(),
          cancellation: token,
        ),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.invalidInput,
          ),
        ),
      );
      expect(storage.keys, isEmpty);
    });

    test('honors cancellation before touching storage', () async {
      final cancellation = CancellationSource()..cancel();

      await expectLater(
        save(cancellation: cancellation.token),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.cancelled,
          ),
        ),
      );
      expect(storage.keys, isEmpty);
    });

    test('maps a failed publish to a persistence error', () async {
      final failing = JsonlLibraryStore(
        storage: _FailingPublishStorage(storage),
        clock: clock,
        ids: SequentialLibraryIdGenerator(),
      );

      await expectLater(
        failing.save(
          topic: 'Research topic',
          papers: <Paper>[libraryPaper()],
          digest: libraryDigest(),
          cancellation: token,
        ),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.persistence,
          ),
        ),
      );
      expect(storage.keys, isEmpty);
    });
  });

  group('find', () {
    test('returns null for an unknown identity', () async {
      expect(
        await store.find(
          LibraryId('lib_ffffffffffffffffffffffffffffffff'),
          cancellation: token,
        ),
        isNull,
      );
    });

    test(
      'fails closed on a damaged stream instead of a partial record',
      () async {
        final saved = await save();
        storage.replaceText(
          JsonlLibraryStore.streamKeyFor(saved.record.libraryId),
          'not json at all\n',
        );

        await expectLater(
          store.find(saved.record.libraryId, cancellation: token),
          throwsA(
            isA<LibraryException>().having(
              (error) => error.error.kind,
              'kind',
              LibraryErrorKind.corruption,
            ),
          ),
        );
      },
    );

    test('rejects a stored record with an unknown schema version', () async {
      final saved = await save();
      final key = JsonlLibraryStore.streamKeyFor(saved.record.libraryId);
      final text = await rawStream(saved.record.libraryId);
      storage.replaceText(
        key,
        text.replaceFirst('"schemaVersion":1', '"schemaVersion":2'),
      );

      await expectLater(
        store.find(saved.record.libraryId, cancellation: token),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.corruption,
          ),
        ),
      );
    });
  });

  group('list', () {
    test('returns newest first with a stable keyset cursor', () async {
      final first = await save();
      clock.advance(const Duration(minutes: 1));
      final second = await save();
      clock.advance(const Duration(minutes: 1));
      final third = await save();

      final pageOne = await store.list(limit: 2, cancellation: token);
      expect(pageOne.cards.map((card) => card.libraryId), <LibraryId>[
        third.record.libraryId,
        second.record.libraryId,
      ]);
      expect(pageOne.totalCount, 3);
      expect(pageOne.nextCursor, isNotNull);

      // A newer record inserted between the pages must not shift page two.
      clock.advance(const Duration(minutes: 1));
      final fourth = await save();

      final pageTwo = await store.list(
        limit: 2,
        cursor: pageOne.nextCursor,
        cancellation: token,
      );
      expect(pageTwo.cards.map((card) => card.libraryId), <LibraryId>[
        first.record.libraryId,
      ]);
      expect(pageTwo.nextCursor, isNull);
      expect(pageTwo.totalCount, 4);

      final refreshed = await store.list(limit: 2, cancellation: token);
      expect(refreshed.cards.map((card) => card.libraryId), <LibraryId>[
        fourth.record.libraryId,
        third.record.libraryId,
      ]);
    });

    test('orders equal timestamps by identity descending', () async {
      final first = await save();
      final second = await save();

      final page = await store.list(limit: 10, cancellation: token);

      expect(page.cards.map((card) => card.libraryId), <LibraryId>[
        second.record.libraryId,
        first.record.libraryId,
      ]);
    });

    test(
      'searches topic, digest text, papers and runId case-insensitively',
      () async {
        final alpha = await save(
          topic: 'Alpha topic',
          papers: <Paper>[libraryPaper(arxivId: '2501.00001')],
          digest: libraryDigest(
            topic: 'Alpha topic',
            overview: 'Overview about transformers',
            items: <DigestItem>[
              DigestItem(arxivId: '2501.00001', finding: 'Grounding finding'),
            ],
          ),
          runId: 'run_alpha',
        );
        final beta = await save(
          topic: 'Beta topic',
          papers: <Paper>[
            libraryPaper(arxivId: '2501.00002', title: 'Beta paper title'),
          ],
          digest: libraryDigest(
            topic: 'Beta topic',
            overview: 'Overview about diffusion',
            items: <DigestItem>[
              DigestItem(arxivId: '2501.00002', finding: 'Beta finding'),
            ],
          ),
          runId: 'run_beta',
        );

        Future<List<LibraryId>> search(String query) async {
          final page = await store.list(
            query: query,
            limit: 10,
            cancellation: token,
          );
          return page.cards.map((card) => card.libraryId).toList();
        }

        expect(await search('TRANSFORMERS'), <LibraryId>[
          alpha.record.libraryId,
        ]);
        expect(await search('beta paper'), <LibraryId>[beta.record.libraryId]);
        expect(await search('2501.00002'), <LibraryId>[beta.record.libraryId]);
        expect(await search('run_beta'), <LibraryId>[beta.record.libraryId]);
        expect(
          (await store.list(
            query: 'topic',
            limit: 10,
            cancellation: token,
          )).totalCount,
          2,
        );
        expect(
          (await store.list(
            query: 'nothing here',
            limit: 10,
            cancellation: token,
          )).totalCount,
          0,
        );
      },
    );

    test('rejects a cursor from another query and malformed cursors', () async {
      await save();
      clock.advance(const Duration(minutes: 1));
      await save();

      final page = await store.list(
        query: 'topic',
        limit: 1,
        cancellation: token,
      );
      expect(page.nextCursor, isNotNull);

      await expectLater(
        store.list(
          query: 'different',
          limit: 1,
          cursor: page.nextCursor,
          cancellation: token,
        ),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.invalidInput,
          ),
        ),
      );
      await expectLater(
        store.list(limit: 1, cursor: 'not a cursor', cancellation: token),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.invalidInput,
          ),
        ),
      );
    });

    test('rejects a non-positive or oversized page size', () async {
      for (final limit in <int>[0, -1, 51]) {
        await expectLater(
          store.list(limit: limit, cancellation: token),
          throwsA(
            isA<LibraryException>().having(
              (error) => error.error.kind,
              'kind',
              LibraryErrorKind.invalidInput,
            ),
          ),
          reason: 'limit $limit',
        );
      }
    });

    test('fails closed when a neighbour stream is damaged', () async {
      final saved = await save();
      storage.replaceText(
        JsonlLibraryStore.streamKeyFor(saved.record.libraryId),
        '{}\n',
      );

      await expectLater(
        store.list(limit: 10, cancellation: token),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.corruption,
          ),
        ),
      );
    });

    test('fails closed on a stream key that is not a library record', () async {
      await save();
      storage.replaceText('stray-stream', '{}\n');

      await expectLater(
        store.list(limit: 10, cancellation: token),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.corruption,
          ),
        ),
      );
    });

    test('maps a failed key listing to a persistence error', () async {
      await save();
      storage.failList = true;

      await expectLater(
        store.list(limit: 10, cancellation: token),
        throwsA(
          isA<LibraryException>().having(
            (error) => error.error.kind,
            'kind',
            LibraryErrorKind.persistence,
          ),
        ),
      );
    });
  });

  group('replay', () {
    test('tolerates a truncated tail and keeps the complete record', () async {
      final saved = await save();
      final key = JsonlLibraryStore.streamKeyFor(saved.record.libraryId);
      storage.appendText(key, '{"type":"domovoy.library_record_op');

      final loaded = await store.find(
        saved.record.libraryId,
        cancellation: token,
      );
      expect(loaded, saved.record);

      final replay = JsonlLibraryReplay(
        limits: const LibraryLimits().jsonlLimits,
      );
      final chunks = await storage.read(key);
      final result = await replay.replay(saved.record.libraryId, chunks!);
      expect(result.needsRepair, isTrue);
      expect(result.record, saved.record);
      expect(result.sequence, 0);
      expect(result.recordRevision, 0);
    });

    test('rejects an envelope with an unknown version', () async {
      final saved = await save();
      final key = JsonlLibraryStore.streamKeyFor(saved.record.libraryId);
      final text = await rawStream(saved.record.libraryId);
      storage.replaceText(key, text.replaceFirst('"version":1', '"version":2'));

      final replay = JsonlLibraryReplay(
        limits: const LibraryLimits().jsonlLimits,
      );
      final chunks = await storage.read(key);
      await expectLater(
        replay.replay(saved.record.libraryId, chunks!),
        throwsA(isA<JsonlReplayException>()),
      );
    });

    test('rejects a record whose identity does not match its stream', () async {
      final saved = await save();
      final key = JsonlLibraryStore.streamKeyFor(saved.record.libraryId);
      final text = await rawStream(saved.record.libraryId);
      storage.replaceText(
        key,
        text.replaceFirst(
          saved.record.libraryId.value,
          'lib_ffffffffffffffffffffffffffffffff',
        ),
      );

      final replay = JsonlLibraryReplay(
        limits: const LibraryLimits().jsonlLimits,
      );
      final chunks = await storage.read(key);
      await expectLater(
        replay.replay(saved.record.libraryId, chunks!),
        throwsA(isA<JsonlReplayException>()),
      );
    });
  });
}

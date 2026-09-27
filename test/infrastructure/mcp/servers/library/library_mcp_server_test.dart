import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/mcp/servers/library/library.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/memory_jsonl_storage.dart';
import 'library_test_support.dart';

/// Repository that fails with a chosen domain error, for handler mapping.
final class _FailingRepository implements LibraryRepository {
  _FailingRepository(this.error);

  final LibraryError error;

  @override
  Future<LibraryRecord?> find(
    LibraryId id, {
    required CancellationToken cancellation,
  }) async => throw LibraryException(error);

  @override
  Future<LibraryPage> list({
    String? query,
    required int limit,
    String? cursor,
    required CancellationToken cancellation,
  }) async => throw LibraryException(error);

  @override
  Future<LibrarySaveResult> save({
    required String topic,
    required List<Paper> papers,
    required Digest digest,
    String? runId,
    required CancellationToken cancellation,
  }) async => throw LibraryException(error);
}

void main() {
  late FakeMemoryJsonlStorage storage;
  late FakeLibraryClock clock;

  setUp(() {
    storage = FakeMemoryJsonlStorage();
    clock = FakeLibraryClock();
  });

  Future<LibraryHarness> start({
    LibraryLimits limits = const LibraryLimits(),
    LibraryRepository? repository,
  }) async {
    final harness = await LibraryHarness.start(
      storage: storage,
      repository: repository,
      limits: limits,
      clock: clock,
      ids: SequentialLibraryIdGenerator(),
    );
    addTearDown(harness.close);
    return harness;
  }

  group('LibraryMcpServerFactory', () {
    test('exposes a stable local server contract', () {
      final factory = LibraryMcpServerFactory(
        storage: storage,
        clock: clock,
        ids: SequentialLibraryIdGenerator(),
      );
      final definition = factory.create();

      expect(definition.id, libraryServerId);
      expect(definition.serverId, McpConnectionId('library'));
      expect(definition.displayName, 'Library');
      expect(definition.version, '1.0.0');
      expect(definition.instructions, isNotNull);
      expect(factory.create().id, 'library');
      expect(factory.repository, isA<JsonlLibraryStore>());
    });

    test('rejects an invalid limit configuration synchronously', () {
      expect(
        () => LibraryMcpServerFactory(
          storage: storage,
          limits: const LibraryLimits(minPapers: 5, maxPapers: 2),
        ),
        throwsA(isA<McpException>()),
      );
      expect(
        () => LibraryMcpServerFactory(
          storage: storage,
          limits: const LibraryLimits(defaultListLimit: 10, maxListLimit: 5),
        ),
        throwsA(isA<McpException>()),
      );
    });

    test('withRepository composes the injected owner', () {
      final repository = _FailingRepository(
        LibraryError(kind: LibraryErrorKind.corruption, message: 'injected'),
      );
      final factory = LibraryMcpServerFactory.withRepository(
        repository: repository,
      );

      expect(factory.repository, same(repository));
    });
  });

  group('tool catalog', () {
    test('advertises three strict tools with annotations', () async {
      final harness = await start();

      final page = await harness.listTools();
      expect(page.map((tool) => tool.originalName).toSet(), <String>{
        librarySaveToolName,
        libraryListToolName,
        libraryGetToolName,
      });

      final save = harness.tool(page, librarySaveToolName);
      expect(save.title, isNotEmpty);
      expect(save.description, contains('Digest v1'));
      expect(save.inputSchema['type'], 'object');
      expect(save.inputSchema['additionalProperties'], isFalse);
      expect(save.inputSchema['required'], <String>[
        'digest',
        'papers',
        'topic',
      ]);
      final saveProperties =
          save.inputSchema['properties']! as Map<String, Object?>;
      expect(saveProperties.keys.toSet(), <String>{
        'digest',
        'papers',
        'topic',
        'runId',
      });
      expect(save.outputSchema!['additionalProperties'], isFalse);
      expect(
        save.outputSchema!['required'],
        containsAll(<String>[
          'schemaVersion',
          'libraryId',
          'savedAt',
          'topic',
          'paperCount',
          'itemCount',
          'created',
          'recordRef',
        ]),
      );
      expect(save.annotations?['readOnlyHint'], isFalse);
      expect(save.annotations?['idempotentHint'], isTrue);

      final list = harness.tool(page, libraryListToolName);
      expect(list.inputSchema['required'], anyOf(isNull, isEmpty));
      expect(list.annotations?['readOnlyHint'], isTrue);
      final listProperties =
          list.inputSchema['properties']! as Map<String, Object?>;
      expect(listProperties.keys.toSet(), <String>{'query', 'limit', 'cursor'});

      final get = harness.tool(page, libraryGetToolName);
      final getProperties =
          get.inputSchema['properties']! as Map<String, Object?>;
      final libraryId = getProperties['libraryId']! as Map<String, Object?>;
      expect(libraryId['pattern'], r'^lib_[a-z0-9]{16,64}$');
      expect(get.outputSchema!['additionalProperties'], isFalse);
      expect(get.annotations?['readOnlyHint'], isTrue);
    });

    test('input and output schemas pass the B2 provider profiles', () async {
      final harness = await start();

      final page = await harness.listTools();
      for (final name in <String>[
        librarySaveToolName,
        libraryListToolName,
        libraryGetToolName,
      ]) {
        final tool = harness.tool(page, name);
        for (final profile in <ToolSchemaProfile>[
          ToolSchemaProfile.openaiChatCompletions,
          ToolSchemaProfile.openaiResponses,
          ToolSchemaProfile.portable,
        ]) {
          expect(
            toolSchemaProblem(tool.inputSchema, profile: profile),
            isNull,
            reason: '$name input schema for ${profile.id}',
          );
          expect(
            toolSchemaProblem(tool.outputSchema!, profile: profile),
            isNull,
            reason: '$name output schema for ${profile.id}',
          );
          expect(
            representToolSchema(
              tool.inputSchema,
              profile: profile,
            ).isRepresented,
            isTrue,
            reason: '$name input schema is representable for ${profile.id}',
          );
          expect(
            representToolSchema(
              tool.outputSchema!,
              profile: profile,
            ).isRepresented,
            isTrue,
            reason: '$name output schema is representable for ${profile.id}',
          );
        }
      }
    });
  });

  group('save_digest', () {
    test('saves a digest and returns its structured result', () async {
      final harness = await start();

      final result = await harness.save(librarySaveArgs(runId: 'run_1'));

      expect(result.isError, isFalse);
      final structured = result.structuredContent! as Map<String, Object?>;
      expect(structured['schemaVersion'], 1);
      expect(structured['created'], isTrue);
      expect(structured['paperCount'], 1);
      expect(structured['itemCount'], 1);
      expect(structured['runId'], 'run_1');
      expect(structured['topic'], 'Research topic');
      expect(structured['libraryId'], matches(RegExp(r'^lib_[a-z0-9]{32}$')));
      expect(
        structured['recordRef'],
        'domovoy://library/${structured['libraryId']}',
      );
      expect(result.textContent, contains('Сохранено в библиотеке'));
      expect(result.textContent, contains('только по аннотациям'));
      expect(storage.keys, hasLength(1));

      final fetched = await harness.get(structured['libraryId']! as String);
      expect(fetched.isError, isFalse);
      final record = fetched.structuredContent! as Map<String, Object?>;
      expect(record['libraryId'], structured['libraryId']);
      expect(record['topic'], 'Research topic');
      expect(record['revision'], 0);
      final papers = record['papers']! as List<Object?>;
      expect(papers, hasLength(1));
      final digest = record['digest']! as Map<String, Object?>;
      expect(digest['sourceScope'], 'abstract');
    });

    test('returns the same libraryId for a repeated runId payload', () async {
      final harness = await start();

      final first = await harness.save(librarySaveArgs(runId: 'run_1'));
      final second = await harness.save(librarySaveArgs(runId: 'run_1'));

      expect(first.isError, isFalse);
      expect(second.isError, isFalse);
      expect(
        (second.structuredContent! as Map<String, Object?>)['libraryId'],
        (first.structuredContent! as Map<String, Object?>)['libraryId'],
      );
      expect(
        (second.structuredContent! as Map<String, Object?>)['created'],
        isFalse,
      );
      expect(second.textContent, contains('без дубликата'));
      expect(storage.keys, hasLength(1));
    });

    test('reports a conflict when the runId payload changed', () async {
      final harness = await start();
      await harness.save(librarySaveArgs(runId: 'run_1'));

      final conflict = await harness.save(
        librarySaveArgs(
          runId: 'run_1',
          digest: libraryDigest(overview: 'A different synthesis'),
        ),
      );

      expect(conflict.isError, isTrue);
      expect(conflict.structuredContent, isNull);
      expect(conflict.textContent, startsWith('[library:conflict]'));
      expect(storage.keys, hasLength(1));
    });

    test('manual saves without runId create distinct records', () async {
      final harness = await start();

      final first = await harness.save(librarySaveArgs());
      final second = await harness.save(librarySaveArgs());

      final firstId =
          (first.structuredContent! as Map<String, Object?>)['libraryId'];
      final secondId =
          (second.structuredContent! as Map<String, Object?>)['libraryId'];
      expect(firstId, isNot(secondId));
      expect(storage.keys, hasLength(2));
    });

    test('rejects an unsupported digest schema version explicitly', () async {
      final harness = await start();
      final arguments = librarySaveArgs();
      final digest = <String, Object?>{
        ...arguments['digest']! as Map<String, Object?>,
        'schemaVersion': 2,
      };

      final result = await harness.save(<String, Object?>{
        ...arguments,
        'digest': digest,
      });

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[library:version_mismatch]'));
      expect(result.structuredContent, isNull);
      expect(storage.keys, isEmpty);
    });

    test('rejects an unsupported paper schema version explicitly', () async {
      final harness = await start();
      final arguments = librarySaveArgs();
      final papers = <Object?>[
        <String, Object?>{
          ...(arguments['papers']! as List<Object?>).single
              as Map<String, Object?>,
          'schemaVersion': 2,
        },
      ];

      final result = await harness.save(<String, Object?>{
        ...arguments,
        'papers': papers,
      });

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[library:version_mismatch]'));
      expect(storage.keys, isEmpty);
    });

    test(
      'rejects a digest item that is not part of the supplied papers',
      () async {
        final harness = await start();

        final result = await harness.save(
          librarySaveArgs(
            digest: libraryDigest(
              items: <DigestItem>[
                DigestItem(arxivId: '2502.99999', finding: 'Foreign finding'),
              ],
            ),
          ),
        );

        expect(result.isError, isTrue);
        expect(result.textContent, startsWith('[library:invalid_input]'));
        expect(result.textContent, contains('2502.99999'));
        expect(result.structuredContent, isNull);
        expect(storage.keys, isEmpty);
      },
    );

    test('rejects a mismatched topic and duplicate paper snapshots', () async {
      final harness = await start();

      final mismatched = await harness.save(
        librarySaveArgs(topic: 'Another topic'),
      );
      expect(mismatched.isError, isTrue);
      expect(mismatched.textContent, startsWith('[library:invalid_input]'));

      final duplicated = await harness.save(
        librarySaveArgs(papers: <Paper>[libraryPaper(), libraryPaper()]),
      );
      expect(duplicated.isError, isTrue);
      expect(duplicated.textContent, startsWith('[library:invalid_input]'));
      expect(storage.keys, isEmpty);
    });

    test('rejects an unknown paper field at the protocol boundary', () async {
      final harness = await start();
      final arguments = librarySaveArgs();
      final papers = <Object?>[
        <String, Object?>{
          ...(arguments['papers']! as List<Object?>).single
              as Map<String, Object?>,
          'pdfUrl': 'https://example.com/paper.pdf',
        },
      ];

      try {
        final result = await harness.save(<String, Object?>{
          ...arguments,
          'papers': papers,
        });
        expect(result.isError, isTrue);
        expect(result.structuredContent, isNull);
      } on McpException {
        // mcp_dart rejects additionalProperties before the handler runs.
      }
      expect(storage.keys, isEmpty);
    });

    test(
      'rejects aggregate paper bytes that the schema cannot bound',
      () async {
        final harness = await start(
          limits: const LibraryLimits(
            maxPaperBytes: 2048,
            maxPapersBytes: 4096,
            maxDigestBytes: 4096,
            maxRecordBytes: 8192,
            maxStreamBytes: 16384,
          ),
        );
        final longAbstract = 'a' * 1500;

        final result = await harness.save(
          librarySaveArgs(
            papers: <Paper>[
              libraryPaper(arxivId: '2501.00001', abstractText: longAbstract),
              libraryPaper(arxivId: '2501.00002', abstractText: longAbstract),
              libraryPaper(arxivId: '2501.00003', abstractText: longAbstract),
            ],
            digest: libraryDigest(
              items: <DigestItem>[
                DigestItem(arxivId: '2501.00001', finding: 'First'),
                DigestItem(arxivId: '2501.00002', finding: 'Second'),
                DigestItem(arxivId: '2501.00003', finding: 'Third'),
              ],
            ),
          ),
        );

        expect(result.isError, isTrue);
        expect(result.textContent, startsWith('[library:invalid_input]'));
        expect(result.textContent, contains('лимит'));
        expect(storage.keys, isEmpty);
      },
    );

    test('rejects a digest payload over the digest byte limit', () async {
      final harness = await start(
        limits: const LibraryLimits(
          maxPaperBytes: 4096,
          maxPapersBytes: 8192,
          maxDigestBytes: 4096,
          maxRecordBytes: 16384,
          maxStreamBytes: 32768,
        ),
      );

      final result = await harness.save(
        librarySaveArgs(digest: libraryDigest(overview: 'o' * 4000)),
      );

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[library:invalid_input]'));
      expect(storage.keys, isEmpty);
    });

    test('maps a repository version mismatch to the wire taxonomy', () async {
      final harness = await start(
        repository: _FailingRepository(
          LibraryError(
            kind: LibraryErrorKind.versionMismatch,
            message: 'Unsupported stored schema.',
          ),
        ),
      );

      final result = await harness.save(librarySaveArgs());

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[library:version_mismatch]'));
    });

    test('maps a repository corruption to the wire taxonomy', () async {
      final harness = await start(
        repository: _FailingRepository(
          LibraryError(
            kind: LibraryErrorKind.corruption,
            message: 'Damaged stream.',
          ),
        ),
      );

      final result = await harness.save(librarySaveArgs());

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[library:corruption]'));
    });

    test(
      'maps a repository persistence failure to the wire taxonomy',
      () async {
        final harness = await start(
          repository: _FailingRepository(
            LibraryError(
              kind: LibraryErrorKind.persistence,
              message: 'Publish failed.',
            ),
          ),
        );

        final result = await harness.save(librarySaveArgs());

        expect(result.isError, isTrue);
        expect(result.textContent, startsWith('[library:persistence]'));
      },
    );

    test('reports cancellation without writing a record', () async {
      final harness = await start();
      final cancellation = CancellationSource()..cancel();

      try {
        final result = await harness.save(
          librarySaveArgs(),
          cancellation: cancellation.token,
        );
        expect(result.isError, isTrue);
        expect(result.textContent, contains('cancelled'));
      } on McpException catch (error) {
        expect(error.error.kind, McpErrorKind.cancelled);
      }
      expect(storage.keys, isEmpty);
    });
  });

  group('list_saved', () {
    test('returns newest first and keeps pagination stable', () async {
      final harness = await start();
      final first = await harness.save(librarySaveArgs());
      clock.advance(const Duration(minutes: 1));
      await harness.save(librarySaveArgs());
      clock.advance(const Duration(minutes: 1));
      final third = await harness.save(librarySaveArgs());

      final pageOne = await harness.list(
        arguments: <String, Object?>{'limit': 2},
      );
      expect(pageOne.isError, isFalse);
      final firstStructured =
          pageOne.structuredContent! as Map<String, Object?>;
      expect(firstStructured['totalCount'], 3);
      expect(firstStructured['nextCursor'], isNotNull);
      final firstIds = (firstStructured['records']! as List<Object?>)
          .map((card) => (card! as Map<String, Object?>)['libraryId'])
          .toList();
      expect(
        firstIds.first,
        (third.structuredContent! as Map<String, Object?>)['libraryId'],
      );

      // A newer record inserted between the pages must not shift page two.
      clock.advance(const Duration(minutes: 1));
      await harness.save(librarySaveArgs());

      final pageTwo = await harness.list(
        arguments: <String, Object?>{
          'limit': 2,
          'cursor': firstStructured['nextCursor'],
        },
      );
      final secondStructured =
          pageTwo.structuredContent! as Map<String, Object?>;
      expect(pageTwo.isError, isFalse);
      expect(secondStructured['records'], hasLength(1));
      expect(secondStructured['nextCursor'], isNull);
      expect(
        ((secondStructured['records']! as List<Object?>).single
            as Map<String, Object?>)['libraryId'],
        (first.structuredContent! as Map<String, Object?>)['libraryId'],
      );
    });

    test('searches saved records case-insensitively', () async {
      final harness = await start();
      await harness.save(
        librarySaveArgs(
          topic: 'Alpha topic',
          digest: libraryDigest(topic: 'Alpha topic'),
        ),
      );
      clock.advance(const Duration(minutes: 1));
      final beta = await harness.save(
        librarySaveArgs(
          topic: 'Beta topic',
          digest: libraryDigest(topic: 'Beta topic', overview: 'Diffusion'),
        ),
      );

      final result = await harness.list(
        arguments: <String, Object?>{'query': 'BETA'},
      );

      expect(result.isError, isFalse);
      final structured = result.structuredContent! as Map<String, Object?>;
      expect(structured['totalCount'], 1);
      expect(
        (structured['records']! as List<Object?>).single,
        isA<Map<String, Object?>>().having(
          (card) => card['libraryId'],
          'libraryId',
          (beta.structuredContent! as Map<String, Object?>)['libraryId'],
        ),
      );
    });

    test('returns an empty page for an empty library', () async {
      final harness = await start();

      final result = await harness.list();

      expect(result.isError, isFalse);
      final structured = result.structuredContent! as Map<String, Object?>;
      expect(structured['records'], isEmpty);
      expect(structured['totalCount'], 0);
      expect(structured.containsKey('nextCursor'), isFalse);
    });

    test('rejects a cursor from another query', () async {
      final harness = await start();
      await harness.save(librarySaveArgs());
      clock.advance(const Duration(minutes: 1));
      await harness.save(librarySaveArgs());

      final page = await harness.list(
        arguments: <String, Object?>{'query': 'topic', 'limit': 1},
      );
      final cursor =
          (page.structuredContent! as Map<String, Object?>)['nextCursor'];

      final result = await harness.list(
        arguments: <String, Object?>{
          'query': 'different',
          'limit': 1,
          'cursor': cursor,
        },
      );

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[library:invalid_input]'));
    });

    test('rejects a malformed cursor', () async {
      final harness = await start();

      final result = await harness.list(
        arguments: <String, Object?>{'cursor': 'not a cursor'},
      );

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[library:invalid_input]'));
    });

    test('rejects an out-of-range limit at the protocol boundary', () async {
      final harness = await start();

      for (final limit in <int>[0, 51]) {
        try {
          final result = await harness.list(
            arguments: <String, Object?>{'limit': limit},
          );
          expect(result.isError, isTrue);
        } on McpException {
          // mcp_dart rejects the declared bounds before the handler runs.
        }
      }
    });

    test('accepts an integral numeric limit', () async {
      final harness = await start();
      await harness.save(librarySaveArgs());
      clock.advance(const Duration(minutes: 1));
      await harness.save(librarySaveArgs());

      final result = await harness.list(
        arguments: <String, Object?>{'limit': 1.0},
      );

      expect(result.isError, isFalse);
      expect(
        (result.structuredContent! as Map<String, Object?>)['records'],
        hasLength(1),
      );
    });
  });

  group('get_saved', () {
    test('returns the full record and reports an unknown identity', () async {
      final harness = await start();
      final saved = await harness.save(librarySaveArgs());
      final libraryId =
          (saved.structuredContent! as Map<String, Object?>)['libraryId']!
              as String;

      final found = await harness.get(libraryId);
      expect(found.isError, isFalse);
      expect(
        (found.structuredContent! as Map<String, Object?>)['schemaVersion'],
        libraryRecordSchemaVersion,
      );
      expect(
        (found.structuredContent! as Map<String, Object?>)['digest'],
        isA<Map<String, Object?>>(),
      );

      final missing = await harness.get('lib_ffffffffffffffffffffffffffffffff');
      expect(missing.isError, isTrue);
      expect(missing.textContent, startsWith('[library:not_found]'));
      expect(missing.structuredContent, isNull);
    });

    test('rejects a malformed identity at the protocol boundary', () async {
      final harness = await start();

      try {
        final result = await harness.get('not-a-library-id');
        expect(result.isError, isTrue);
      } on McpException {
        // mcp_dart rejects the declared pattern before the handler runs.
      }
    });
  });

  group('corruption', () {
    test('fails get and list closed on a damaged stream', () async {
      final harness = await start();
      final saved = await harness.save(librarySaveArgs());
      final libraryId =
          (saved.structuredContent! as Map<String, Object?>)['libraryId']!
              as String;
      storage.replaceText(libraryId, 'not json at all\n');

      final fetched = await harness.get(libraryId);
      expect(fetched.isError, isTrue);
      expect(fetched.textContent, startsWith('[library:corruption]'));
      expect(fetched.structuredContent, isNull);

      final listed = await harness.list();
      expect(listed.isError, isTrue);
      expect(listed.textContent, startsWith('[library:corruption]'));
      expect(listed.structuredContent, isNull);
    });
  });
}

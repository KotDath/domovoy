import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart'
    hide createPlatformJsonlStreamStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../support/agent_harness.dart';

void main() {
  group('native JSONL filesystem storage', () {
    late Directory sandbox;
    late Directory applicationSupport;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('domovoy-jsonl-');
      applicationSupport = Directory(
        p.join(sandbox.path, 'application-support'),
      );
    });

    tearDown(() async {
      if (await sandbox.exists()) {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'resolves lazily once and confines opaque keys below app support',
      () async {
        var resolutions = 0;
        final storage = JsonlFilesystemStreamStorage(
          applicationSupportDirectoryResolver: () async {
            resolutions += 1;
            return applicationSupport;
          },
        );
        final root = _storageRoot(applicationSupport);
        expect(resolutions, 0);
        expect(await root.exists(), isFalse);
        expect(await storage.listKeys(), isEmpty);
        expect(resolutions, 1);
        expect(await root.exists(), isTrue);
        await storage.listKeys();
        expect(resolutions, 1);

        final id = AgentSessionId('../../outside/чат?');
        final store = JsonlAgentSessionStore(storage: storage);
        await store.save(
          _record(id, revision: 0, updatedAtMicros: 1, messages: 1),
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        final entities = await root.list().toList();
        expect(entities, hasLength(1));
        expect(entities.single, isA<Directory>());
        final namespace = p.basename(entities.single.path);
        expect(namespace, matches(RegExp(r'^session-v1_[A-Za-z0-9_-]+$')));
        expect(namespace, isNot(contains('..')));
        expect(
          await Directory(p.join(sandbox.path, 'outside')).exists(),
          isFalse,
        );
        expect(
          await JsonlAgentSessionStore(storage: storage).load(id),
          isNotNull,
        );
      },
    );

    test('shared exports stay web-safe and native dependencies are direct', () {
      final sharedFactory = File(
        'lib/infrastructure/agents/jsonl/jsonl_stream_storage_factory.dart',
      ).readAsStringSync();
      final barrel = File(
        'lib/infrastructure/agents/jsonl/jsonl.dart',
      ).readAsStringSync();
      final coreRepository = File(
        'lib/core/agents/repository.dart',
      ).readAsStringSync();
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(sharedFactory, isNot(contains("import 'dart:io'")));
      expect(sharedFactory, contains('if (dart.library.io)'));
      expect(barrel, isNot(contains("export 'jsonl_stream_storage_io.dart'")));
      expect(coreRepository, isNot(contains('dart:io')));
      expect(coreRepository, isNot(contains('path_provider')));
      expect(pubspec, contains('\n  path: ^1.9.1\n'));
      expect(pubspec, contains('\n  path_provider: ^2.1.6\n'));
      expect(
        createPlatformJsonlStreamStorage(),
        isA<JsonlFilesystemStreamStorage>(),
      );
    });

    test(
      'fresh instances restore two complete chats and deterministic catalog',
      () async {
        final firstStorage = _storage(applicationSupport);
        final first = JsonlAgentSessionStore(storage: firstStorage);
        final rich = _richRecord(
          AgentSessionId('rich'),
          revision: 0,
          updatedAtMicros: 10,
        );
        final other = _record(
          AgentSessionId('other'),
          revision: 0,
          updatedAtMicros: 10,
          messages: 2,
        );
        await first.save(rich, expectedRevision: 0, cancellation: _openToken());
        await first.save(
          other,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        final richUpdated = rich.copyWith(revision: 1, updatedAtMicros: 11);
        await first.save(
          richUpdated,
          expectedRevision: 0,
          cancellation: _openToken(),
        );

        final restarted = JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        );
        final catalog = await restarted.list();
        expect(catalog.available.map((summary) => summary.id.value), <String>[
          'rich',
          'other',
        ]);
        expect(await restarted.load(rich.id), richUpdated);
        expect(await restarted.load(other.id), other);
        expect(
          catalog.available.first.messageCount,
          rich.transcript.messages.length,
        );
        expect(catalog.available.first.model, rich.definition.model);

        final namespace = _namespace(applicationSupport, rich.id);
        final beforeConflict = await _generationFiles(namespace);
        await expectLater(
          restarted.save(
            rich.copyWith(revision: 1, updatedAtMicros: 99),
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
          _agentError(AgentErrorKind.conflict),
        );
        expect(await _generationFiles(namespace), beforeConflict);
        expect(await restarted.load(rich.id), richUpdated);
      },
    );

    test(
      'delete restart keeps only tombstone and reserves the identifier',
      () async {
        var failCleanup = false;
        final store = JsonlAgentSessionStore(
          storage: _storage(
            applicationSupport,
            stageHook: (stage, _) {
              if (failCleanup && stage == JsonlFilesystemStage.beforeCleanup) {
                throw StateError('interrupted cleanup');
              }
            },
          ),
        );
        final deleted = _record(
          AgentSessionId('deleted'),
          revision: 0,
          updatedAtMicros: 1,
          messages: 3,
        );
        await store.save(
          deleted,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        failCleanup = true;
        await store.delete(
          deleted.id,
          expectedRevision: 0,
          cancellation: _openToken(),
        );

        final namespace = _namespace(applicationSupport, deleted.id);
        expect((await _generationFiles(namespace)).length, greaterThan(1));
        final active = await _activeGeneration(namespace);
        final tombstone = await File(
          p.join(namespace.path, active),
        ).readAsString();
        expect(tombstone, contains('"operation":"delete"'));
        expect(tombstone, isNot(contains('message-')));

        final restarted = JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        );
        expect(await restarted.load(deleted.id), isNull);
        expect((await restarted.list()).available, isEmpty);
        expect(await _generationFiles(namespace), hasLength(1));
        await expectLater(
          restarted.save(
            deleted,
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
          _agentError(AgentErrorKind.conflict),
        );
        final fresh = _record(
          AgentSessionId('fresh'),
          revision: 0,
          updatedAtMicros: 2,
        );
        await restarted.save(
          fresh,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        expect((await restarted.list()).available.single.id, fresh.id);
      },
    );

    test(
      'pre-flush and pre-pointer failures preserve old complete state',
      () async {
        final initial = _record(
          AgentSessionId('crash'),
          revision: 0,
          updatedAtMicros: 1,
          messages: 1,
        );
        await JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        ).save(initial, expectedRevision: 0, cancellation: _openToken());

        JsonlFilesystemStage? failAt =
            JsonlFilesystemStage.beforeGenerationFlush;
        final failing = JsonlAgentSessionStore(
          storage: _storage(
            applicationSupport,
            stageHook: (stage, _) {
              if (stage == failAt) {
                throw StateError('sk-secret /private/raw-content');
              }
            },
          ),
        );
        final updated = initial.copyWith(revision: 1, updatedAtMicros: 2);
        await _expectSanitizedPersistence(
          failing.save(
            updated,
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
        );
        expect(
          await JsonlAgentSessionStore(
            storage: _storage(applicationSupport),
          ).load(initial.id),
          initial,
        );

        failAt = JsonlFilesystemStage.beforePointerPublication;
        await _expectSanitizedPersistence(
          failing.save(
            updated,
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
        );
        final namespace = _namespace(applicationSupport, initial.id);
        expect((await _generationFiles(namespace)).length, greaterThan(1));

        final recovering = JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        );
        expect(await recovering.load(initial.id), initial);
        await recovering.list();
        expect(await _generationFiles(namespace), hasLength(1));
        expect(await recovering.load(initial.id), initial);
      },
    );

    test(
      'published generation wins even when superseded cleanup fails',
      () async {
        final initial = _record(
          AgentSessionId('cleanup-crash'),
          revision: 0,
          updatedAtMicros: 1,
          messages: 2,
        );
        var failCleanup = false;
        final store = JsonlAgentSessionStore(
          storage: _storage(
            applicationSupport,
            stageHook: (stage, _) {
              if (failCleanup && stage == JsonlFilesystemStage.beforeCleanup) {
                throw StateError('cleanup path /private/secret');
              }
            },
          ),
        );
        await store.save(
          initial,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        failCleanup = true;
        final updated = initial.copyWith(revision: 1, updatedAtMicros: 2);
        await store.save(
          updated,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        final namespace = _namespace(applicationSupport, initial.id);
        expect((await _generationFiles(namespace)).length, greaterThan(1));

        final restarted = JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        );
        expect(await restarted.load(initial.id), updated);
        await restarted.list();
        expect(await _generationFiles(namespace), hasLength(1));
        expect(await restarted.load(initial.id), updated);
      },
    );

    test('cancellation after filesystem admission is commit-wins', () async {
      final pointerReached = Completer<void>();
      final releasePointer = Completer<void>();
      var holdPointer = false;
      final store = JsonlAgentSessionStore(
        storage: _storage(
          applicationSupport,
          stageHook: (stage, _) async {
            if (holdPointer &&
                stage == JsonlFilesystemStage.beforePointerPublication) {
              if (!pointerReached.isCompleted) {
                pointerReached.complete();
              }
              await releasePointer.future;
            }
          },
        ),
      );
      final initial = _record(
        AgentSessionId('cancel-after-admission'),
        revision: 0,
        updatedAtMicros: 1,
      );
      await store.save(
        initial,
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      holdPointer = true;
      final cancellation = CancellationSource();
      final updated = initial.copyWith(revision: 1, updatedAtMicros: 2);
      final saving = store.save(
        updated,
        expectedRevision: 0,
        cancellation: cancellation.token,
      );
      await pointerReached.future;
      cancellation.cancel();
      releasePointer.complete();
      await saving;

      expect(
        await JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        ).load(initial.id),
        updated,
      );
    });

    test(
      'partial generation repairs; internal damage isolates one chat',
      () async {
        final store = JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        );
        final healthy = _record(
          AgentSessionId('healthy'),
          revision: 0,
          updatedAtMicros: 3,
        );
        final recoverable = _record(
          AgentSessionId('recoverable'),
          revision: 0,
          updatedAtMicros: 2,
        );
        await store.save(
          healthy,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        await store.save(
          recoverable,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        final namespace = _namespace(applicationSupport, recoverable.id);
        var active = File(
          p.join(namespace.path, await _activeGeneration(namespace)),
        );
        await active.writeAsString(
          '{"partial":"sk-secret',
          mode: FileMode.append,
          flush: true,
        );
        final restarted = JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        );
        expect(await restarted.load(recoverable.id), recoverable);
        final repaired = recoverable.copyWith(revision: 1, updatedAtMicros: 4);
        await restarted.save(
          repaired,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        active = File(
          p.join(namespace.path, await _activeGeneration(namespace)),
        );
        expect(await active.readAsString(), isNot(contains('sk-secret')));

        await active.writeAsString(
          '{"raw":"sk-secret /private/path"}\n',
          mode: FileMode.append,
          flush: true,
        );
        final quarantined = JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        );
        final snapshot = await quarantined.list();
        expect(snapshot.available.single.id, healthy.id);
        expect(snapshot.issues.single.id, recoverable.id);
        expect(
          snapshot.issues.single.reason.message,
          isNot(contains('sk-secret')),
        );
        expect(
          snapshot.issues.single.reason.message,
          isNot(contains('/private')),
        );
        await _expectSanitizedPersistence(quarantined.load(recoverable.id));
      },
    );

    test(
      'invalid active pointer never falls back to an older generation',
      () async {
        var failCleanup = false;
        final store = JsonlAgentSessionStore(
          storage: _storage(
            applicationSupport,
            stageHook: (stage, _) {
              if (failCleanup && stage == JsonlFilesystemStage.beforeCleanup) {
                throw StateError('cleanup failed');
              }
            },
          ),
        );
        final initial = _record(
          AgentSessionId('bad-pointer'),
          revision: 0,
          updatedAtMicros: 1,
        );
        await store.save(
          initial,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        failCleanup = true;
        await store.save(
          initial.copyWith(revision: 1, updatedAtMicros: 2),
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        final namespace = _namespace(applicationSupport, initial.id);
        expect((await _generationFiles(namespace)).length, greaterThan(1));
        final activeFile = File(
          p.join(
            namespace.path,
            JsonlFilesystemStreamStorage.activeManifestName,
          ),
        );
        final manifest = Map<String, Object?>.from(
          jsonDecode((await activeFile.readAsString()).trim()) as Map,
        );
        manifest['generation'] =
            'generation-00000000000000000000000000000000.jsonl';
        await activeFile.writeAsString(
          '${jsonEncode(manifest)}\n',
          flush: true,
        );

        final restarted = JsonlAgentSessionStore(
          storage: _storage(applicationSupport),
        );
        await _expectSanitizedPersistence(restarted.load(initial.id));
        final catalog = await restarted.list();
        expect(catalog.available, isEmpty);
        expect(catalog.issues.single.id, initial.id);
      },
    );

    test(
      'initialization and enumeration failures are typed and sanitized',
      () async {
        final enumerationStorage = _storage(applicationSupport);
        expect(await enumerationStorage.listKeys(), isEmpty);
        final root = _storageRoot(applicationSupport);
        await root.delete(recursive: true);
        await File(root.path).writeAsString('/private/sk-secret');
        await _expectSanitizedPersistence(
          JsonlAgentSessionStore(storage: enumerationStorage).list(),
        );

        final blockedParent = File(p.join(sandbox.path, 'not-a-directory'));
        await blockedParent.writeAsString('/private/sk-secret');
        final unavailable = JsonlAgentSessionStore(
          storage: JsonlFilesystemStreamStorage(
            applicationSupportDirectoryResolver: () async =>
                Directory(blockedParent.path),
          ),
        );
        await _expectSanitizedPersistence(unavailable.list());
        await _expectSanitizedPersistence(
          unavailable.save(
            _record(
              AgentSessionId('no-fallback'),
              revision: 0,
              updatedAtMicros: 1,
            ),
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
        );
      },
    );
  });
}

JsonlFilesystemStreamStorage _storage(
  Directory applicationSupport, {
  JsonlFilesystemStageHook? stageHook,
}) {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: () async => applicationSupport,
    stageHook: stageHook,
  );
}

Directory _storageRoot(Directory applicationSupport) {
  return Directory(
    p.join(
      applicationSupport.path,
      JsonlFilesystemStreamStorage.applicationDirectoryName,
      JsonlFilesystemStreamStorage.storageDirectoryName,
    ),
  );
}

Directory _namespace(Directory applicationSupport, AgentSessionId id) {
  return Directory(
    p.join(
      _storageRoot(applicationSupport).path,
      const JsonlSessionKeyCodec().encode(id),
    ),
  );
}

Future<Set<String>> _generationFiles(Directory namespace) async {
  return (await namespace.list().toList())
      .map((entity) => p.basename(entity.path))
      .where(
        (name) => name.startsWith('generation-') && name.endsWith('.jsonl'),
      )
      .toSet();
}

Future<String> _activeGeneration(Directory namespace) async {
  final manifest = jsonDecode(
    await File(
      p.join(namespace.path, JsonlFilesystemStreamStorage.activeManifestName),
    ).readAsString(),
  );
  return (manifest as Map)['generation']! as String;
}

Future<void> _expectSanitizedPersistence(Future<Object?> future) async {
  try {
    await future;
    fail('Expected a persistence failure.');
  } on AgentException catch (error) {
    expect(error.error.kind, AgentErrorKind.persistence);
    expect(error.error.message, isNot(contains('sk-secret')));
    expect(error.error.message, isNot(contains('/private')));
    expect(error.error.message, isNot(contains('raw-content')));
  }
}

Matcher _agentError(AgentErrorKind kind) => throwsA(
  isA<AgentException>().having((error) => error.error.kind, 'kind', kind),
);

CancellationToken _openToken() => CancellationSource().token;

AgentSessionRecord _record(
  AgentSessionId id, {
  required int revision,
  required int updatedAtMicros,
  int messages = 0,
}) {
  return AgentSessionRecord(
    id: id,
    revision: revision,
    definition: testDefinition(),
    transcript: AgentTranscript(
      messages: List<LlmMessage>.generate(
        messages,
        (index) => LlmMessage(
          role: index.isEven ? LlmMessageRole.user : LlmMessageRole.assistant,
          parts: <LlmContentPart>[LlmTextPart('message-$index')],
        ),
      ),
    ),
    usage: LlmUsage(totalTokens: messages),
    modelTurns: messages ~/ 2,
    toolAttempts: 0,
    createdAtMicros: 1,
    updatedAtMicros: updatedAtMicros,
  );
}

AgentSessionRecord _richRecord(
  AgentSessionId id, {
  required int revision,
  required int updatedAtMicros,
}) {
  final messages = <LlmMessage>[
    LlmMessage(
      role: LlmMessageRole.assistant,
      parts: <LlmContentPart>[LlmTextPart('summary')],
    ),
    LlmMessage(
      role: LlmMessageRole.user,
      parts: <LlmContentPart>[LlmTextPart('question')],
    ),
    LlmMessage(
      role: LlmMessageRole.assistant,
      parts: <LlmContentPart>[LlmTextPart('answer')],
    ),
  ];
  return AgentSessionRecord(
    id: id,
    revision: revision,
    definition: testDefinition(model: BuiltInLlmCatalog.gpt4oMiniModel.ref),
    transcript: AgentTranscript(messages: messages),
    usage: LlmUsage(inputTokens: 4, outputTokens: 2, totalTokens: 6),
    modelTurns: 1,
    toolAttempts: 0,
    createdAtMicros: 1,
    updatedAtMicros: updatedAtMicros,
    continuationEntries: <LlmContinuationEntry>[
      LlmContinuationEntry(
        assistantMessageIndex: 2,
        state: LlmProviderTurnState(
          origin: BuiltInLlmCatalog.gpt4oMiniModel.ref,
          wireFamily: LlmWireFamily.openaiResponses,
          format: openaiResponsesOutputItemsV1,
          payload: <Map<String, Object?>>[
            <String, Object?>{
              'type': 'message',
              'id': 'message-2',
              'role': 'assistant',
              'content': <Map<String, Object?>>[
                <String, Object?>{
                  'type': 'output_text',
                  'text': 'answer',
                  'annotations': <Object?>[],
                },
              ],
            },
          ],
        ),
      ),
    ],
    compactionState: AgentCompactionState(
      generation: 1,
      generatedPrefixStart: 0,
      generatedPrefixCount: 1,
      reason: AgentCompactionReason.manual,
      triggerId: null,
      triggerVersion: null,
      strategyId: 'summary',
      strategyVersion: 1,
      estimatorId: 'utf8-framing',
      estimatorVersion: 1,
      removedMessageCount: 2,
      beforeEstimate: 20,
      afterEstimate: 10,
      decisionMetadata: const <String, Object?>{'mode': 'safe'},
      updatedAtMicros: updatedAtMicros,
    ),
  );
}

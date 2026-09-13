import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';
import '../../../support/scripted_llm_provider.dart';

void main() {
  group('JSONL envelope and replay', () {
    test('canonical v1 upsert and tombstone fixtures are newline framed', () {
      const codec = JsonlSessionEnvelopeCodec();
      final id = AgentSessionId('chat / один');
      final upsert = codec.encodeLine(
        JsonlSessionEnvelope(
          sessionId: id,
          sequence: 0,
          operation: JsonlSessionOperation.upsert,
          expectedRevision: 0,
          recordRevision: 0,
          record: const <String, Object?>{'marker': 'value'},
        ),
      );
      expect(
        upsert,
        '{"type":"domovoy.agent_session_operation","version":1,'
        '"sessionId":"chat / один","sequence":0,"operation":"upsert",'
        '"expectedRevision":0,"recordRevision":0,'
        '"record":{"marker":"value"}}\n',
      );
      expect(
        codec.encodeLine(
          JsonlSessionEnvelope(
            sessionId: id,
            sequence: 1,
            operation: JsonlSessionOperation.upsert,
            expectedRevision: 0,
            recordRevision: 1,
            record: const <String, Object?>{'marker': 'next'},
          ),
        ),
        '{"type":"domovoy.agent_session_operation","version":1,'
        '"sessionId":"chat / один","sequence":1,"operation":"upsert",'
        '"expectedRevision":0,"recordRevision":1,'
        '"record":{"marker":"next"}}\n',
      );
      expect(
        codec.encodeLine(
          JsonlSessionEnvelope(
            sessionId: id,
            sequence: 2,
            operation: JsonlSessionOperation.delete,
            expectedRevision: 1,
            recordRevision: 1,
          ),
        ),
        '{"type":"domovoy.agent_session_operation","version":1,'
        '"sessionId":"chat / один","sequence":2,"operation":"delete",'
        '"expectedRevision":1,"recordRevision":1}\n',
      );
    });

    test('opaque keys are URL-safe, canonical, and reversible', () {
      const codec = JsonlSessionKeyCodec();
      final id = AgentSessionId('../chat? один');
      final key = codec.encode(id);
      expect(key, matches(RegExp(r'^session-v1_[A-Za-z0-9_-]+$')));
      expect(key, isNot(contains(id.value)));
      expect(codec.decode(key), id);
      expect(() => codec.decode('$key='), throwsFormatException);
    });

    test(
      'full codec snapshot preserves continuation and compaction state',
      () async {
        final storage = _FakeJsonlStorage();
        final store = JsonlAgentSessionStore(storage: storage);
        final record = _richRecord('rich', updatedAtMicros: 5);
        await store.save(
          record,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        final restored = await JsonlAgentSessionStore(
          storage: storage,
        ).load(record.id);
        expect(restored, record);
        final raw = jsonDecode(storage.activeText(_key(record.id))!);
        _expectJsonOnly(raw);
        expect(
          storage.activeText(_key(record.id)),
          isNot(contains('sk-secret')),
        );
        expect(
          storage.activeText(_key(record.id)),
          isNot(contains('Cancellation')),
        );
      },
    );
  });

  group('JSONL repository and catalog', () {
    test(
      'fresh store lists and restores exact records in stable order',
      () async {
        final storage = _FakeJsonlStorage();
        final firstStore = JsonlAgentSessionStore(storage: storage);
        AgentSessionRepository repository = firstStore;
        AgentSessionCatalog catalog = firstStore;
        final older = _record('z', updatedAtMicros: 8, messages: 1);
        final tieB = _record('b', updatedAtMicros: 9, messages: 2);
        final tieA = _richRecord('a', updatedAtMicros: 9);
        for (final record in <AgentSessionRecord>[older, tieB, tieA]) {
          await repository.save(
            record,
            expectedRevision: 0,
            cancellation: _openToken(),
          );
        }

        final restarted = JsonlAgentSessionStore(storage: storage);
        repository = restarted;
        catalog = restarted;
        final snapshot = await catalog.list();
        expect(snapshot.available.map((summary) => summary.id.value), <String>[
          'a',
          'b',
          'z',
        ]);
        expect(snapshot.available[1].messageCount, 2);
        for (final record in <AgentSessionRecord>[older, tieB, tieA]) {
          expect(await repository.load(record.id), record);
          final summary = snapshot.available.singleWhere(
            (candidate) => candidate.id == record.id,
          );
          expect(summary.revision, record.revision);
          expect(summary.createdAtMicros, record.createdAtMicros);
          expect(summary.updatedAtMicros, record.updatedAtMicros);
          expect(summary.model, record.definition.model);
          expect(summary.messageCount, record.transcript.messages.length);
        }
      },
    );

    test('same-revision saves and save-delete races have one winner', () async {
      final storage = _FakeJsonlStorage();
      final store = JsonlAgentSessionStore(storage: storage);
      final initial = _record('race', updatedAtMicros: 1);
      await store.save(
        initial,
        expectedRevision: 0,
        cancellation: _openToken(),
      );

      storage.holdNextPublish();
      final winner = store.save(
        initial.copyWith(revision: 1, updatedAtMicros: 2),
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      await storage.nextPublishStarted;
      final loser = store.save(
        initial.copyWith(revision: 1, updatedAtMicros: 3),
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      storage.releasePublish();
      await winner;
      await expectLater(loser, _agentError(AgentErrorKind.conflict));
      expect(storage.publishInvocations, 2);
      expect((await store.load(initial.id))!.updatedAtMicros, 2);

      storage.holdNextPublish();
      final saveWinner = store.save(
        initial.copyWith(revision: 2, updatedAtMicros: 4),
        expectedRevision: 1,
        cancellation: _openToken(),
      );
      await storage.nextPublishStarted;
      final deleteLoser = store.delete(
        initial.id,
        expectedRevision: 1,
        cancellation: _openToken(),
      );
      storage.releasePublish();
      await saveWinner;
      await expectLater(deleteLoser, _agentError(AgentErrorKind.conflict));
      expect((await store.load(initial.id))!.revision, 2);

      storage.holdNextPublish();
      final deleteWinner = store.delete(
        initial.id,
        expectedRevision: 2,
        cancellation: _openToken(),
      );
      await storage.nextPublishStarted;
      final saveLoser = store.save(
        initial.copyWith(revision: 3, updatedAtMicros: 5),
        expectedRevision: 2,
        cancellation: _openToken(),
      );
      storage.releasePublish();
      await deleteWinner;
      await expectLater(saveLoser, _agentError(AgentErrorKind.conflict));
      expect(await store.load(initial.id), isNull);
    });

    test(
      'overlapping listing observes complete before or after snapshots',
      () async {
        final storage = _FakeJsonlStorage();
        final store = JsonlAgentSessionStore(storage: storage);
        final initial = _record('listed', updatedAtMicros: 1);
        await store.save(
          initial,
          expectedRevision: 0,
          cancellation: _openToken(),
        );

        storage.holdNextRead();
        final before = store.list();
        await storage.nextReadStarted;
        final queuedSave = store.save(
          initial.copyWith(revision: 1, updatedAtMicros: 2),
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        storage.releaseRead();
        expect((await before).available.single.revision, 0);
        await queuedSave;

        storage.holdNextPublish();
        final admittedSave = store.save(
          initial.copyWith(revision: 2, updatedAtMicros: 3),
          expectedRevision: 1,
          cancellation: _openToken(),
        );
        await storage.nextPublishStarted;
        final after = store.list();
        storage.releasePublish();
        await admittedSave;
        expect((await after).available.single.revision, 2);
      },
    );

    test('cancellation before admission has no late effect', () async {
      final storage = _FakeJsonlStorage();
      final store = JsonlAgentSessionStore(storage: storage);
      final initial = _record('cancel-wait', updatedAtMicros: 1);
      await store.save(
        initial,
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      storage.holdNextPublish();
      final admitted = store.save(
        initial.copyWith(revision: 1, updatedAtMicros: 2),
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      await storage.nextPublishStarted;
      final cancelled = CancellationSource();
      final waiting = store.delete(
        initial.id,
        expectedRevision: 0,
        cancellation: cancelled.token,
      );
      cancelled.cancel();
      storage.releasePublish();
      await admitted;
      await expectLater(waiting, _agentError(AgentErrorKind.cancelled));
      expect(storage.publishInvocations, 2);
      expect((await store.load(initial.id))!.revision, 1);
    });

    test('cancellation after admission is commit-wins exactly once', () async {
      final storage = _FakeJsonlStorage();
      final store = JsonlAgentSessionStore(storage: storage);
      final initial = _record('commit-wins', updatedAtMicros: 1);
      await store.save(
        initial,
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      storage.holdNextPublish();
      final cancellation = CancellationSource();
      final saving = store.save(
        initial.copyWith(revision: 1, updatedAtMicros: 2),
        expectedRevision: 0,
        cancellation: cancellation.token,
      );
      await storage.nextPublishStarted;
      cancellation.cancel();
      storage.releasePublish();
      await saving;
      expect(storage.publishInvocations, 2);
      expect((await store.load(initial.id))!.revision, 1);
      expect(storage.activeText(_key(initial.id))!.split('\n'), hasLength(3));
    });

    test(
      'fresh runtime after simulated process loss invents no active attempt',
      () async {
        final sourceStorage = _FakeJsonlStorage();
        final sourceStore = JsonlAgentSessionStore(storage: sourceStorage);
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: <LlmEvent>[LlmUsageUpdate(LlmUsage(totalTokens: 9))],
          gate: gate,
        );
        final sourceRuntime = testRuntime(
          provider: provider,
          repository: sourceStore,
        );
        final sourceSession = await sourceRuntime
            .agent(testDefinition())
            .createSession(persistence: SessionPersistence.repository);
        final run = sourceSession.run('active');
        final eventsFuture = run.events.toList();
        while (provider.requests.isEmpty ||
            sourceSession
                    .snapshot
                    .tokenAccounting
                    .currentRequest
                    ?.usage
                    .totalTokens !=
                9) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(sourceSession.snapshot.tokenAccounting.ledger, isEmpty);

        final crashStorage = _FakeJsonlStorage();
        final key = _key(sourceSession.id);
        crashStorage.injectActive(key, sourceStorage.activeText(key)!);
        final restartedStore = JsonlAgentSessionStore(
          storage: crashStorage,
          recordCodec: const AgentSessionCodec(),
        );
        final restartedRuntime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: const <List<LlmEvent>>[],
          ),
          repository: restartedStore,
        );
        final restored = await restartedRuntime
            .agent(testDefinition())
            .restoreSession(sourceSession.id);
        expect(restored.snapshot.tokenAccounting.ledger, isEmpty);
        expect(restored.snapshot.tokenAccounting.currentRequest, isNull);
        expect(restored.snapshot.transcript.messages, hasLength(1));
        expect(
          restored.snapshot.transcript.messages.single.role,
          LlmMessageRole.user,
        );
        await restored.close();
        await restartedRuntime.close();

        await run.cancel();
        await eventsFuture;
        await sourceSession.close();
        await sourceRuntime.close();
      },
    );
  });

  group('JSONL recovery and isolation', () {
    test('partial tail falls back and is removed by the next commit', () async {
      final storage = _FakeJsonlStorage();
      final firstStore = JsonlAgentSessionStore(storage: storage);
      final initial = _record('partial', updatedAtMicros: 1);
      await firstStore.save(
        initial,
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      final key = _key(initial.id);
      storage.replaceActiveText('${storage.activeText(key)}{"secret-tail":');

      final restarted = JsonlAgentSessionStore(storage: storage);
      expect(await restarted.load(initial.id), initial);
      final successor = initial.copyWith(revision: 1, updatedAtMicros: 2);
      await restarted.save(
        successor,
        expectedRevision: 0,
        cancellation: _openToken(),
      );
      final repaired = storage.activeText(key)!;
      expect(repaired, isNot(contains('secret-tail')));
      expect(repaired.endsWith('\n'), isTrue);
      expect(
        await JsonlAgentSessionStore(storage: storage).load(initial.id),
        successor,
      );
    });

    test(
      'corrupt stream is quarantined without hiding healthy sessions',
      () async {
        final storage = _FakeJsonlStorage();
        final store = JsonlAgentSessionStore(storage: storage);
        final healthy = _record('healthy', updatedAtMicros: 3);
        final bad = _record('bad', updatedAtMicros: 4);
        await store.save(
          healthy,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        await store.save(bad, expectedRevision: 0, cancellation: _openToken());
        storage.replaceActiveText(
          '${storage.activeText(_key(bad.id))}'
          '{"raw":"sk-secret /private/path"}\n'
          '${storage.activeText(_key(bad.id))}',
          key: _key(bad.id),
        );
        storage.injectActive('not-a-session-key', '{"raw":"secret-key"}\n');

        final snapshot = await JsonlAgentSessionStore(storage: storage).list();
        expect(snapshot.available.single.id, healthy.id);
        expect(snapshot.issues, hasLength(2));
        expect(
          snapshot.issues.map((issue) => issue.id),
          containsAll(<AgentSessionId?>[bad.id, null]),
        );
        for (final issue in snapshot.issues) {
          expect(issue.reason.kind, AgentErrorKind.persistence);
          expect(issue.reason.message, isNot(contains('sk-secret')));
          expect(issue.reason.message, isNot(contains('/private/path')));
          expect(issue.reason.message, isNot(contains('secret-key')));
        }
        await expectLater(
          store.load(bad.id),
          _agentError(AgentErrorKind.persistence),
        );
      },
    );

    test(
      'malformed accounting ledger is quarantined on fresh replay',
      () async {
        final storage = _FakeJsonlStorage();
        final store = JsonlAgentSessionStore(
          storage: storage,
          recordCodec: const AgentSessionCodec(),
        );
        final record = _accountingRecord('bad-accounting');
        await store.save(
          record,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        storage.mutateActiveJson(_key(record.id), (envelope) {
          final encodedRecord = Map<String, Object?>.from(
            envelope['record']! as Map,
          );
          final accounting = Map<String, Object?>.from(
            encodedRecord['tokenAccounting']! as Map,
          );
          final entries = List<Object?>.from(accounting['entries']! as List);
          entries.add(entries.single);
          accounting['entries'] = entries;
          encodedRecord['tokenAccounting'] = accounting;
          envelope['record'] = encodedRecord;
        });

        final restarted = JsonlAgentSessionStore(
          storage: storage,
          recordCodec: const AgentSessionCodec(),
        );
        await expectLater(
          restarted.load(record.id),
          _agentError(AgentErrorKind.persistence),
        );
        final catalog = await restarted.list();
        expect(catalog.available, isEmpty);
        expect(catalog.issues, hasLength(1));
        expect(catalog.issues.single.id, record.id);
        expect(
          catalog.issues.single.reason.message,
          isNot(contains('attempt')),
        );
      },
    );

    test(
      'gaps, mismatches, unknown versions, and transitions quarantine',
      () async {
        final mutations = <String, void Function(Map<String, Object?>)>{
          'sequence gap': (map) => map['sequence'] = 2,
          'envelope identity': (map) => map['sessionId'] = 'other',
          'envelope version': (map) => map['version'] = 99,
          'unknown operation': (map) => map['operation'] = 'merge',
          'record revision': (map) => map['recordRevision'] = 1,
          'nested identity': (map) {
            final record = Map<String, Object?>.from(map['record']! as Map);
            record['id'] = AgentSessionId('other').toJson();
            map['record'] = record;
          },
          'nested version': (map) {
            final record = Map<String, Object?>.from(map['record']! as Map);
            record['version'] = 99;
            map['record'] = record;
          },
          'unexpected field': (map) => map['raw'] = 'secret',
        };
        for (final entry in mutations.entries) {
          final storage = _FakeJsonlStorage();
          final store = JsonlAgentSessionStore(storage: storage);
          final record = _record('bad-${entry.key}', updatedAtMicros: 1);
          await store.save(
            record,
            expectedRevision: 0,
            cancellation: _openToken(),
          );
          storage.mutateActiveJson(_key(record.id), entry.value);
          await expectLater(
            JsonlAgentSessionStore(storage: storage).load(record.id),
            _agentError(AgentErrorKind.persistence),
            reason: entry.key,
          );
        }
      },
    );

    test(
      'entry and stream limits fail without publishing excess bytes',
      () async {
        final entryStorage = _FakeJsonlStorage();
        final id = AgentSessionId('entry-limit');
        entryStorage.injectActive(_key(id), '${'x' * 65}\n');
        final entryStore = JsonlAgentSessionStore(
          storage: entryStorage,
          limits: JsonlStorageLimits(maxEntryBytes: 64, maxStreamBytes: 128),
        );
        await expectLater(
          entryStore.load(id),
          _agentError(AgentErrorKind.persistence),
        );

        final emptyStorage = _FakeJsonlStorage();
        final emptyId = AgentSessionId('empty');
        emptyStorage.injectActive(_key(emptyId), '');
        await expectLater(
          JsonlAgentSessionStore(storage: emptyStorage).load(emptyId),
          _agentError(AgentErrorKind.persistence),
        );

        final streamStorage = _FakeJsonlStorage();
        final streamId = AgentSessionId('stream-limit');
        streamStorage.injectActive(_key(streamId), 'x' * 129);
        final streamStore = JsonlAgentSessionStore(
          storage: streamStorage,
          limits: JsonlStorageLimits(maxEntryBytes: 64, maxStreamBytes: 128),
        );
        await expectLater(
          streamStore.load(streamId),
          _agentError(AgentErrorKind.persistence),
        );

        final tinyStorage = _FakeJsonlStorage();
        final tinyStore = JsonlAgentSessionStore(
          storage: tinyStorage,
          limits: JsonlStorageLimits(maxEntryBytes: 32, maxStreamBytes: 64),
        );
        await expectLater(
          tinyStore.save(
            _record('too-large', updatedAtMicros: 1),
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
          _agentError(AgentErrorKind.persistence),
        );
        expect(tinyStorage.publishInvocations, 0);
      },
    );

    test('enumeration failure fails the whole catalog', () async {
      final storage = _FakeJsonlStorage()..failEnumeration = true;
      await expectLater(
        JsonlAgentSessionStore(storage: storage).list(),
        _agentError(AgentErrorKind.persistence),
      );
    });

    test(
      'old/new pointers are complete, orphans inactive, invalid pointer fails',
      () async {
        final storage = _FakeJsonlStorage()..failCleanup = true;
        final store = JsonlAgentSessionStore(storage: storage);
        final initial = _record('atomic', updatedAtMicros: 1);
        await store.save(
          initial,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        final key = _key(initial.id);
        final oldGeneration = storage.activeGeneration(key)!;
        final updated = initial.copyWith(revision: 1, updatedAtMicros: 2);
        await store.save(
          updated,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        final newGeneration = storage.activeGeneration(key)!;

        storage.activate(key, oldGeneration);
        expect(
          await JsonlAgentSessionStore(storage: storage).load(initial.id),
          initial,
        );
        storage.activate(key, newGeneration);
        expect(
          await JsonlAgentSessionStore(storage: storage).load(initial.id),
          updated,
        );

        final orphan = storage.stage(key, utf8.encode('{"orphan":true}\n'));
        storage.failCleanup = false;
        final snapshot = await JsonlAgentSessionStore(storage: storage).list();
        expect(snapshot.available.single.revision, 1);
        expect(storage.generations(key), isNot(contains(orphan)));

        storage.activate(key, 9999);
        await expectLater(
          JsonlAgentSessionStore(storage: storage).load(initial.id),
          _agentError(AgentErrorKind.persistence),
        );
        final quarantined = await JsonlAgentSessionStore(
          storage: storage,
        ).list();
        expect(quarantined.available, isEmpty);
        expect(quarantined.issues, hasLength(1));
      },
    );
  });

  group('JSONL tombstones', () {
    test(
      'delete survives restart, reserves id, and fresh id starts at zero',
      () async {
        final storage = _FakeJsonlStorage();
        final store = JsonlAgentSessionStore(storage: storage);
        final deleted = _record('deleted', updatedAtMicros: 1, messages: 2);
        await store.save(
          deleted,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        await expectLater(
          store.delete(
            deleted.id,
            expectedRevision: 1,
            cancellation: _openToken(),
          ),
          _agentError(AgentErrorKind.conflict),
        );
        final cancelled = CancellationSource()..cancel();
        await expectLater(
          store.delete(
            deleted.id,
            expectedRevision: 0,
            cancellation: cancelled.token,
          ),
          _agentError(AgentErrorKind.cancelled),
        );
        await store.delete(
          deleted.id,
          expectedRevision: 0,
          cancellation: _openToken(),
        );

        final tombstone = storage.activeText(_key(deleted.id))!;
        expect(storage.generations(_key(deleted.id)), hasLength(1));
        expect(tombstone.split('\n'), hasLength(2));
        expect(tombstone, contains('"operation":"delete"'));
        expect(tombstone, isNot(contains('message-0')));
        final restarted = JsonlAgentSessionStore(storage: storage);
        expect(await restarted.load(deleted.id), isNull);
        expect((await restarted.list()).available, isEmpty);
        await expectLater(
          restarted.save(
            deleted,
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
          _agentError(AgentErrorKind.conflict),
        );
        final fresh = _record('fresh-id', updatedAtMicros: 2);
        await restarted.save(
          fresh,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        expect((await restarted.list()).available.single.revision, 0);
      },
    );

    test(
      'commit-wins delete and interrupted cleanup cannot restore messages',
      () async {
        final storage = _FakeJsonlStorage()..failCleanup = true;
        final store = JsonlAgentSessionStore(storage: storage);
        final record = _record(
          'delete-commit',
          updatedAtMicros: 1,
          messages: 2,
        );
        await store.save(
          record,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        storage.holdNextPublish();
        final cancellation = CancellationSource();
        final deleting = store.delete(
          record.id,
          expectedRevision: 0,
          cancellation: cancellation.token,
        );
        await storage.nextPublishStarted;
        cancellation.cancel();
        storage.releasePublish();
        await deleting;
        expect(storage.generations(_key(record.id)).length, greaterThan(1));
        final restarted = JsonlAgentSessionStore(storage: storage);
        expect(await restarted.load(record.id), isNull);
        expect((await restarted.list()).available, isEmpty);
      },
    );
  });
}

CancellationToken _openToken() => CancellationSource().token;

Matcher _agentError(AgentErrorKind kind) => throwsA(
  isA<AgentException>().having((error) => error.error.kind, 'kind', kind),
);

String _key(AgentSessionId id) => const JsonlSessionKeyCodec().encode(id);

AgentSessionRecord _record(
  String id, {
  required int updatedAtMicros,
  int messages = 0,
}) {
  return AgentSessionRecord(
    id: AgentSessionId(id),
    revision: 0,
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

AgentSessionRecord _richRecord(String id, {required int updatedAtMicros}) {
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
    id: AgentSessionId(id),
    revision: 0,
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

AgentSessionRecord _accountingRecord(String id) {
  final accounting = AgentTokenAccountingState(
    generation: 1,
    contextRevision: 0,
    messageIds: const <AgentTranscriptMessageId?>[],
    legacyBaseline: LlmUsage(),
    entries: <AgentModelUsageEntry>[
      AgentModelUsageEntry.compaction(
        sequence: 1,
        attemptId: ProviderAttemptId('accounting-attempt'),
        model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
        outcome: AgentModelInvocationOutcome.completed,
        usage: LlmUsage(totalTokens: 3),
        contextRevision: 0,
        compactionOperationId: AgentCompactionOperationId(
          'accounting-operation',
        ),
        invocationOrdinal: 0,
      ),
    ],
  );
  return AgentSessionRecord(
    id: AgentSessionId(id),
    revision: 0,
    definition: testDefinition(),
    transcript: AgentTranscript(),
    usage: accounting.compatibilityUsage,
    modelTurns: 0,
    toolAttempts: 0,
    createdAtMicros: 1,
    updatedAtMicros: 1,
    tokenAccounting: accounting,
  );
}

void _expectJsonOnly(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    return;
  }
  if (value is List) {
    for (final nested in value) {
      _expectJsonOnly(nested);
    }
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      expect(entry.key, isA<String>());
      _expectJsonOnly(entry.value);
    }
    return;
  }
  fail('Non-JSON runtime value ${value.runtimeType} was serialized.');
}

final class _FakeJsonlStorage implements JsonlStreamStorage {
  final Map<String, _FakeNamespace> _namespaces = <String, _FakeNamespace>{};
  bool failEnumeration = false;
  bool failCleanup = false;
  int publishInvocations = 0;
  Completer<void>? _publishGate;
  Completer<void> _publishStarted = Completer<void>();
  Completer<void>? _readGate;
  Completer<void> _readStarted = Completer<void>();

  Future<void> get nextPublishStarted => _publishStarted.future;
  Future<void> get nextReadStarted => _readStarted.future;

  void holdNextPublish() {
    _publishGate = Completer<void>();
    _publishStarted = Completer<void>();
  }

  void releasePublish() {
    _publishGate?.complete();
    _publishGate = null;
  }

  void holdNextRead() {
    _readGate = Completer<void>();
    _readStarted = Completer<void>();
  }

  void releaseRead() {
    _readGate?.complete();
    _readGate = null;
  }

  @override
  Future<void> cleanup(String key) async {
    if (failCleanup) {
      throw StateError('cleanup failed');
    }
    final namespace = _namespaces[key];
    if (namespace == null) {
      return;
    }
    final active = namespace.active;
    namespace.generations.removeWhere((generation, _) => generation != active);
    if (active == null && namespace.generations.isEmpty) {
      _namespaces.remove(key);
    }
  }

  @override
  Future<List<String>> listKeys() async {
    if (failEnumeration) {
      throw StateError('enumeration secret');
    }
    return _namespaces.keys.toList();
  }

  @override
  Future<void> publish(String key, List<int> contents) async {
    publishInvocations += 1;
    final namespace = _namespaces.putIfAbsent(key, _FakeNamespace.new);
    final generation = namespace.stage(contents);
    if (!_publishStarted.isCompleted) {
      _publishStarted.complete();
    }
    final gate = _publishGate;
    if (gate != null) {
      await gate.future;
    }
    namespace.active = generation;
  }

  @override
  Future<Stream<List<int>>?> read(String key) async {
    final namespace = _namespaces[key];
    if (namespace == null || namespace.active == null) {
      return null;
    }
    final bytes = namespace.generations[namespace.active];
    if (bytes == null) {
      throw StateError('active generation is unavailable');
    }
    final captured = List<int>.from(bytes);
    if (!_readStarted.isCompleted) {
      _readStarted.complete();
    }
    final gate = _readGate;
    if (gate != null) {
      await gate.future;
    }
    final midpoint = captured.length ~/ 2;
    return Stream<List<int>>.fromIterable(<List<int>>[
      captured.sublist(0, midpoint),
      captured.sublist(midpoint),
    ]);
  }

  String? activeText(String key) {
    final namespace = _namespaces[key];
    final bytes = namespace?.generations[namespace.active];
    return bytes == null ? null : utf8.decode(bytes);
  }

  void replaceActiveText(String value, {String? key}) {
    final selectedKey = key ?? _namespaces.keys.single;
    final namespace = _namespaces[selectedKey]!;
    namespace.generations[namespace.active!] = utf8.encode(value);
  }

  void injectActive(String key, String value) {
    final namespace = _namespaces.putIfAbsent(key, _FakeNamespace.new);
    namespace.active = namespace.stage(utf8.encode(value));
  }

  void mutateActiveJson(
    String key,
    void Function(Map<String, Object?>) mutate,
  ) {
    final map = Map<String, Object?>.from(
      jsonDecode(activeText(key)!.trim()) as Map,
    );
    mutate(map);
    replaceActiveText('${jsonEncode(map)}\n', key: key);
  }

  int stage(String key, List<int> contents) {
    return _namespaces.putIfAbsent(key, _FakeNamespace.new).stage(contents);
  }

  void activate(String key, int generation) {
    _namespaces[key]!.active = generation;
  }

  int? activeGeneration(String key) => _namespaces[key]?.active;

  Set<int> generations(String key) =>
      _namespaces[key]?.generations.keys.toSet() ?? <int>{};
}

final class _FakeNamespace {
  final Map<int, List<int>> generations = <int, List<int>>{};
  int? active;
  int _next = 0;

  int stage(List<int> contents) {
    final generation = _next++;
    generations[generation] = List<int>.from(contents);
    return generation;
  }
}

@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_web.dart'
    hide createPlatformJsonlStreamStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_web/shared_preferences_web.dart';

import '../../../support/agent_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => SharedPreferencesAsyncWeb.registerWith(null));

  var namespaceSequence = 0;
  late String namespace;

  setUp(() async {
    namespaceSequence += 1;
    namespace =
        'ru.kotdath.domovoy.test.${DateTime.now().microsecondsSinceEpoch}.$namespaceSequence';
    await _clearNamespace(namespace);
  });

  tearDown(() => _clearNamespace(namespace));

  group('browser JSONL storage', () {
    test(
      'platform factory is durable browser storage without memory fallback',
      () {
        expect(
          createPlatformJsonlStreamStorage(),
          isA<JsonlBrowserStreamStorage>(),
        );
      },
    );

    test(
      'scopes immutable generations, preserves exact bytes, and cleans orphans',
      () async {
        final preferences = _MemoryBrowserPreferences()
          ..values['unrelated.preference'] = 'leave-me';
        final storage = JsonlBrowserStreamStorage(
          preferences: preferences,
          namespace: namespace,
        );
        const key = 'session-v1_b3BhcXVl';
        final first = utf8.encode('{"message":"привет"}\n');
        final second = utf8.encode(
          '{"message":"привет"}\n{"message":"again"}\n',
        );

        expect(await storage.listKeys(), isEmpty);
        await storage.publish(key, first);
        final firstPointer = preferences.values[_activeKey(namespace, key)]!;
        expect(firstPointer, startsWith(_generationPrefix(namespace, key)));
        expect(await _readAll(storage, key), first);
        await storage.publish(key, second);
        final secondPointer = preferences.values[_activeKey(namespace, key)]!;
        expect(secondPointer, isNot(firstPointer));
        expect(preferences.values[firstPointer], utf8.decode(first));
        expect(preferences.values[secondPointer], utf8.decode(second));
        expect(await storage.listKeys(), <String>[key]);

        await storage.cleanup(key);
        expect(preferences.values.containsKey(firstPointer), isFalse);
        expect(preferences.values[secondPointer], utf8.decode(second));
        expect(preferences.values['unrelated.preference'], 'leave-me');
      },
    );

    test(
      'fresh origin-backed instances restore exact chats and ordering',
      () async {
        final first = JsonlAgentSessionStore(
          storage: JsonlBrowserStreamStorage(namespace: namespace),
        );
        final rich = _richRecord(
          AgentSessionId('browser-rich'),
          revision: 0,
          updatedAtMicros: 10,
        );
        final other = _record(
          AgentSessionId('browser-other'),
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
        final updated = rich.copyWith(revision: 1, updatedAtMicros: 11);
        await first.save(
          updated,
          expectedRevision: 0,
          cancellation: _openToken(),
        );

        final restarted = JsonlAgentSessionStore(
          storage: JsonlBrowserStreamStorage(namespace: namespace),
        );
        final catalog = await restarted.list();
        expect(catalog.available.map((entry) => entry.id.value), <String>[
          'browser-rich',
          'browser-other',
        ]);
        expect(await restarted.load(rich.id), updated);
        expect(await restarted.load(other.id), other);
        expect(catalog.available.first.messageCount, 3);
        expect(catalog.available.first.model, rich.definition.model);

        final beforeConflict = await _generationKeys(namespace, rich.id);
        await expectLater(
          restarted.save(
            rich.copyWith(revision: 1, updatedAtMicros: 99),
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
          _agentError(AgentErrorKind.conflict),
        );
        expect(await _generationKeys(namespace, rich.id), beforeConflict);
        expect(await restarted.load(rich.id), updated);
      },
    );

    test(
      'cancellation linearizes and admitted browser delete is commit-wins',
      () async {
        var holdPointer = false;
        var pointerReached = Completer<void>();
        var releasePointer = Completer<void>();
        final storage = JsonlBrowserStreamStorage(
          namespace: namespace,
          stageHook: (stage, _) async {
            if (holdPointer &&
                stage == JsonlBrowserStage.beforePointerPublication) {
              if (!pointerReached.isCompleted) {
                pointerReached.complete();
              }
              await releasePointer.future;
            }
          },
        );
        final store = JsonlAgentSessionStore(storage: storage);
        final initial = _record(
          AgentSessionId('browser-cancellation'),
          revision: 0,
          updatedAtMicros: 1,
        );
        await store.save(
          initial,
          expectedRevision: 0,
          cancellation: _openToken(),
        );

        holdPointer = true;
        final winner = initial.copyWith(revision: 1, updatedAtMicros: 2);
        final winningSave = store.save(
          winner,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        await pointerReached.future;
        final cancelled = CancellationSource();
        final waitingSave = store.save(
          initial.copyWith(revision: 1, updatedAtMicros: 3),
          expectedRevision: 0,
          cancellation: cancelled.token,
        );
        cancelled.cancel();
        releasePointer.complete();
        await winningSave;
        await expectLater(waitingSave, _agentError(AgentErrorKind.cancelled));
        expect(await store.load(initial.id), winner);

        pointerReached = Completer<void>();
        releasePointer = Completer<void>();
        final deleteCancellation = CancellationSource();
        final deleting = store.delete(
          initial.id,
          expectedRevision: 1,
          cancellation: deleteCancellation.token,
        );
        await pointerReached.future;
        deleteCancellation.cancel();
        releasePointer.complete();
        await deleting;

        final restarted = JsonlAgentSessionStore(
          storage: JsonlBrowserStreamStorage(namespace: namespace),
        );
        expect(await restarted.load(initial.id), isNull);
        expect((await restarted.list()).available, isEmpty);
      },
    );

    test(
      'delete restart retains only tombstone and reserves the identifier',
      () async {
        var failCleanup = false;
        final first = JsonlAgentSessionStore(
          storage: JsonlBrowserStreamStorage(
            namespace: namespace,
            stageHook: (stage, _) {
              if (failCleanup && stage == JsonlBrowserStage.beforeCleanup) {
                throw StateError('blocked cleanup /private/sk-secret');
              }
            },
          ),
        );
        final deleted = _record(
          AgentSessionId('browser-deleted'),
          revision: 0,
          updatedAtMicros: 1,
          messages: 3,
        );
        await first.save(
          deleted,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        failCleanup = true;
        await first.delete(
          deleted.id,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        expect(
          (await _generationKeys(namespace, deleted.id)).length,
          greaterThan(1),
        );
        final preferences = SharedPreferencesJsonlBrowserPreferences();
        final deletedKey = const JsonlSessionKeyCodec().encode(deleted.id);
        final active = await preferences.getString(
          _activeKey(namespace, deletedKey),
        );
        final tombstone = await preferences.getString(active!);
        expect(tombstone, contains('"operation":"delete"'));
        expect(tombstone, isNot(contains('message-')));

        final restarted = JsonlAgentSessionStore(
          storage: JsonlBrowserStreamStorage(namespace: namespace),
        );
        expect(await restarted.load(deleted.id), isNull);
        expect((await restarted.list()).available, isEmpty);
        expect(await _generationKeys(namespace, deleted.id), hasLength(1));
        await expectLater(
          restarted.save(
            deleted,
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
          _agentError(AgentErrorKind.conflict),
        );

        final fresh = _record(
          AgentSessionId('browser-fresh'),
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
      'quota, blocked access, invalid pointer, and bounds are sanitized',
      () async {
        final record = _record(
          AgentSessionId('browser-failure'),
          revision: 0,
          updatedAtMicros: 1,
        );

        final quota = _MemoryBrowserPreferences()
          ..failSet = (key) => key.contains('.generation.');
        await _expectSanitizedPersistence(
          JsonlAgentSessionStore(
            storage: JsonlBrowserStreamStorage(
              preferences: quota,
              namespace: namespace,
            ),
          ).save(record, expectedRevision: 0, cancellation: _openToken()),
        );
        expect(quota.values, isEmpty);

        final blocked = _MemoryBrowserPreferences()..failGetKeys = true;
        await _expectSanitizedPersistence(
          JsonlAgentSessionStore(
            storage: JsonlBrowserStreamStorage(
              preferences: blocked,
              namespace: namespace,
            ),
          ).list(),
        );

        final unavailable = _MemoryBrowserPreferences()..failGetString = true;
        await _expectSanitizedPersistence(
          JsonlAgentSessionStore(
            storage: JsonlBrowserStreamStorage(
              preferences: unavailable,
              namespace: namespace,
            ),
          ).load(record.id),
        );

        final corrupt = _MemoryBrowserPreferences();
        final key = const JsonlSessionKeyCodec().encode(record.id);
        corrupt.values[_activeKey(namespace, key)] =
            '$namespace.other-session.generation.sk-secret';
        await _expectSanitizedPersistence(
          JsonlAgentSessionStore(
            storage: JsonlBrowserStreamStorage(
              preferences: corrupt,
              namespace: namespace,
            ),
          ).load(record.id),
        );

        final oversized = _MemoryBrowserPreferences();
        final generation = '${_generationPrefix(namespace, key)}${'a' * 32}';
        oversized.values[_activeKey(namespace, key)] = generation;
        oversized.values[generation] = 'sk-secret';
        await _expectSanitizedPersistence(
          JsonlAgentSessionStore(
            storage: JsonlBrowserStreamStorage(
              preferences: oversized,
              namespace: namespace,
              maxStreamBytes: 4,
            ),
          ).load(record.id),
        );
      },
    );

    test(
      'pointer failure preserves the old generation without fallback',
      () async {
        final preferences = _MemoryBrowserPreferences();
        final storage = JsonlBrowserStreamStorage(
          preferences: preferences,
          namespace: namespace,
        );
        final store = JsonlAgentSessionStore(storage: storage);
        final initial = _record(
          AgentSessionId('browser-pointer-failure'),
          revision: 0,
          updatedAtMicros: 1,
        );
        await store.save(
          initial,
          expectedRevision: 0,
          cancellation: _openToken(),
        );
        preferences.failSet = (key) => key.endsWith('.active');
        await _expectSanitizedPersistence(
          store.save(
            initial.copyWith(revision: 1, updatedAtMicros: 2),
            expectedRevision: 0,
            cancellation: _openToken(),
          ),
        );
        preferences.failSet = null;

        final restarted = JsonlAgentSessionStore(
          storage: JsonlBrowserStreamStorage(
            preferences: preferences,
            namespace: namespace,
          ),
        );
        expect(await restarted.load(initial.id), initial);
        expect(
          (await _generationKeysFrom(
            preferences,
            namespace,
            initial.id,
          )).length,
          greaterThan(1),
        );
        await restarted.list();
        expect(
          await _generationKeysFrom(preferences, namespace, initial.id),
          hasLength(1),
        );
      },
    );
  });
}

final class _MemoryBrowserPreferences implements JsonlBrowserPreferences {
  final Map<String, String> values = <String, String>{};
  bool failGetKeys = false;
  bool failGetString = false;
  bool Function(String key)? failSet;
  bool Function(String key)? failRemove;

  @override
  Future<Set<String>> getKeys() async {
    if (failGetKeys) {
      throw StateError('blocked browser storage /private/sk-secret');
    }
    return values.keys.toSet();
  }

  @override
  Future<String?> getString(String key) async {
    if (failGetString) {
      throw StateError('unavailable browser storage /private/sk-secret');
    }
    return values[key];
  }

  @override
  Future<void> remove(String key) async {
    if (failRemove?.call(key) ?? false) {
      throw StateError('blocked browser cleanup /private/sk-secret');
    }
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (failSet?.call(key) ?? false) {
      throw StateError('quota exceeded /private/sk-secret raw-content');
    }
    values[key] = value;
  }
}

Future<void> _clearNamespace(String namespace) async {
  final preferences = SharedPreferencesJsonlBrowserPreferences();
  final prefix = '$namespace.';
  for (final key in await preferences.getKeys()) {
    if (key.startsWith(prefix)) {
      await preferences.remove(key);
    }
  }
}

Future<List<int>?> _readAll(JsonlStreamStorage storage, String key) async {
  final stream = await storage.read(key);
  if (stream == null) {
    return null;
  }
  final bytes = <int>[];
  await for (final chunk in stream) {
    bytes.addAll(chunk);
  }
  return bytes;
}

String _activeKey(String namespace, String key) {
  return '$namespace.stream.$key.active';
}

String _generationPrefix(String namespace, String key) {
  return '$namespace.stream.$key.generation.';
}

Future<Set<String>> _generationKeys(String namespace, AgentSessionId id) {
  return _generationKeysFrom(
    SharedPreferencesJsonlBrowserPreferences(),
    namespace,
    id,
  );
}

Future<Set<String>> _generationKeysFrom(
  JsonlBrowserPreferences preferences,
  String namespace,
  AgentSessionId id,
) async {
  final key = const JsonlSessionKeyCodec().encode(id);
  final prefix = _generationPrefix(namespace, key);
  return (await preferences.getKeys())
      .where((candidate) => candidate.startsWith(prefix))
      .toSet();
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

import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart'
    hide createPlatformJsonlStreamStorage;
import 'package:domovoy/infrastructure/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JSONL Project store', () {
    test('envelope keys are independent of session namespace', () {
      const codec = JsonlProjectKeyCodec();
      final key = codec.encode(ProjectId('../proj один'));
      expect(key, matches(RegExp(r'^project-v1_[A-Za-z0-9_-]+$')));
      expect(key, isNot(contains('session-v1_')));
      expect(codec.decode(key), ProjectId('../proj один'));
    });

    test('restart restores two projects and ignores partial tails', () async {
      final storage = _FakeJsonlStorage();
      final store = JsonlProjectStore(storage: storage);
      final first = _record('a', updated: 9);
      final second = _record('b', updated: 9);
      await store.save(
        first,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      await store.save(
        second,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final key = const JsonlProjectKeyCodec().encode(first.id);
      storage.appendRaw(key, '{"partial"');
      final restarted = JsonlProjectStore(storage: storage);
      final snapshot = await restarted.list();
      expect(snapshot.available.map((item) => item.id.value), ['a', 'b']);
      expect(await restarted.load(first.id), first);
    });

    test('v1 records migrate to kind user and republish as v2', () async {
      final storage = _FakeJsonlStorage();
      final id = ProjectId('legacy');
      final v1Record = Map<String, Object?>.from(_record('legacy').toJson())
        ..['version'] = ProjectRecord.legacyJsonVersion
        ..remove('kind');
      final envelope = <String, Object?>{
        'type': JsonlProjectEnvelope.type,
        'version': JsonlProjectEnvelope.version,
        'projectId': 'legacy',
        'sequence': 0,
        'operation': JsonlProjectOperation.upsert.name,
        'expectedRevision': 0,
        'recordRevision': 0,
        'record': v1Record,
      };
      storage.replace(
        const JsonlProjectKeyCodec().encode(id),
        '${jsonEncode(envelope)}\n',
      );
      final store = JsonlProjectStore(storage: storage);
      final loaded = await store.load(id);
      expect(loaded, isNotNull);
      expect(loaded!.kind, ProjectKind.user);
      expect(loaded, _record('legacy'));

      await store.save(
        loaded.copyWith(revision: 1, updatedAtMicros: 3),
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final reloaded = await JsonlProjectStore(storage: storage).load(id);
      expect(reloaded!.revision, 1);
      expect(reloaded.kind, ProjectKind.user);
    });

    test('malformed complete line isolates the neighbor', () async {
      final storage = _FakeJsonlStorage();
      final store = JsonlProjectStore(storage: storage);
      final healthy = _record('healthy', updated: 3);
      final broken = _record('broken', updated: 4);
      await store.save(
        healthy,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      await store.save(
        broken,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      storage.replace(
        const JsonlProjectKeyCodec().encode(broken.id),
        '{"not":"an envelope"}\n',
      );
      final snapshot = await JsonlProjectStore(storage: storage).list();
      expect(snapshot.available.single.id, healthy.id);
      expect(snapshot.issues, hasLength(1));
      expect(
        snapshot.issues.single.reason.message,
        isNot(contains('envelope')),
      );
    });

    test('unknown version, key mismatch, tombstone, cancel', () async {
      final storage = _FakeJsonlStorage();
      final store = JsonlProjectStore(storage: storage);
      final record = _record('one');
      await store.save(
        record,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      await expectLater(
        store.save(
          record.copyWith(revision: 1),
          expectedRevision: 0,
          cancellation: (CancellationSource()..cancel()).token,
        ),
        throwsA(
          isA<ProjectException>().having(
            (error) => error.error.kind,
            'kind',
            ProjectErrorKind.cancelled,
          ),
        ),
      );
      await store.delete(
        record.id,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      expect(await JsonlProjectStore(storage: storage).load(record.id), isNull);
      storage.failList = true;
      await expectLater(
        JsonlProjectStore(storage: storage).list(),
        throwsA(isA<ProjectException>()),
      );
    });
  });

  test('web factory publishes no Project stream', () {
    expect(createPlatformProjectJsonlStreamStorage(), isNull);
  }, skip: !_isWebHint);

  test('native Project namespace is independent when IO is available', () {
    expect(
      JsonlFilesystemStreamStorage.projectStorageDirectoryName,
      'project-workspaces-jsonl-v1',
    );
    expect(
      JsonlFilesystemStreamStorage.storageDirectoryName,
      'agent-sessions-jsonl-v1',
    );
  });
}

const _isWebHint = bool.fromEnvironment('dart.library.js_interop');

ProjectRecord _record(String id, {int updated = 1}) {
  return ProjectRecord(
    id: ProjectId(id),
    revision: 0,
    name: 'Project $id',
    root: ExternalGrantRootReference(DirectoryGrantId('g-$id')),
    createdAtMicros: 1,
    updatedAtMicros: updated,
  );
}

final class _FakeJsonlStorage implements JsonlStreamStorage {
  final Map<String, String> _active = <String, String>{};
  var failList = false;

  void appendRaw(String key, String fragment) {
    _active[key] = '${_active[key] ?? ''}$fragment';
  }

  void replace(String key, String contents) => _active[key] = contents;

  @override
  Future<List<String>> listKeys() async {
    if (failList) {
      throw StateError('list failed');
    }
    return _active.keys.toList()..sort();
  }

  @override
  Future<Stream<List<int>>?> read(String key) async {
    final text = _active[key];
    if (text == null) {
      return null;
    }
    return Stream<List<int>>.value(utf8.encode(text));
  }

  @override
  Future<void> publish(String key, List<int> contents) async {
    _active[key] = utf8.decode(contents);
  }

  @override
  Future<void> cleanup(String key) async {}
}

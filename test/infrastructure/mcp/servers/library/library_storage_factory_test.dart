import 'dart:io';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart';
import 'package:domovoy/infrastructure/mcp/servers/library/library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'library_test_support.dart';

void main() {
  test('creates the on-device library namespace', () {
    final storage = createPlatformLibraryJsonlStreamStorage();

    expect(storage, isA<JsonlFilesystemStreamStorage>());
    expect(
      (storage! as JsonlFilesystemStreamStorage).namespaceDirectoryName,
      libraryJsonlStorageDirectoryName,
    );
    expect(libraryJsonlStorageDirectoryName, 'library-jsonl-v1');
  });

  test(
    'persists and replays through the real atomic filesystem storage',
    () async {
      final root = await Directory.systemTemp.createTemp('domovoy-library-');
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      JsonlStreamStorage storage() => JsonlFilesystemStreamStorage(
        applicationSupportDirectoryResolver: () async => root,
        namespaceDirectoryName: libraryJsonlStorageDirectoryName,
      );
      final clock = FakeLibraryClock();
      final token = CancellationSource().token;

      final store = JsonlLibraryStore(
        storage: storage(),
        clock: clock,
        ids: SequentialLibraryIdGenerator(),
      );
      final saved = await store.save(
        topic: 'Research topic',
        papers: <Paper>[libraryPaper()],
        digest: libraryDigest(),
        runId: 'run_1',
        cancellation: token,
      );

      final libraryRoot = Directory(
        p.join(
          root.path,
          'ru.kotdath.domovoy',
          libraryJsonlStorageDirectoryName,
        ),
      );
      expect(await libraryRoot.exists(), isTrue);
      expect(
        libraryRoot.listSync(recursive: true).whereType<File>(),
        isNotEmpty,
        reason: 'a record must exist as an atomic JSONL generation',
      );

      final reopened = JsonlLibraryStore(
        storage: storage(),
        clock: clock,
        ids: SequentialLibraryIdGenerator(),
      );
      final loaded = await reopened.find(
        saved.record.libraryId,
        cancellation: token,
      );
      expect(loaded, saved.record);

      final repeated = await reopened.save(
        topic: 'Research topic',
        papers: <Paper>[libraryPaper()],
        digest: libraryDigest(),
        runId: 'run_1',
        cancellation: token,
      );
      expect(repeated.created, isFalse);
      expect(repeated.record.libraryId, saved.record.libraryId);

      final page = await reopened.list(limit: 10, cancellation: token);
      expect(page.totalCount, 1);
      expect(page.cards.single.libraryId, saved.record.libraryId);
    },
  );
}

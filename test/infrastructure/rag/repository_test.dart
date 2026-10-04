import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';

RagIndex fixtureIndex() {
  final doc = RagDocument(
    source: 'facts.md',
    title: 'Facts',
    text: 'Memory\nSchedule',
  );
  final chunks = [
    for (final span in [(0, 6), (7, 15)])
      RagChunk(
        documentId: doc.id,
        documentRevision: doc.revision,
        source: doc.source,
        title: doc.title,
        section: 'Facts',
        start: span.$1,
        end: span.$2,
        text: doc.text.substring(span.$1, span.$2),
        strategy: ChunkStrategy.fixed,
        tokens: 1,
        ordinal: span.$1,
      ),
  ];
  return RagIndex(
    fingerprint: 'v1',
    dimension: 2,
    strategy: ChunkStrategy.fixed,
    chunks: chunks,
    vectors: [
      [2, 0],
      [0, 3],
    ],
    documents: [doc],
    elapsedMs: 10,
    generation: 'g1',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('empty document corpus has valid checksummed JSONL framing', () async {
    final storage = FakeMemoryJsonlStorage();
    final repo = JsonlRagRepository(storage);
    await repo.saveDocuments('p', 'empty', []);
    expect(await JsonlRagRepository(storage).documents('p', 'empty'), isEmpty);
  });
  test('normalized cosine order, thresholds and fingerprint compatibility', () {
    final index = fixtureIndex();
    final hits = searchRagIndex(index, [1, 0], 'v1');
    expect(hits.first.chunk.text, 'Memory');
    expect(hits.first.score, closeTo(1, 1e-9));
    expect(searchRagIndex(index, [1, 0], 'v1', threshold: .5), hasLength(1));
    expect(() => searchRagIndex(index, [1, 0], 'v2'), throwsFormatException);
    for (final v in [
      [0, 0],
      [double.nan, 0],
      [double.infinity, 0],
      [1],
    ]) {
      expect(() => normalizedRagVector(v, 2), throwsFormatException);
    }
    expect(() => index.vectors.first[0] = 0, throwsUnsupportedError);
  });
  test(
    'roundtrip preserves revision evidence; projects/corpora are isolated',
    () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = JsonlRagRepository(storage);
      final index = fixtureIndex();
      await repository.saveDocuments('p', 'docs', index.documents);
      await repository.publishIndex('p', 'docs', index);
      final reopened = JsonlRagRepository(storage);
      final loaded = await reopened.loadIndex('p', 'docs', ChunkStrategy.fixed);
      expect(loaded!.chunks.map((c) => c.id), index.chunks.map((c) => c.id));
      expect(loaded.documents.single.revision, index.documents.single.revision);
      expect(
        await reopened.loadIndex('other', 'docs', ChunkStrategy.fixed),
        isNull,
      );
      expect(
        await reopened.loadIndex('p', 'other', ChunkStrategy.fixed),
        isNull,
      );
      final rebuilt = RagIndex(
        fingerprint: index.fingerprint,
        dimension: index.dimension,
        strategy: index.strategy,
        chunks: index.chunks,
        vectors: index.vectors,
        documents: index.documents,
        elapsedMs: 20,
        generation: 'g2',
      );
      await repository.publishIndex('p', 'docs', rebuilt);
      expect(
        (await repository.loadGeneration('p', 'docs', 'g1'))!.generation,
        'g1',
      );
      expect(
        (await repository.loadIndex(
          'p',
          'docs',
          ChunkStrategy.fixed,
        ))!.generation,
        'g2',
      );
      final newDoc = RagDocument(
        source: 'facts.md',
        title: 'Facts',
        text: 'New revision',
      );
      await repository.saveDocuments('p', 'docs', [newDoc]);
      expect(
        (await reopened.loadIndex(
          'p',
          'docs',
          ChunkStrategy.fixed,
        ))!.documents.single.text,
        'Memory\nSchedule',
      );
    },
  );
  test(
    'filesystem pointer failure retains durable active generation',
    () async {
      final dir = await Directory.systemTemp.createTemp('rag-atomic-test-');
      addTearDown(() => dir.delete(recursive: true));
      var fail = false;
      final storage = JsonlFilesystemStreamStorage(
        applicationSupportDirectoryResolver: () async => dir,
        namespaceDirectoryName: 'rag-test',
        stageHook: (stage, key) {
          if (fail &&
              stage == JsonlFilesystemStage.beforePointerPublication &&
              key == ragHash(jsonEncode(['p', 'docs', 'fixed']))) {
            throw const FileSystemException('injected pointer failure');
          }
        },
      );
      final repo = JsonlRagRepository(storage);
      final old = fixtureIndex();
      await repo.publishIndex('p', 'docs', old);
      fail = true;
      final next = RagIndex(
        fingerprint: old.fingerprint,
        dimension: old.dimension,
        strategy: old.strategy,
        chunks: old.chunks,
        vectors: old.vectors,
        documents: old.documents,
        elapsedMs: 30,
        generation: 'g-next',
      );
      await expectLater(
        repo.publishIndex('p', 'docs', next),
        throwsA(isA<FileSystemException>()),
      );
      final reopened = JsonlRagRepository(
        JsonlFilesystemStreamStorage(
          applicationSupportDirectoryResolver: () async => dir,
          namespaceDirectoryName: 'rag-test',
        ),
      );
      expect(
        (await reopened.loadIndex(
          'p',
          'docs',
          ChunkStrategy.fixed,
        ))!.generation,
        'g1',
      );
    },
  );

  test(
    'PDF bytes stored once; scopes with delimiter characters stay distinct',
    () async {
      final storage = FakeMemoryJsonlStorage();
      final repo = JsonlRagRepository(storage);
      final bytes = utf8.encode('%PDF-test');
      final doc = RagDocument(
        source: 'paper.pdf',
        title: 'Paper',
        text: 'Text',
        pdfBase64: base64Encode(bytes),
        pdfSize: bytes.length,
        pageStarts: [0],
      );
      await repo.saveDocuments('a|b', 'c', [doc]);
      final keyCount = storage.keys.length;
      await repo.saveDocuments('a|b', 'c', [doc]);
      expect(storage.keys.length, keyCount);
      final loaded = (await repo.documents('a|b', 'c')).single;
      expect(loaded.pdfBase64, isNull);
      expect(loaded.pdfSize, bytes.length);
      expect(await repo.originalPdf('a|b', 'c', loaded), bytes);
      expect(await repo.documents('a', 'b|c'), isEmpty);
    },
  );
  test(
    'partial or corrupt index fails instead of accepting incomplete evidence',
    () async {
      final storage = FakeMemoryJsonlStorage();
      final repository = JsonlRagRepository(storage);
      await repository.publishIndex('p', 'docs', fixtureIndex());
      storage.appendText(storage.keys.last, 'partial');
      await expectLater(
        repository.loadIndex('p', 'docs', ChunkStrategy.fixed),
        throwsFormatException,
      );
    },
  );
}

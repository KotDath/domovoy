import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/rag/contracts.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/features/knowledge/application/knowledge_controller.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_jsonl_storage.dart';
import '../../../support/rag_fakes.dart';

final class ControlledModels implements RagModelProvider {
  final delegate = FakeRagModels();
  Completer<void>? release;
  Completer<void>? entered;
  @override
  Future<RagModelInfo> health(CancellationToken token) =>
      delegate.health(token);
  @override
  Future<List<RagToken>> tokenize(
    String text,
    CancellationToken token, {
    bool reranker = false,
  }) => delegate.tokenize(text, token, reranker: reranker);
  @override
  Future<List<List<double>>> embed(
    List<String> texts,
    RagModelInfo model,
    CancellationToken token, {
    bool query = false,
  }) async {
    entered?.complete();
    entered = null;
    if (release != null) await release!.future;
    checkRagCancellation(token.isCancelled);
    return delegate.embed(texts, model, token, query: query);
  }
}

final class FailingStorage implements JsonlStreamStorage {
  final delegate = FakeMemoryJsonlStorage();
  bool fail = false;
  @override
  Future<List<String>> listKeys() => delegate.listKeys();
  @override
  Future<Stream<List<int>>?> read(String key) => delegate.read(key);
  @override
  Future<void> publish(String key, List<int> bytes) async {
    if (fail) throw StateError('disk full');
    await delegate.publish(key, bytes);
  }

  @override
  Future<void> cleanup(String key) => delegate.cleanup(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancelled file picker leaves empty corpus untouched and reopenable',
    () async {
      final storage = FailingStorage();
      final c = KnowledgeController(
        repository: JsonlRagRepository(storage),
        models: FakeRagModels(),
        importer: FakeRagImporter(),
      );
      addTearDown(c.dispose);
      await c.initialize();
      await c.importFiles();
      expect(storage.delegate.keys, isEmpty);
      await c.initialize();
      expect(c.error, isNull);
      expect(c.documents, isEmpty);
    },
  );
  test(
    'cancelled rebuild and failed publication retain old durable generation',
    () async {
      final storage = FailingStorage();
      final repository = JsonlRagRepository(storage);
      final models = ControlledModels();
      final c = KnowledgeController(
        repository: repository,
        models: models,
        importer: FakeRagImporter(),
      );
      addTearDown(c.dispose);
      await c.addText('Facts', 'Memory and schedule');
      await c.buildIndex();
      final old = c.activeIndex!;
      models.release = Completer<void>();
      final entered = models.entered = Completer<void>();
      final rebuilding = c.buildIndex();
      await entered.future;
      c.cancel();
      models.release!.complete();
      await rebuilding;
      expect(c.activeIndex, same(old));
      expect(c.progress, contains('Отменено'));
      models.release = null;
      storage.fail = true;
      await c.buildIndex();
      expect(c.error, contains('disk full'));
      expect(c.activeIndex, same(old));
      final restarted = await repository.loadIndex(
        c.project,
        c.corpus,
        c.strategy,
      );
      expect(restarted!.generation, old.generation);
      expect(restarted.serializedBytes, old.serializedBytes);
    },
  );

  test(
    'failed corpus load cannot expose or copy the previous corpus',
    () async {
      final storage = FailingStorage();
      final c = KnowledgeController(
        repository: JsonlRagRepository(storage),
        models: FakeRagModels(),
        importer: FakeRagImporter(),
      );
      addTearDown(c.dispose);
      await c.addText('Old', 'Private project fact');
      await c.buildIndex();
      await c.search('fact');
      storage.delegate.replaceText(
        ragHash(jsonEncode(['default', 'arxiv', 'documents'])),
        'corrupt',
      );
      await c.selectCorpus('arxiv');
      expect(c.error, isNotNull);
      expect(c.corpus, 'arxiv');
      expect(c.documents, isEmpty);
      expect(c.indexes, isEmpty);
      expect(c.hits, isEmpty);
      await c.addText('New', 'Public paper');
      expect(c.documents.map((d) => d.text), ['Public paper']);
      await c.selectCorpus('domovoy');
      expect(c.documents.single.text, 'Private project fact');
    },
  );
  test(
    'same-title texts coexist and comparison uses both current snapshots',
    () async {
      final c = KnowledgeController(
        repository: JsonlRagRepository(FakeMemoryJsonlStorage()),
        models: FakeRagModels(),
        importer: FakeRagImporter(),
      );
      addTearDown(c.dispose);
      await c.addText('Same title', 'First fact');
      await c.addText('Same title', 'Second fact');
      await c.addText('Same title', 'Second fact');
      expect(c.documents.length, 2);
      c.selectStrategy(ChunkStrategy.fixed);
      await c.buildIndex();
      c.selectStrategy(ChunkStrategy.structure);
      await c.buildIndex();
      await c.compareSearch('fact');
      expect(c.error, isNull);
      expect(c.comparisonHits.keys.toSet(), ChunkStrategy.values.toSet());
      expect(c.comparisonQuery, 'fact');
      expect(c.comparisonHits.values.every((h) => h.length == 2), isTrue);
    },
  );
  test(
    'project switch waits for cancelled work and clears old hits and indexes',
    () async {
      final models = ControlledModels();
      final c = KnowledgeController(
        repository: JsonlRagRepository(FakeMemoryJsonlStorage()),
        models: models,
        importer: FakeRagImporter(),
      );
      addTearDown(c.dispose);
      await c.initialize(projectId: 'first');
      await c.addText('Facts', 'Memory');
      await c.buildIndex();
      await c.search('Memory');
      expect(c.hits, isNotEmpty);
      models.release = Completer<void>();
      final entered = models.entered = Completer<void>();
      final search = c.search('Memory');
      await entered.future;
      final switching = c.initialize(projectId: 'second');
      models.release!.complete();
      await search;
      await switching;
      expect(c.project, 'second');
      expect(c.hits, isEmpty);
      expect(c.documents, isEmpty);
      expect(c.indexes, isEmpty);
      models.release = null;
      await c.initialize(projectId: 'first');
      expect(c.documents.single.text, 'Memory');
      expect(c.activeIndex, isNotNull);
    },
  );
}

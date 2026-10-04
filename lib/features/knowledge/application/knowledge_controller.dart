import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/llm/cancellation.dart';
import '../../../core/rag/chunking.dart';
import '../../../core/rag/contracts.dart';
import '../../../core/rag/models.dart';

final class KnowledgeController extends ChangeNotifier {
  KnowledgeController({
    required this.repository,
    required this.models,
    required this.importer,
  });
  final RagRepository repository;
  final RagModelProvider models;
  final RagDocumentImporter importer;
  String project = 'default';
  String corpus = 'domovoy';
  List<RagDocument> documents = [];
  final Map<ChunkStrategy, RagIndex> indexes = {};
  List<RagHit> hits = [];
  Map<ChunkStrategy, List<RagHit>> comparisonHits = {};
  String? comparisonQuery;
  ChunkStrategy strategy = ChunkStrategy.structure;
  RagModelInfo? model;
  bool busy = false;
  bool _disposed = false;
  bool _publishing = false;
  String progress = '';
  String? error;
  CancellationSource? _cancellation;
  int _epoch = 0;
  Completer<void>? _idle;

  bool get canCancel => busy && !_publishing;
  RagIndex? get activeIndex => indexes[strategy];
  bool indexStale(RagIndex index) =>
      index.documents.map((d) => '${d.id}:${d.revision}').join('|') !=
      documents.map((d) => '${d.id}:${d.revision}').join('|');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void selectStrategy(ChunkStrategy value) {
    strategy = value;
    hits = [];
    comparisonHits = {};
    comparisonQuery = null;
    _notify();
  }

  Future<void> initialize({String? projectId}) async {
    if (busy) {
      cancel();
      await _idle?.future;
    }
    await _run((token) async {
      final selectedProject = projectId ?? project;
      final selectedCorpus = corpus;
      if (selectedProject != project) {
        documents = [];
        indexes.clear();
        hits = [];
        comparisonHits = {};
        comparisonQuery = null;
        model = null;
      }
      project = selectedProject;
      hits = [];
      comparisonHits = {};
      comparisonQuery = null;
      final loadedDocs = await repository.documents(
        selectedProject,
        selectedCorpus,
      );
      final loadedIndexes = <ChunkStrategy, RagIndex>{};
      for (final kind in ChunkStrategy.values) {
        final index = await repository.loadIndex(
          selectedProject,
          selectedCorpus,
          kind,
        );
        checkRagCancellation(token.isCancelled);
        if (index != null) loadedIndexes[kind] = index;
      }
      checkRagCancellation(token.isCancelled);
      documents = loadedDocs;
      indexes
        ..clear()
        ..addAll(loadedIndexes);
      progress = 'Загружено документов: ${documents.length}';
    });
  }

  Future<void> selectCorpus(String value) async {
    if (busy) return;
    corpus = value;
    documents = [];
    indexes.clear();
    hits = [];
    comparisonHits = {};
    comparisonQuery = null;
    model = null;
    await initialize();
  }

  Future<void> checkService() => _run((token) async {
    model = await models.health(token);
    final vector = await models.embed(
      ['Проверка подключения: память проекта'],
      model!,
      token,
      query: true,
    );
    progress =
        '${model!.label} · ${vector.single.length}D · живой embedding получен';
  });

  Future<void> loadDemoCorpus() => _run((token) async {
    final manifest =
        jsonDecode(await rootBundle.loadString('assets/rag_demo/manifest.json'))
            as List;
    final docs = <RagDocument>[];
    for (final row in manifest) {
      checkRagCancellation(token.isCancelled);
      final text = await rootBundle.loadString(row['asset'] as String);
      if (ragHash(text) != row['sha256']) {
        throw const FormatException('Demo corpus hash mismatch');
      }
      docs.add(
        RagDocument(
          source: row['source'] as String,
          title: row['source'] as String,
          text: text,
          sourceRevision: row['revision'] as String?,
        ),
      );
    }
    await _saveMerged(docs, token);
    progress = 'Импортировано ${docs.length} документов Domovoy';
  });

  Future<void> importFiles() => _run((token) async {
    final docs = await importer.selectFiles();
    if (docs.isEmpty) {
      progress = 'Выбор файлов отменён; корпус не изменён';
      return;
    }
    await _saveMerged(docs, token);
    progress = 'Импортировано ${docs.length} файлов';
  });

  Future<void> importArxiv(String input) => _run((token) async {
    progress = 'Загрузка и извлечение PDF arXiv…';
    _notify();
    final doc = await importer.importArxiv(input);
    await _saveMerged([doc], token);
    progress = 'Импортировано ${doc.title}, страниц: ${doc.pageStarts.length}';
  });

  Future<void> addText(String title, String text) => _run((token) async {
    if (title.trim().isEmpty || text.trim().isEmpty) {
      throw ArgumentError('Введите название и текст');
    }
    await _saveMerged([
      RagDocument(
        source: 'local:${title.trim()}:${ragHash(text).substring(0, 16)}',
        title: title.trim(),
        text: text,
      ),
    ], token);
    progress = 'Документ сохранён; перестройте индекс';
  });

  Future<void> _saveMerged(
    List<RagDocument> added,
    CancellationToken token,
  ) async {
    checkRagCancellation(token.isCancelled);
    final merged = {
      for (final d in documents) d.id: d,
      for (final d in added) d.id: d,
    }.values.toList()..sort((a, b) => a.source.compareTo(b.source));
    final totalChars = merged.fold<int>(0, (sum, doc) => sum + doc.text.length);
    if (merged.fold<int>(0, (size, d) => size + d.pdfSize) >
        128 * 1024 * 1024) {
      throw StateError('PDF-файлы корпуса ограничены суммарно 128 МБ');
    }
    if (totalChars > 4000000 || merged.length > 100) {
      throw StateError('Корпус ограничен 100 документами и 4 млн символов');
    }
    if (merged.any((d) => d.text.length > 2000000)) {
      throw StateError('Документ ограничен 2 млн символов');
    }
    if (merged.any((d) => d.text.trim().isEmpty)) {
      throw const FormatException('Документ пуст');
    }
    _publishing = true;
    _notify();
    await repository.saveDocuments(project, corpus, merged);
    documents = merged
        .map(
          (d) => RagDocument(
            source: d.source,
            title: d.title,
            text: d.text,
            pageStarts: d.pageStarts,
            pdfHash: d.pdfHash,
            pdfSize: d.pdfSize,
            sourceRevision: d.sourceRevision,
          ),
        )
        .toList(growable: false);
    hits = [];
    comparisonHits = {};
    comparisonQuery = null;
  }

  Future<void> buildIndex() => _run((token) async {
    if (documents.isEmpty) throw StateError('Сначала добавьте документы');
    final selected = strategy;
    final docs = List<RagDocument>.of(documents);
    final stopwatch = Stopwatch()..start();
    final info = await models.health(token);
    model = info;
    final chunks = <RagChunk>[];
    final chunker = RagChunker(models);
    for (var i = 0; i < docs.length; i++) {
      progress =
          'Разбиение: документ ${i + 1}/${docs.length} · чанков ${chunks.length}';
      _notify();
      chunks.addAll(await chunker.split(docs[i], selected, token));
    }
    final vectors = <List<double>>[];
    for (var start = 0; start < chunks.length; start += 8) {
      checkRagCancellation(token.isCancelled);
      progress = 'Эмбеддинги: ${vectors.length}/${chunks.length}';
      _notify();
      final batch = chunks.sublist(start, min(start + 8, chunks.length));
      vectors.addAll(
        await models.embed(batch.map((c) => c.text).toList(), info, token),
      );
    }
    checkRagCancellation(token.isCancelled);
    final index = RagIndex(
      fingerprint: info.fingerprint,
      dimension: info.dimension,
      strategy: selected,
      chunks: List.unmodifiable(chunks),
      vectors: List.unmodifiable(vectors),
      documents: List.unmodifiable(docs),
      elapsedMs: stopwatch.elapsedMilliseconds,
      generation: ragHash(
        '${info.fingerprint}|${selected.name}|${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    _publishing = true;
    progress = 'Публикация проверенного индекса…';
    _notify();
    await repository.publishIndex(project, corpus, index);
    indexes[selected] = index;
    hits = [];
    comparisonHits = {};
    comparisonQuery = null;
    progress =
        '${selected.name}: ${chunks.length} чанков · ${info.dimension}D · '
        '${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1)} с';
  });

  Future<void> search(String question) => _run((token) async {
    final index = activeIndex;
    if (index == null) throw StateError('Сначала постройте индекс');
    if (indexStale(index)) {
      throw StateError('Документы изменились: перестройте индекс');
    }
    if (question.trim().isEmpty) throw ArgumentError('Введите вопрос');
    final info = await models.health(token);
    final vector = await models.embed(
      [question.trim()],
      info,
      token,
      query: true,
    );
    final found = await compute(_search, (
      index,
      vector.single,
      info.fingerprint,
    ));
    checkRagCancellation(token.isCancelled);
    hits = found;
    progress = 'Поиск: ${hits.length} чанков · генератор не вызывался';
  });

  Future<void> compareSearch(String question) => _run((token) async {
    if (question.trim().isEmpty) throw ArgumentError('Введите вопрос');
    final snapshots = Map<ChunkStrategy, RagIndex>.of(indexes);
    if (snapshots.length != 2 || snapshots.values.any(indexStale)) {
      throw StateError('Нужны два актуальных индекса одного корпуса');
    }
    final info = await models.health(token);
    final vector = await models.embed(
      [question.trim()],
      info,
      token,
      query: true,
    );
    final found = <ChunkStrategy, List<RagHit>>{};
    for (final entry in snapshots.entries) {
      found[entry.key] = await compute(_search, (
        entry.value,
        vector.single,
        info.fingerprint,
      ));
      checkRagCancellation(token.isCancelled);
    }
    comparisonHits = found;
    comparisonQuery = question.trim();
    progress = 'Один query-вектор · два локальных поиска top-5';
  });

  Future<void> _run(Future<void> Function(CancellationToken) operation) async {
    if (busy || _disposed) return;
    busy = true;
    final idle = Completer<void>();
    _idle = idle;
    error = null;
    _publishing = false;
    final source = CancellationSource();
    _cancellation = source;
    final epoch = ++_epoch;
    _notify();
    try {
      await operation(source.token);
    } on RagCancelled {
      progress = 'Отменено; предыдущий индекс сохранён';
    } on Object catch (e) {
      error = e.toString();
    } finally {
      idle.complete();
      if (epoch == _epoch && !_disposed) {
        busy = false;
        _publishing = false;
        _cancellation = null;
        _notify();
      }
    }
  }

  void cancel() {
    if (canCancel) _cancellation?.cancel();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _cancellation?.cancel();
    super.dispose();
  }
}

List<RagHit> _search((RagIndex, List<double>, String) input) =>
    searchRagIndex(input.$1, input.$2, input.$3);

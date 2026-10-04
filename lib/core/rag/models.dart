import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

String ragHash(String text) => sha256.convert(utf8.encode(text)).toString();

void checkRagCancellation(bool cancelled) {
  if (cancelled) throw const RagCancelled();
}

final class RagCancelled implements Exception {
  const RagCancelled();
  @override
  String toString() => 'Операция отменена';
}

enum ChunkStrategy { fixed, structure }

final class RagDocument {
  RagDocument({
    required this.source,
    required this.title,
    required String text,
    List<int> pageStarts = const [],
    this.pdfBase64,
    String? pdfHash,
    this.sourceRevision,
    this.pdfSize = 0,
  }) : pdfHash = pdfHash ?? (pdfBase64 == null ? null : ragHash(pdfBase64)),
       pageStarts = List.unmodifiable(pageStarts),
       text = normalize(text),
       revision = ragHash(normalize(text)),
       id = ragHash(source);

  static String normalize(String text) => text
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');

  final String id;
  final String source;
  final String title;
  final String text;
  final String revision;
  final List<int> pageStarts;
  final String? pdfBase64;
  final String? pdfHash;
  final String? sourceRevision;
  final int pdfSize;

  int? pageAt(int offset) => pageStarts.isEmpty
      ? null
      : max(1, pageStarts.where((start) => start <= offset).length);

  Map<String, Object?> toJson({bool includePdf = true}) => {
    'source': source,
    'title': title,
    'text': text,
    'revision': revision,
    'page_starts': pageStarts,
    if (includePdf) 'pdf': pdfBase64,
    'pdf_ref': pdfHash,
    'source_revision': sourceRevision,
    'pdf_size': pdfSize,
  };

  factory RagDocument.fromJson(Map<String, dynamic> json) {
    final doc = RagDocument(
      source: json['source'] as String,
      title: json['title'] as String,
      text: json['text'] as String,
      pageStarts: (json['page_starts'] as List).cast<int>(),
      pdfBase64: json['pdf'] as String?,
      pdfHash: json['pdf_ref'] as String?,
      sourceRevision: json['source_revision'] as String?,
      pdfSize: (json['pdf_size'] as int?) ?? 0,
    );
    if (doc.revision != json['revision']) {
      throw const FormatException('Document revision mismatch');
    }
    return doc;
  }
}

final class RagChunk {
  RagChunk({
    required this.documentId,
    required this.documentRevision,
    required this.source,
    required this.title,
    required this.section,
    required this.start,
    required this.end,
    required this.text,
    required this.strategy,
    required this.tokens,
    required this.ordinal,
    this.pageStart,
    this.pageEnd,
    this.forcedSplit = false,
    this.config = 'v1-384-64',
  }) : id = ragHash(
         jsonEncode([
           documentId,
           documentRevision,
           strategy.name,
           config,
           start,
           end,
           ragHash(text),
         ]),
       );

  final String id;
  final String documentId;
  final String documentRevision;
  final String source;
  final String title;
  final String section;
  final int start;
  final int end;
  final String text;
  final ChunkStrategy strategy;
  final int tokens;
  final int ordinal;
  final int? pageStart;
  final int? pageEnd;
  final bool forcedSplit;
  final String config;

  Map<String, Object?> toJson() => {
    'id': id,
    'document': documentId,
    'revision': documentRevision,
    'source': source,
    'title': title,
    'section': section,
    'start': start,
    'end': end,
    'text': text,
    'strategy': strategy.name,
    'tokens': tokens,
    'ordinal': ordinal,
    'page_start': pageStart,
    'page_end': pageEnd,
    'forced_split': forcedSplit,
    'config': config,
  };

  factory RagChunk.fromJson(Map<String, dynamic> json) {
    final chunk = RagChunk(
      documentId: json['document'] as String,
      documentRevision: json['revision'] as String,
      source: json['source'] as String,
      title: json['title'] as String,
      section: json['section'] as String,
      start: json['start'] as int,
      end: json['end'] as int,
      text: json['text'] as String,
      strategy: ChunkStrategy.values.byName(json['strategy'] as String),
      tokens: json['tokens'] as int,
      ordinal: json['ordinal'] as int,
      pageStart: json['page_start'] as int?,
      pageEnd: json['page_end'] as int?,
      forcedSplit: json['forced_split'] as bool,
      config: json['config'] as String,
    );
    if (chunk.id != json['id']) {
      throw const FormatException('Chunk ID mismatch');
    }
    return chunk;
  }
}

List<double> normalizedRagVector(List<num> input, int dimension) {
  if (input.length != dimension || input.any((n) => !n.isFinite)) {
    throw const FormatException('Invalid embedding dimension or value');
  }
  final norm = sqrt(input.fold<double>(0, (sum, v) => sum + v * v));
  if (norm <= 0 || !norm.isFinite) {
    throw const FormatException('Zero embedding');
  }
  return List<double>.unmodifiable(input.map((v) => v / norm));
}

final class RagIndex {
  RagIndex({
    required this.fingerprint,
    required this.dimension,
    required this.strategy,
    required List<RagChunk> chunks,
    required List<List<double>> vectors,
    required List<RagDocument> documents,
    required this.elapsedMs,
    required this.generation,
  }) : chunks = List.unmodifiable(chunks),
       vectors = List.unmodifiable(
         vectors.map((v) => normalizedRagVector(v, dimension)),
       ),
       documents = List.unmodifiable(documents) {
    if (dimension <= 0 ||
        chunks.isEmpty ||
        chunks.length != vectors.length ||
        chunks.map((c) => c.id).toSet().length != chunks.length) {
      throw const FormatException('Incomplete index');
    }
    final docs = {for (final doc in documents) doc.id: doc};
    if (docs.length != documents.length) {
      throw const FormatException('Duplicate index document');
    }
    for (var i = 0; i < chunks.length; i++) {
      normalizedRagVector(vectors[i], dimension);
      final chunk = chunks[i];
      final doc = docs[chunk.documentId];
      if (doc == null ||
          chunk.documentRevision != doc.revision ||
          chunk.strategy != strategy ||
          chunk.start < 0 ||
          chunk.end > doc.text.length ||
          chunk.start >= chunk.end ||
          doc.text.substring(chunk.start, chunk.end) != chunk.text) {
        throw const FormatException('Index evidence mismatch');
      }
    }
  }
  final String fingerprint;
  final int dimension;
  final ChunkStrategy strategy;
  final List<RagChunk> chunks;
  final List<List<double>> vectors;
  final List<RagDocument> documents;
  final int elapsedMs;
  final String generation;
  List<Map<String, Object?>> get jsonlRows => [
    {
      'type': 'manifest',
      'fingerprint': fingerprint,
      'dimension': dimension,
      'strategy': strategy.name,
      'generation': generation,
      'elapsed_ms': elapsedMs,
      'count': chunks.length,
    },
    for (final doc in documents)
      {'type': 'document', 'data': doc.toJson(includePdf: false)},
    for (var i = 0; i < chunks.length; i++)
      {'type': 'chunk', 'data': chunks[i].toJson(), 'vector': vectors[i]},
  ];

  /// Exact encoded JSONL size, including document snapshots and footer.
  int get serializedBytes => encodeRagJsonl(jsonlRows).length;

  /// Repeated UTF-16 evidence coordinates; independent of token boundary merges.
  int get overlapCharacters {
    var total = 0;
    var unique = 0;
    for (final doc in documents) {
      final spans = chunks.where((c) => c.documentId == doc.id).toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      var end = 0;
      for (final chunk in spans) {
        total += chunk.end - chunk.start;
        unique += max(0, chunk.end - max(end, chunk.start));
        end = max(end, chunk.end);
      }
    }
    return total - unique;
  }
}

List<int> encodeRagJsonl(List<Map<String, Object?>> rows) {
  final text = rows.isEmpty ? '' : '${rows.map(jsonEncode).join('\n')}\n';
  return utf8.encode(
    '$text${jsonEncode({'type': 'end', 'version': 1, 'hash': ragHash(text)})}\n',
  );
}

final class RagHit {
  const RagHit(this.chunk, this.score);
  final RagChunk chunk;
  final double score;
}

List<RagHit> searchRagIndex(
  RagIndex index,
  List<double> query,
  String fingerprint, {
  int topK = 5,
  double threshold = -1,
}) {
  if (fingerprint != index.fingerprint) {
    throw const FormatException('Модель изменилась: перестройте индекс');
  }
  final q = normalizedRagVector(query, index.dimension);
  final hits = <RagHit>[];
  for (var i = 0; i < index.chunks.length; i++) {
    final v = index.vectors[i];
    var score = 0.0;
    for (var j = 0; j < q.length; j++) {
      score += q[j] * v[j];
    }
    if (score >= threshold) hits.add(RagHit(index.chunks[i], score));
  }
  hits.sort((a, b) {
    final c = b.score.compareTo(a.score);
    return c == 0 ? a.chunk.id.compareTo(b.chunk.id) : c;
  });
  return hits.take(topK).toList(growable: false);
}

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/rag/contracts.dart';
import '../../core/rag/models.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';

final class JsonlRagRepository implements RagRepository {
  const JsonlRagRepository(this.storage);
  final JsonlStreamStorage storage;
  String _key(String project, String corpus, String kind) =>
      ragHash(jsonEncode([project, corpus, kind]));

  Future<List<Map<String, dynamic>>> _read(String key) async {
    final stream = await storage.read(key);
    if (stream == null) return [];
    final bytes = await stream.fold<List<int>>([], (a, b) => a..addAll(b));
    return compute(_decode, bytes);
  }

  @override
  Future<List<RagDocument>> documents(String project, String corpus) async {
    final rows = await _read(_key(project, corpus, 'documents'));
    return rows.map(RagDocument.fromJson).toList(growable: false);
  }

  @override
  Future<void> saveDocuments(
    String project,
    String corpus,
    List<RagDocument> docs,
  ) async {
    if (docs.map((d) => d.id).toSet().length != docs.length) {
      throw const FormatException('Duplicate documents');
    }
    for (final doc in docs) {
      if (doc.pdfBase64 != null) {
        final key = _key(project, corpus, 'pdf:${doc.pdfHash}');
        if (await storage.read(key) == null) {
          await storage.publish(
            key,
            encodeRagJsonl([
              {'pdf': doc.pdfBase64, 'hash': doc.pdfHash},
            ]),
          );
        }
      }
    }
    final bytes = await compute(
      encodeRagJsonl,
      docs.map((d) => d.toJson(includePdf: false)).toList(),
    );
    await storage.publish(_key(project, corpus, 'documents'), bytes);
  }

  @override
  Future<RagIndex?> loadIndex(
    String project,
    String corpus,
    ChunkStrategy strategy,
  ) async {
    final rows = await _read(_key(project, corpus, strategy.name));
    if (rows.isEmpty) return null;
    if (rows.length != 1 || rows.single['type'] != 'active_index') {
      throw const FormatException('Invalid active index pointer');
    }
    final index = await loadGeneration(
      project,
      corpus,
      rows.single['generation'] as String,
    );
    if (index == null || index.strategy != strategy) {
      throw const FormatException('Missing active index generation');
    }
    return index;
  }

  @override
  Future<RagIndex?> loadGeneration(
    String project,
    String corpus,
    String generation,
  ) async {
    final rows = await _read(_key(project, corpus, 'generation:$generation'));
    if (rows.isEmpty) return null;
    final index = await compute(_loadIndex, rows);
    if (index.generation != generation) {
      throw const FormatException('Generation mismatch');
    }
    return index;
  }

  @override
  Future<List<int>?> originalPdf(
    String project,
    String corpus,
    RagDocument doc,
  ) async {
    if (doc.pdfHash == null) return null;
    final rows = await _read(_key(project, corpus, 'pdf:${doc.pdfHash}'));
    if (rows.length != 1 ||
        rows.single['hash'] != doc.pdfHash ||
        ragHash(rows.single['pdf'] as String) != doc.pdfHash) {
      throw const FormatException('Missing or corrupt original PDF');
    }
    return base64Decode(rows.single['pdf'] as String);
  }

  @override
  Future<void> publishIndex(
    String project,
    String corpus,
    RagIndex index,
  ) async {
    final bytes = await compute(encodeRagJsonl, index.jsonlRows);
    // Immutable generations are kept independently of the active pointer.
    await storage.publish(
      _key(project, corpus, 'generation:${index.generation}'),
      bytes,
    );
    await storage.publish(
      _key(project, corpus, index.strategy.name),
      encodeRagJsonl([
        {'type': 'active_index', 'generation': index.generation},
      ]),
    );
  }
}

List<Map<String, dynamic>> _decode(List<int> bytes) {
  final text = utf8.decode(bytes);
  if (!text.endsWith('\n')) throw const FormatException('Incomplete JSONL');
  final lines = text.substring(0, text.length - 1).split('\n');
  final footer = jsonDecode(lines.removeLast()) as Map;
  final payload = lines.isEmpty ? '' : '${lines.join('\n')}\n';
  if (footer['type'] != 'end' ||
      footer['version'] != 1 ||
      footer['hash'] != ragHash(payload)) {
    throw const FormatException('Corrupt RAG JSONL');
  }
  return lines.map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
}

RagIndex _loadIndex(List<Map<String, dynamic>> rows) {
  final manifest = rows.first;
  if (manifest['type'] != 'manifest') {
    throw const FormatException('Missing manifest');
  }
  final docs = <RagDocument>[];
  final chunks = <RagChunk>[];
  final vectors = <List<double>>[];
  for (final row in rows.skip(1)) {
    switch (row['type']) {
      case 'document':
        docs.add(RagDocument.fromJson(row['data'] as Map<String, dynamic>));
      case 'chunk':
        chunks.add(RagChunk.fromJson(row['data'] as Map<String, dynamic>));
        vectors.add(
          normalizedRagVector(
            (row['vector'] as List).cast<num>(),
            manifest['dimension'] as int,
          ),
        );
      default:
        throw const FormatException('Unknown index record');
    }
  }
  if (manifest['count'] != chunks.length) {
    throw const FormatException('Chunk count mismatch');
  }
  return RagIndex(
    fingerprint: manifest['fingerprint'] as String,
    dimension: manifest['dimension'] as int,
    strategy: ChunkStrategy.values.byName(manifest['strategy'] as String),
    chunks: chunks,
    vectors: vectors,
    documents: docs,
    elapsedMs: manifest['elapsed_ms'] as int,
    generation: manifest['generation'] as String,
  );
}

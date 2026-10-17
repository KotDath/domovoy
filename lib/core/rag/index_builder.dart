import 'dart:math';

import '../llm/cancellation.dart';
import 'chunking.dart';
import 'contracts.dart';
import 'models.dart';

/// Shared tokenizer/chunker/embedding pipeline. Cache identity includes content,
/// chunk configuration, model fingerprint and the caller's revision scope.
Future<RagIndex> buildRagIndex({
  required RagModelProvider models,
  required RagModelInfo model,
  required List<RagDocument> documents,
  required ChunkStrategy strategy,
  required CancellationToken cancellation,
  String revisionScope = '',
  void Function(String stage, int done, int total)? progress,
}) async {
  final clock = Stopwatch()..start();
  final chunks = <RagChunk>[];
  final chunker = RagChunker(models);
  for (var i = 0; i < documents.length; i++) {
    progress?.call('chunking', i, documents.length);
    chunks.addAll(await chunker.split(documents[i], strategy, cancellation));
  }
  final vectors = <List<double>>[];
  for (var start = 0; start < chunks.length; start += 8) {
    checkRagCancellation(cancellation.isCancelled);
    progress?.call('embedding', start, chunks.length);
    vectors.addAll(
      await models.embed(
        chunks
            .sublist(start, min(start + 8, chunks.length))
            .map((c) => c.text)
            .toList(),
        model,
        cancellation,
      ),
    );
  }
  checkRagCancellation(cancellation.isCancelled);
  return RagIndex(
    fingerprint: model.fingerprint,
    dimension: model.dimension,
    strategy: strategy,
    chunks: chunks,
    vectors: vectors,
    documents: documents,
    elapsedMs: clock.elapsedMilliseconds,
    generation: ragIndexIdentity(documents, model, strategy, revisionScope),
  );
}

String ragIndexIdentity(
  List<RagDocument> docs,
  RagModelInfo model,
  ChunkStrategy strategy,
  String scope,
) => ragHash(
  '$scope|v1-384-64|${strategy.name}|${model.fingerprint}|${model.dimension}|'
  '${docs.map((d) => '${d.source}:${d.revision}').join('|')}',
);

import 'dart:math';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/retrieval.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';
import '../../support/rag_fakes.dart';

final class _Rewrite implements RagQueryRewriter {
  @override
  Future<RagRewriteResult> rewrite(
    String original,
    CancellationToken token,
  ) async => const RagRewriteResult(query: 'rewritten query');
}

final class _Reranker implements RagReranker {
  String? query;
  bool badIds = false;
  int calls = 0;
  @override
  Future<RagRerankerInfo> rerankerInfo(CancellationToken token) async =>
      const RagRerankerInfo(fingerprint: 'rank-v1', scale: 'bge_raw_logit');
  @override
  Future<RagRerankResult> rerank(
    String query,
    List<RagHit> hits,
    RagRerankerInfo model,
    CancellationToken token,
  ) async {
    this.query = query;
    calls++;
    return RagRerankResult({
      for (var i = 0; i < hits.length; i++)
        badIds ? 'wrong-$i' : hits[i].chunk.id: i / 2,
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '20→threshold/dedup/top5; real rerank order uses original intent and distinct scale',
    () async {
      final repo = JsonlRagRepository(FakeMemoryJsonlStorage());
      final doc = RagDocument(
        source: 'facts.md',
        title: 'Facts',
        text: 'x' * 500,
      );
      final chunks = [
        for (var i = 0; i < 21; i++)
          RagChunk(
            documentId: doc.id,
            documentRevision: doc.revision,
            source: doc.source,
            title: doc.title,
            section: 'Facts',
            start: i == 1 ? 2 : i * 20,
            end: i == 1 ? 22 : i * 20 + 20,
            text: 'x' * 20,
            strategy: ChunkStrategy.fixed,
            tokens: 20,
            ordinal: i,
          ),
      ];
      await repo.saveDocuments('default', 'domovoy', [doc]);
      await repo.publishIndex(
        'default',
        'domovoy',
        RagIndex(
          fingerprint: 'fake-v1',
          dimension: 2,
          strategy: ChunkStrategy.fixed,
          chunks: chunks,
          documents: [doc],
          vectors: [
            for (var i = 0; i < 21; i++)
              [0.99 - i * 0.015, sqrt(1 - pow(0.99 - i * 0.015, 2))],
          ],
          elapsedMs: 1,
          generation: 'generation-test',
        ),
      );
      final ranker = _Reranker();
      final coordinator = RagTurnCoordinator(
        repository: repo,
        models: FakeRagModels(),
        reranker: ranker,
      );
      RagTurnRequest request(
        RagProtocol mode, {
        double dense = 0.85,
        double rank = 0,
        String? fingerprint,
        String? corpusHash,
        String? embeddingFingerprint,
        ChunkStrategy? strategy,
      }) => RagTurnRequest(
        id: 'r',
        project: 'default',
        session: 's',
        query: 'original query',
        corpus: 'domovoy',
        strategy: ChunkStrategy.fixed,
        protocol: mode,
        contextByteBudget: 24000,
        retrieval: RagRetrievalConfig(
          denseThreshold: dense,
          rerankThreshold: rank,
          expectedRerankerFingerprint: fingerprint,
          corpusHash: corpusHash,
          embeddingFingerprint: embeddingFingerprint,
          strategy: strategy,
        ),
      );
      final token = CancellationSource().token;
      final raw = await coordinator.prepare(request(RagProtocol.m1), token);
      expect(raw.candidates, hasLength(5));
      expect(raw.evidence, hasLength(5));
      expect((raw.toJson()['retrieval_config'] as Map)['candidate_limit'], 5);
      final filtered = await coordinator.prepare(
        request(RagProtocol.m2),
        token,
      );
      expect(filtered.candidates, hasLength(20));
      expect(
        (filtered.toJson()['retrieval_config'] as Map)['candidate_limit'],
        20,
      );
      expect(filtered.evidence, hasLength(5));
      expect(filtered.exclusions[chunks[1].id], 'duplicate_overlap');
      expect(
        filtered.exclusions.values,
        containsAll(['dense_threshold', 'final_top_k']),
      );
      final empty = await coordinator.prepare(
        request(RagProtocol.m2, dense: 1),
        token,
      );
      expect(empty.evidence, isEmpty);
      expect(
        empty.exclusions.values.every((r) => r == 'dense_threshold'),
        true,
      );
      final ranked = await coordinator.prepare(
        request(RagProtocol.m4, rank: 9.5),
        token,
        rewriter: _Rewrite(),
      );
      expect(ranked.candidates, hasLength(20));
      expect(ranked.evidence.single.chunk.id, chunks[19].id);
      expect(ranker.query, 'original query');
      expect(ranked.rewrittenQuery, 'rewritten query');
      expect(ranked.rerankerScale, 'bge_raw_logit');
      final row = (ranked.toJson()['candidates'] as List).last as Map;
      expect(row['dense_rank'], 20);
      expect(row['rerank_rank'], 1);
      await expectLater(
        coordinator.prepare(
          request(RagProtocol.m4, fingerprint: 'other'),
          token,
          rewriter: _Rewrite(),
        ),
        throwsStateError,
      );
      expect(ranker.calls, 1);
      for (final stale in [
        request(RagProtocol.m2, corpusHash: 'changed'),
        request(RagProtocol.m2, embeddingFingerprint: 'changed'),
        request(RagProtocol.m2, strategy: ChunkStrategy.structure),
      ]) {
        await expectLater(coordinator.prepare(stale, token), throwsStateError);
      }
      ranker.badIds = true;
      await expectLater(
        coordinator.prepare(
          request(RagProtocol.m4),
          token,
          rewriter: _Rewrite(),
        ),
        throwsFormatException,
      );
    },
  );
}

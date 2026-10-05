import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/retrieval.dart';
import 'package:domovoy/core/rag/task_state.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';
import '../../support/rag_fakes.dart';
import '../../support/rag_grounding_fixture.dart';
import '../../support/rag_task_state_fixture.dart';

final class _Rewrite implements RagQueryRewriter {
  final queries = <String>[];
  @override
  Future<RagRewriteResult> rewrite(
    String original,
    CancellationToken token,
  ) async {
    queries.add(original);
    return RagRewriteResult(query: original);
  }
}

final class _Rank implements RagReranker {
  final queries = <String>[];
  @override
  Future<RagRerankerInfo> rerankerInfo(CancellationToken token) async =>
      const RagRerankerInfo(fingerprint: 'rank', scale: 'bge_raw_logit');
  @override
  Future<RagRerankResult> rerank(
    String query,
    List<RagHit> candidates,
    RagRerankerInfo model,
    CancellationToken token,
  ) async {
    queries.add(query);
    return RagRerankResult({for (final c in candidates) c.chunk.id: 1});
  }
}

void main() {
  test(
    'pinned state-free cutoffs never silently score state-augmented queries',
    () async {
      final f = RagGroundingFixture();
      final repo = JsonlRagRepository(FakeMemoryJsonlStorage());
      await repo.saveDocuments('p', 'domovoy', [f.document]);
      await repo.publishIndex(
        'p',
        'domovoy',
        RagIndex(
          fingerprint: 'fake-v1',
          dimension: 2,
          strategy: ChunkStrategy.fixed,
          chunks: [f.chunk],
          documents: [f.document],
          vectors: [
            [1, 0],
          ],
          elapsedMs: 1,
          generation: 'g',
        ),
      );
      final models = FakeRagModels(), rewrite = _Rewrite(), rank = _Rank();
      final coordinator = RagTurnCoordinator(
        repository: repo,
        models: models,
        reranker: rank,
      );
      final state = changedTaskState(
        RagTaskState(project: 'p', session: 's'),
        '08:30',
      );
      RagTurnRequest request(RagProtocol p, String profile) => RagTurnRequest(
        id: 'r',
        project: 'p',
        session: 's',
        query: 'Current question?',
        corpus: 'domovoy',
        strategy: ChunkStrategy.fixed,
        protocol: p,
        contextByteBudget: 10000,
        taskState: state,
        retrieval: RagRetrievalConfig(
          denseThreshold: -1,
          rerankThreshold: -100,
          calibrationId: profile,
        ),
      );
      final token = CancellationSource().token;
      final m2 = await coordinator.prepare(
        request(RagProtocol.m2, 'pinned'),
        token,
      );
      expect(models.queryInputs.single, 'Current question?');
      expect(m2.toJson()['retrieval_query'], 'Current question?');
      for (final p in [RagProtocol.m3, RagProtocol.m4]) {
        await expectLater(
          coordinator.prepare(request(p, 'pinned'), token, rewriter: rewrite),
          throwsStateError,
        );
        expect(rewrite.queries, isEmpty);
      }
      await coordinator.prepare(
        request(RagProtocol.m4, 'manual-experiment'),
        token,
        rewriter: rewrite,
      );
      expect(rewrite.queries.single, contains('08:30'));
      expect(rank.queries.single, 'Current question?');
    },
  );
}

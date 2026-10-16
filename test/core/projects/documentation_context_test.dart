import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/projects/documentation_context.dart';
import 'package:domovoy/core/projects/project_context.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/memory_jsonl_storage.dart';
import '../../support/rag_fakes.dart';

void main() {
  test(
    'root README anchors supplement real dense selection without invented dense scores',
    () async {
      final repo = JsonlRagRepository(FakeMemoryJsonlStorage());
      final docs = [
        RagDocument(
          source: 'README.rst',
          title: 'README.rst',
          text: 'Project overview with real introductory content.',
        ),
        for (var i = 0; i < 5; i++)
          RagDocument(
            source: 'docs/section$i.md',
            title: 'Section $i',
            text: '# Reference\nTODO',
          ),
      ];
      final chunks = [
        for (final doc in docs)
          RagChunk(
            documentId: doc.id,
            documentRevision: doc.revision,
            source: doc.source,
            title: doc.title,
            section: doc.title,
            start: 0,
            end: doc.text.length,
            text: doc.text,
            strategy: ChunkStrategy.structure,
            tokens: 10,
            ordinal: 0,
          ),
      ];
      await repo.saveDocuments('p', projectDocumentationCorpus, docs);
      await repo.publishIndex(
        'p',
        projectDocumentationCorpus,
        RagIndex(
          fingerprint: 'fake-v1',
          dimension: 2,
          strategy: ChunkStrategy.structure,
          chunks: chunks,
          vectors: [
            [0, 1],
            for (var i = 0; i < 5; i++) [1, 0],
          ],
          documents: docs,
          elapsedMs: 1,
          generation: 'frozen-generation',
        ),
      );
      final prepared = await prepareProjectDocumentationContext(
        RagTurnCoordinator(repository: repo, models: FakeRagModels()),
        const RagTurnRequest(
          id: 'run',
          project: 'p',
          session: 's',
          query: 'Explain structure',
          corpus: projectDocumentationCorpus,
          strategy: ChunkStrategy.structure,
          protocol: RagProtocol.m1,
          contextByteBudget: 32000,
        ),
        CancellationSource().token,
      );
      expect(prepared.turn.evidence, hasLength(5));
      expect(prepared.overview.single.chunk.source, 'README.rst');
      expect(prepared.context, contains('real introductory content'));
      final rows = prepared.toJson()['candidates'] as List;
      final overview = rows.singleWhere(
        (r) => r['retrieval_kind'] == 'project_readme_overview',
      );
      expect(overview['cosine'], isNull);
      expect(overview['dense_rank'], isNull);
      expect(overview['sent'], isTrue);
      expect(prepared.turn.generation, 'frozen-generation');
    },
  );
}

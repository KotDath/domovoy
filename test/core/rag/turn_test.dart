import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/knowledge/application/knowledge_controller.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';
import '../../support/rag_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'one frozen generation and exact bounded evidence, M0 retrieves nothing',
    () async {
      final repo = JsonlRagRepository(FakeMemoryJsonlStorage());
      final models = FakeRagModels();
      final knowledge = KnowledgeController(
        repository: repo,
        models: models,
        importer: FakeRagImporter(),
      );
      addTearDown(knowledge.dispose);
      await knowledge.addText(
        'Facts',
        'Facts 😀\nMemory belongs to the project.',
      );
      await knowledge.buildIndex();
      final coordinator = RagTurnCoordinator(repository: repo, models: models);
      RagTurnRequest request(RagProtocol protocol, int budget) =>
          RagTurnRequest(
            id: 'request',
            project: 'default',
            session: 'chat',
            query: 'memory?',
            corpus: 'domovoy',
            strategy: ChunkStrategy.structure,
            protocol: protocol,
            contextByteBudget: budget,
          );
      final token = CancellationSource().token;
      final turn = await coordinator.prepare(
        request(RagProtocol.m1, 10000),
        token,
      );
      expect(turn.generation, knowledge.activeIndex!.generation);
      expect(
        turn.evidence.single.chunk.text,
        'Facts 😀\nMemory belongs to the project.',
      );
      expect(turn.context, contains(turn.evidence.single.chunk.id));
      final bounded = await coordinator.prepare(
        request(RagProtocol.m1, 1),
        token,
      );
      expect(bounded.evidence, isEmpty);
      expect(bounded.candidates, hasLength(1));
      expect(bounded.exclusions.values.single, 'context_budget');
      final m0 = await coordinator.prepare(
        request(RagProtocol.m0, 10000),
        token,
      );
      expect(m0.generation, isNull);
      expect(m0.context, isEmpty);
      final cancelled = CancellationSource()..cancel();
      await expectLater(
        coordinator.prepare(request(RagProtocol.m1, 10000), cancelled.token),
        throwsA(isA<RagCancelled>()),
      );
      await knowledge.addText('New', 'new content');
      await expectLater(
        coordinator.prepare(request(RagProtocol.m1, 10000), token),
        throwsStateError,
      );
      // Already frozen evidence still resolves to its original document revision.
      expect(
        (await repo.loadGeneration(
          'default',
          'domovoy',
          turn.generation!,
        ))!.documents,
        hasLength(1),
      );
    },
  );
}

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/features/knowledge/presentation/rag_chat_bar.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/agent_harness.dart';
import '../../../support/memory_jsonl_storage.dart';
import '../../../support/rag_fakes.dart';

void main() {
  testWidgets(
    'project README overview is labelled separately and expands with revision',
    (tester) async {
      final runtime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: [],
        ),
      );
      final storage = FakeMemoryJsonlStorage();
      final controller = RagChatController(
        coordinator: RagTurnCoordinator(
          repository: JsonlRagRepository(storage),
          models: FakeRagModels(),
        ),
        traces: JsonlRagTraceRepository(storage),
        registry: runtime.registry,
      );
      addTearDown(controller.dispose);
      addTearDown(runtime.close);
      final doc = RagDocument(
        source: 'README.md',
        title: 'README.md',
        text: 'Actual overview',
      );
      final chunk = RagChunk(
        documentId: doc.id,
        documentRevision: doc.revision,
        source: doc.source,
        title: doc.title,
        section: 'Overview',
        start: 0,
        end: doc.text.length,
        text: doc.text,
        strategy: ChunkStrategy.structure,
        tokens: 3,
        ordinal: 0,
      );
      controller.history = [
        {
          'id': 'project-help',
          'protocol': 'm1',
          'query': 'Explain this project',
          'scenario': 'project_help',
          'candidates': [
            {
              'chunk': chunk.toJson(),
              'sent': true,
              'dense_rank': null,
              'cosine': null,
              'retrieval_kind': 'project_readme_overview',
            },
          ],
        },
      ];
      await tester.pumpWidget(
        MaterialApp(home: RagInspectorPage(controller: controller)),
      );
      final card = find.textContaining('README · обзор проекта');
      await tester.scrollUntilVisible(
        card,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.textContaining('revision ${doc.revision}'), findsOneWidget);
      expect(find.textContaining('Actual overview'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.textContaining('revision ${doc.revision}'), findsNothing);
    },
  );
}

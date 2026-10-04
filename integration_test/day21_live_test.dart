import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/features/knowledge/application/knowledge_controller.dart';
import 'package:domovoy/features/knowledge/presentation/knowledge_page.dart';
import 'package:domovoy/infrastructure/rag/document_importer.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/model_service_client.dart';
import 'package:domovoy/infrastructure/rag/rag_storage_factory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

/// Opt-in real-device check: requires the pinned live gateway on loopback:8765.
/// No credentials, canned vectors or answers. Not part of fake unit tests.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native knowledge UI imports, indexes, searches and reopens both generations',
    (tester) async {
      final client = http.Client();
      final repo = JsonlRagRepository(createRagStorage()!);
      final models = RagModelServiceClient(
        client,
        Uri.parse('http://127.0.0.1:8765'),
      );
      final c = KnowledgeController(
        repository: repo,
        models: models,
        importer: NativeRagDocumentImporter(client),
      );
      addTearDown(client.close);
      addTearDown(c.dispose);
      await c.initialize(
        projectId: 'day21-live-${DateTime.now().microsecondsSinceEpoch}',
      );
      await tester.pumpWidget(MaterialApp(home: KnowledgePage(controller: c)));
      await tester.tap(find.byKey(const ValueKey('knowledge.demo')));
      await tester.pump();
      await _idle(tester, c);
      expect(c.error, isNull);
      expect(c.documents.length, 12);
      c.selectStrategy(ChunkStrategy.fixed);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('knowledge.index')));
      await tester.pump();
      await _idle(tester, c);
      expect(c.error, isNull);
      final fixed = c.activeIndex!;
      expect(fixed.dimension, 1024);
      expect(fixed.chunks.every((x) => x.tokens <= 384), isTrue);
      c.selectStrategy(ChunkStrategy.structure);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('knowledge.index')));
      await tester.pump();
      await _idle(tester, c);
      expect(c.error, isNull);
      expect(c.indexes.length, 2);
      final structural = c.activeIndex!;
      expect(
        structural.chunks.map((x) => x.id).toList(),
        isNot(fixed.chunks.map((x) => x.id).toList()),
      );
      await c.search('Какие слои памяти есть в Domovoy?');
      expect(c.error, isNull);
      expect(c.hits.length, 5);
      expect(c.hits.first.score.isFinite, isTrue);
      await c.initialize(projectId: c.project);
      expect(c.indexes[ChunkStrategy.fixed]!.generation, fixed.generation);
      expect(
        c.indexes[ChunkStrategy.structure]!.generation,
        structural.generation,
      );
      await tester.pump();
      debugPrint(
        'DAY21_LIVE fixed=${fixed.chunks.length} structure=${structural.chunks.length} dimensions=${fixed.dimension} persisted=true search=5',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<void> _idle(WidgetTester tester, KnowledgeController c) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (c.busy && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  expect(c.busy, isFalse, reason: 'real service operation timed out');
}

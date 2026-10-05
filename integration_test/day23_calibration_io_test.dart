// Native Linux evaluation, intentionally separate from deterministic unit tests.
// Golden facts stay in this host harness and never enter the model request.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/calibration.dart';
import 'package:domovoy/core/rag/retrieval.dart';
import 'package:domovoy/infrastructure/rag/cloud_query_rewriter.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/chat/presentation/chat_workspace_page.dart';
import 'package:domovoy/features/knowledge/application/knowledge_controller.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart';
import 'package:domovoy/infrastructure/rag/document_importer.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:domovoy/infrastructure/rag/model_service_client.dart';
import 'package:domovoy/infrastructure/rag/rag_storage_factory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real dev calibration on eight independent questions',
    (tester) async {
      expect(
        Platform.isLinux,
        isTrue,
        reason: 'This file is the native Linux evaluation harness',
      );
      final client = http.Client();
      final sessions = JsonlAgentSessionStore(
        storage: JsonlFilesystemStreamStorage(
          applicationSupportDirectoryResolver: getApplicationSupportDirectory,
          namespaceDirectoryName: 'rag-eval-sessions-v1',
        ),
      );
      final stack = buildProductionAgentStack(
        httpClient: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(),
          readEnvironment: (name) => Platform.environment[name],
        ),
        repository: sessions,
        catalog: sessions,
      );
      addTearDown(stack.runtime.close);
      addTearDown(client.close);
      final storage = createRagStorage()!;
      final repository = JsonlRagRepository(storage);
      final models = RagModelServiceClient(
        client,
        Uri.parse('http://127.0.0.1:8765'),
      );
      final knowledge = KnowledgeController(
        repository: repository,
        models: models,
        importer: NativeRagDocumentImporter(client),
      );
      final project = 'day23-dev-${DateTime.now().microsecondsSinceEpoch}';
      await knowledge.initialize(projectId: project);
      await knowledge.loadDemoCorpus();
      for (final strategy in [ChunkStrategy.fixed]) {
        knowledge.selectStrategy(strategy);
        await knowledge.buildIndex();
        expect(knowledge.error, isNull);
      }
      addTearDown(knowledge.dispose);
      final traceRepository = JsonlRagTraceRepository(storage);
      final rag = RagChatController(
        coordinator: RagTurnCoordinator(repository: repository, models: models),
        traces: traceRepository,
        registry: stack.registry,
      );
      addTearDown(rag.dispose);
      final definition = AgentDefinition(
        id: AgentId('rag-evaluation'),
        name: 'RAG evaluation',
        systemPrompt: '',
        model: BuiltInLlmCatalog.deepSeekFlashModel.ref,
        generation: LlmGenerationConfig(
          reasoningMode: ReasoningMode.disabled,
          temperature: 0,
          maxOutputTokens: 2048,
        ),
      );
      final chat = ChatWorkspaceController(
        runtime: stack.runtime,
        definition: definition,
        catalog: sessions,
        repository: sessions,
        registry: stack.registry,
        runPreparer: rag,
      );
      addTearDown(chat.dispose);
      await tester.runAsync(chat.initialize);
      await tester.pumpWidget(
        MaterialApp(
          theme: DomovoyTheme.light(),
          darkTheme: DomovoyTheme.dark(),
          home: ChatWorkspacePage(controller: chat, ragChat: rag),
        ),
      );
      final output = File(
        const String.fromEnvironment(
          'RAG_DEV_OUTPUT',
          defaultValue:
              '/home/kotdath/Videos/domovoy/evidence/day-23/dev-samples.jsonl',
        ),
      );
      expect(
        output.existsSync(),
        false,
        reason: 'Preserve original calibration runs',
      );
      output.parent.createSync(recursive: true);
      final devText = File('eval/rag/dev_questions.jsonl').readAsStringSync();
      final dev = devText
          .trim()
          .split('\n')
          .map((l) => jsonDecode(l) as Map)
          .toList();
      expect(dev, hasLength(8));
      final token = CancellationSource().token;
      final rankInfo = await models.rerankerInfo(token);
      final coordinator = RagTurnCoordinator(
        repository: repository,
        models: models,
        reranker: models,
      );
      final rewriter = CloudRagQueryRewriter(
        registry: stack.registry,
        model: definition.model,
        beforeRequest: (request) async =>
            File('${output.path}.rewrite-requests.jsonl').writeAsStringSync(
              '${jsonEncode(request)}\n',
              mode: FileMode.append,
              flush: true,
            ),
      );
      final denseSamples = <RagCalibrationSample>[];
      final rankSamples = <RagCalibrationSample>[];
      Set<String> relevant(Map question, List<RagHit> hits) => {
        for (final hit in hits)
          if ((question['evidence_units'] as List).any((unit) {
            if (unit['document_id'] != hit.chunk.documentId ||
                unit['document_revision'] != hit.chunk.documentRevision) {
              return false;
            }
            final start = unit['start_utf16'] as int,
                end = unit['end_utf16'] as int;
            final overlap = max(
              0,
              min(end, hit.chunk.end) - max(start, hit.chunk.start),
            );
            return overlap / (end - start) >= 0.5;
          }))
            hit.chunk.id,
      };
      for (final question in dev) {
        RagTurnRequest request(RagProtocol protocol) => RagTurnRequest(
          id: '${question['id']}',
          project: project,
          session: 'dev-${question['id']}',
          query: question['question'] as String,
          corpus: 'domovoy',
          strategy: ChunkStrategy.fixed,
          protocol: protocol,
          contextByteBudget: 24000,
          retrieval: const RagRetrievalConfig(
            denseThreshold: -1,
            calibrationId: 'dev-unfiltered',
          ),
        );
        final raw = await tester.runAsync(
          () => coordinator.prepare(request(RagProtocol.m2), token),
        );
        final rewrite = await tester.runAsync(
          () => coordinator.prepare(
            request(RagProtocol.m3),
            token,
            rewriter: rewriter,
          ),
        );
        final scores = await tester.runAsync(
          () => models.rerank(
            question['question'] as String,
            rewrite!.candidates,
            rankInfo,
            token,
          ),
        );
        final rawRelevant = relevant(question, raw!.candidates);
        final rewrittenRelevant = relevant(question, rewrite!.candidates);
        for (final pair in [(raw, rawRelevant), (rewrite, rewrittenRelevant)]) {
          denseSamples.add(
            RagCalibrationSample(
              answerable: question['answerable'] as bool,
              candidates: pair.$1.candidates,
              relevantIds: pair.$2,
              scores: {for (final h in pair.$1.candidates) h.chunk.id: h.score},
            ),
          );
        }
        rankSamples.add(
          RagCalibrationSample(
            answerable: question['answerable'] as bool,
            candidates: rewrite.candidates,
            relevantIds: rewrittenRelevant,
            scores: scores!.scores,
          ),
        );
        output.writeAsStringSync(
          '${jsonEncode({'id': question['id'], 'answerable': question['answerable'], 'question': question['question'], 'raw': raw.toJson(), 'rewritten': rewrite.toJson(), 'reranker_scores': scores.scores, 'reranker_usage': scores.usage, 'raw_relevant_ids': rawRelevant.toList(), 'rewritten_relevant_ids': rewrittenRelevant.toList()})}\n',
          mode: FileMode.append,
          flush: true,
        );
        debugPrint(
          'DAY23_DEV ${question['id']} pools=${raw.candidates.length}/${rewrite.candidates.length}',
        );
      }
      final dense = calibrateRagThreshold(denseSamples),
          rank = calibrateRagThreshold(rankSamples);
      final config = {
        'version': 1,
        'dev_hash': ragHash(devText),
        'strategy': 'fixed',
        'corpus_hash': ragHash(
          jsonEncode([
            for (final d in knowledge.documents) '${d.id}:${d.revision}',
          ]),
        ),
        'embedding_fingerprint': knowledge.activeIndex!.fingerprint,
        'reranker_fingerprint': rankInfo.fingerprint,
        'score_scale': rankInfo.scale,
        'rewrite_version': 'query-rewrite-v1',
        'rewrite_model': definition.model.toJson(),
        'rewrite_sampling': {
          'temperature': 0,
          'max_output_tokens': 512,
          'reasoning': 'disabled',
        },
        'dense': dense,
        'rerank': rank,
        'relevance_label': 'agent-selected canonical spans; >=50% span overlap',
        'created_at_utc': DateTime.now().toUtc().toIso8601String(),
      };
      File('${output.path}.profile.json').writeAsStringSync(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({...config, 'id': ragHash(jsonEncode(config))}),
        flush: true,
      );
      expect(dense['known_hit'], greaterThan(0));
      expect(rank['known_hit'], greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

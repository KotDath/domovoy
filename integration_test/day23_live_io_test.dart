// Native Linux evaluation, intentionally separate from deterministic unit tests.
// Golden facts stay in this host harness and never enter the model request.
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/evidence_coverage.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/chat/presentation/chat_workspace_page.dart';
import 'package:domovoy/features/knowledge/application/knowledge_controller.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart';
import 'package:domovoy/infrastructure/rag/document_importer.dart';
import 'package:domovoy/infrastructure/rag/cloud_query_rewriter.dart';
import 'package:domovoy/core/rag/retrieval.dart';
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
    'real frozen-calibration M1–M4 ablations on all ten questions',
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
      final project = 'day23-eval-${DateTime.now().microsecondsSinceEpoch}';
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
        coordinator: RagTurnCoordinator(
          repository: repository,
          models: models,
          reranker: models,
        ),
        defaultRetrieval: RagRetrievalConfig.fromProfile(
          jsonDecode(File('eval/rag/calibration.json').readAsStringSync())
              as Map<String, dynamic>,
        ),
        queryRewriterFactory: (model, beforeRequest, afterResult) =>
            CloudRagQueryRewriter(
              registry: stack.registry,
              model: model,
              beforeRequest: beforeRequest,
              afterResult: afterResult,
            ),
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
      final golden = File('eval/rag/golden_questions.jsonl')
          .readAsLinesSync()
          .where((l) => l.isNotEmpty)
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();
      expect(golden, hasLength(10));
      final output = File(
        const String.fromEnvironment(
          'RAG_EVAL_OUTPUT',
          defaultValue:
              '/home/kotdath/Videos/domovoy/evidence/day-22/evaluation.jsonl',
        ),
      );
      output.parent.createSync(recursive: true);
      expect(
        output.existsSync(),
        isFalse,
        reason: 'Preserve earlier runs; select a new output path',
      );
      final results = <Map<String, Object?>>[];
      for (final variant in ['m1', 'm2', 'm3', 'm4']) {
        rag.configure(
          enabled: true,
          protocol: RagProtocol.values.byName(variant),
          neutral: true,
          strategy: ChunkStrategy.fixed,
        );
        for (final question in golden) {
          final created = await tester.runAsync(
            () => chat.createChat(projectId: ProjectId(project)),
          );
          expect(created!.isSuccess, isTrue, reason: chat.state.error?.message);
          await tester.pump();
          final session = chat.state.selectedSession!;
          expect(session.transcript.messages, isEmpty);
          final timer = Stopwatch()..start();
          final result = await tester.runAsync(
            () => chat.send(question['question'] as String),
          );
          await tester.pump();
          expect(result!.isSuccess, isTrue, reason: chat.state.error?.message);
          final traces = await traceRepository.list(project, session.id.value);
          final trace = traces.singleWhere((t) => t['protocol'] == variant);
          expect(traces, hasLength(variant == 'm3' || variant == 'm4' ? 2 : 1));
          expect(trace['request']['tools_count'], 0);
          expect(trace['neutral_evaluation'], true);
          final units = question['evidence_units'] as List;
          final candidates = trace['candidates'] as List;
          final covered = units
              .where((unit) => _covered(unit as Map, candidates))
              .length;
          final sentCovered = units
              .where(
                (unit) => _covered(
                  unit as Map,
                  candidates.where((c) => c['sent'] == true).toList(),
                ),
              )
              .length;
          final row = <String, Object?>{
            'variant': variant,
            'question_id': question['id'],
            'question': question['question'],
            'answerable': question['answerable'],
            'candidate_hit': covered > 0,
            'final_hit_at_5': sentCovered > 0,
            'evidence_units_total': units.length,
            'evidence_units_covered': covered,
            'sent_evidence_units_covered': sentCovered,
            'elapsed_ms': timer.elapsedMilliseconds,
            'trace': trace,
            'auxiliary_traces': traces
                .where((t) => t['protocol'] == 'query_rewrite')
                .toList(),
          };
          results.add(row);
          output.writeAsStringSync(
            '${jsonEncode(row)}\n',
            mode: FileMode.append,
            flush: true,
          );
          debugPrint(
            'DAY23_EVAL $variant ${question['id']} hit=${row['final_hit_at_5']} units=$covered/${units.length} ms=${timer.elapsedMilliseconds}',
          );
        }
      }
      expect(results, hasLength(40));
      final config = {
        'code_revision': const String.fromEnvironment(
          'RAG_EVAL_CODE_REVISION',
          defaultValue: 'working-tree',
        ),
        'project': project,
        'calibration': jsonDecode(
          File('eval/rag/calibration.json').readAsStringSync(),
        ),
        'generator': definition.model.toJson(),
        'generation': definition.generation.toJson(),
        'prompt_hash': ragHash(ragAnswerInstructions),
        'profile': 'neutral',
        'unrelated_memory': 'disabled',
        'tools': 'disabled',
        'sessions': 'fresh per question per variant',
        'provider_cache': 'not controlled',
        'server_model_revision': 'not exposed by provider',
        'corpus': [
          for (final doc in knowledge.documents)
            {
              'source': doc.source,
              'revision': doc.revision,
              'source_revision': doc.sourceRevision,
            },
        ],
        'indexes': {
          for (final e in knowledge.indexes.entries)
            e.key.name: {
              'generation': e.value.generation,
              'fingerprint': e.value.fingerprint,
              'chunks': e.value.chunks.length,
              'config': e.value.chunks.first.config,
            },
        },
      };
      File('${output.path}.config.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(config),
        flush: true,
      );
      // Reopen immutable traces and prove source text survives a fresh repository.
      final reopened = JsonlRagTraceRepository(storage);
      final selected = chat.state.selectedSession!;
      final historical = await reopened.list(project, selected.id.value);
      expect(
        historical.singleWhere(
          (t) => t['protocol'] == 'm4',
        )['completion']['accepted_message_id'],
        isNotNull,
      );
      debugPrint('DAY23_EVALUATION_COMPLETE ${output.path} count=40');
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

bool _covered(Map unit, List candidates) => ragEvidenceCoversSpan(
  documentId: unit['document_id'] as String,
  revision: unit['document_revision'] as String,
  start: unit['start_utf16'] as int,
  end: unit['end_utf16'] as int,
  chunks: candidates.map(
    (c) => RagChunk.fromJson(Map<String, dynamic>.from(c['chunk'] as Map)),
  ),
);

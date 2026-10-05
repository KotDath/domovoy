// Real Linux dialogue evaluation. Expected checks never enter model context.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/knowledge/application/knowledge_controller.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart';
import 'package:domovoy/infrastructure/rag/cloud_task_extractor.dart';
import 'package:domovoy/infrastructure/rag/document_importer.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_task_state_repository.dart';
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
    'real twelve-turn dialogues, restart and isolated tail replay',
    (tester) async {
      expect(Platform.isLinux, true);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Day 25 real-model evaluation')),
        ),
      );
      await tester.runAsync(() async {
        final client = http.Client();
        final sessions = JsonlAgentSessionStore(
          storage: JsonlFilesystemStreamStorage(
            applicationSupportDirectoryResolver: getApplicationSupportDirectory,
            namespaceDirectoryName: 'rag-day25-eval-sessions-v1',
          ),
        );
        final output = File(
          const String.fromEnvironment(
            'RAG_EVAL_OUTPUT',
            defaultValue:
                '/home/kotdath/Videos/domovoy/evidence/day-25/dialogues.jsonl',
          ),
        );
        expect(output.existsSync(), false, reason: 'Never overwrite evidence');
        output.parent.createSync(recursive: true);
        final scenarios =
            jsonDecode(
                  File('eval/rag/dialogue_scenarios.json').readAsStringSync(),
                )
                as Map;
        final repository = JsonlRagRepository(createRagStorage()!);
        final traces = JsonlRagTraceRepository(createRagStorage()!);
        final states = JsonlRagTaskStateRepository(
          createRagTaskStateStorage()!,
        );
        final models = RagModelServiceClient(
          client,
          Uri.parse('http://127.0.0.1:8765'),
        );
        final importer = NativeRagDocumentImporter(client);
        final credentials = DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(),
          readEnvironment: (key) => Platform.environment[key],
        );
        const code = String.fromEnvironment(
          'RAG_EVAL_CODE_REVISION',
          defaultValue: 'working-tree',
        );
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final config = <String, Object?>{
          'code_revision': code,
          'scenarios': scenarios,
          'runs': [],
          'provider_cache': 'not controlled',
          'server_model_revision': 'not exposed',
          'tools': 0,
          'profile': 'neutral',
          'shared_memory': 'disabled',
        };
        void write(Map<String, Object?> row) {
          output.writeAsStringSync(
            '${jsonEncode(row)}\n',
            mode: FileMode.append,
            flush: true,
          );
          debugPrint(
            'DAY25 ${row['scenario']} ${row['question_id']} accepted=${row['accepted']} state=${(row['state_after'] as Map?)?['revision']}',
          );
        }

        List<RagDocument>? papers;
        RagIndex? paperIndex;
        try {
          for (final scenario in scenarios['scenarios'] as List) {
            final project = 'day25-${scenario['id']}-$stamp';
            final knowledge = KnowledgeController(
              repository: repository,
              models: models,
              importer: importer,
            );
            await knowledge.initialize(projectId: project);
            await knowledge.loadDemoCorpus();
            knowledge.selectStrategy(ChunkStrategy.fixed);
            await knowledge.buildIndex();
            expect(knowledge.error, isNull);
            final fixedIndex = knowledge.indexes[ChunkStrategy.fixed]!;
            var env = _Env(
              client,
              credentials,
              sessions,
              repository,
              traces,
              states,
              models,
            );
            await env.chat.initialize();
            expect(
              (await env.chat.createChat(
                projectId: ProjectId(project),
              )).isSuccess,
              true,
            );
            final sessionId = env.chat.state.selectedId!;
            final runConfig = <String, Object?>{
              'scenario': scenario['id'],
              'project': project,
              'session': sessionId.value,
              'domovoy_generation': fixedIndex.generation,
              'restart': null,
            };
            (config['runs'] as List).add(runConfig);
            try {
              for (final question in scenario['questions'] as List) {
                if (question['restart_before'] == true) {
                  final before = await states.load(project, sessionId.value);
                  final transcript = env.chat.state.selectedSession!.transcript
                      .toJson();
                  await env.close();
                  env = _Env(
                    client,
                    credentials,
                    sessions,
                    repository,
                    traces,
                    JsonlRagTaskStateRepository(createRagTaskStateStorage()!),
                    models,
                  );
                  await env.chat.initialize();
                  expect(
                    (await env.chat.selectChat(sessionId)).isSuccess,
                    true,
                  );
                  await env.rag.attach(env.chat.state.selectedSession);
                  final reopened = env.rag.taskState!;
                  expect(reopened.toJson(), before.toJson());
                  expect(
                    env.chat.state.selectedSession!.transcript.toJson(),
                    transcript,
                  );
                  runConfig['restart'] = {
                    'before': before.toJson(),
                    'reloaded_before_new_model_request': reopened.toJson(),
                    'transcript_messages': env
                        .chat
                        .state
                        .selectedSession!
                        .transcript
                        .messages
                        .length,
                  };
                }
                if (question['corpus'] == 'arxiv' && paperIndex == null) {
                  papers = [];
                  for (final meta
                      in jsonDecode(
                            File(
                              'eval/rag/arxiv_sources.json',
                            ).readAsStringSync(),
                          )
                          as List) {
                    final id = meta['arxiv_id'] as String;
                    final file = File(
                      id.startsWith('2310')
                          ? const String.fromEnvironment(
                              'RAG_MEMGPT_PDF',
                              defaultValue:
                                  '/home/kotdath/Videos/domovoy/evidence/day-21/MemGPT-2310.08560v2.pdf',
                            )
                          : "${const String.fromEnvironment('RAG_PAPERS_DIR', defaultValue: '/home/kotdath/Downloads/domovoy-rag-papers')}/$id.pdf",
                    );
                    final bytes = file.readAsBytesSync();
                    expect(bytes.length, meta['bytes']);
                    expect(sha256.convert(bytes).toString(), meta['sha256']);
                    final pdf = await importer.extractPdf(
                      bytes,
                      meta['url'] as String,
                      meta['title'] as String,
                    );
                    expect(pdf.pageStarts.length, meta['pages']);
                    papers.add(
                      RagDocument(
                        source: pdf.source,
                        title: pdf.title,
                        text: pdf.text,
                        pageStarts: pdf.pageStarts,
                        pdfBase64: pdf.pdfBase64,
                        pdfSize: pdf.pdfSize,
                        sourceRevision: id,
                      ),
                    );
                  }
                  await repository.saveDocuments(project, 'arxiv', papers);
                  await knowledge.selectCorpus('arxiv');
                  await knowledge.buildIndex();
                  expect(knowledge.error, isNull);
                  paperIndex = knowledge.indexes[ChunkStrategy.fixed]!;
                  config['arxiv'] = {
                    'documents': papers
                        .map(
                          (d) => {
                            'source': d.source,
                            'source_revision': d.sourceRevision,
                            'revision': d.revision,
                            'pages': d.pageStarts.length,
                            'characters': d.text.length,
                            'pdf_bytes': d.pdfSize,
                          },
                        )
                        .toList(),
                    'generation': paperIndex.generation,
                    'chunks': paperIndex.chunks.length,
                    'fingerprint': paperIndex.fingerprint,
                  };
                } else if (question['corpus'] == 'arxiv') {
                  await repository.saveDocuments(project, 'arxiv', papers!);
                  await repository.publishIndex(project, 'arxiv', paperIndex!);
                  runConfig['arxiv_index'] =
                      'Published same validated immutable paper index; not a repeated build';
                }
                env.rag.configure(corpus: question['corpus'] as String);
                final beforeTraces = (await traces.list(
                  project,
                  sessionId.value,
                )).map((t) => t['id']).toSet();
                final beforeMessages =
                    env.chat.state.selectedSession!.transcript.messages.length;
                final watch = Stopwatch()..start();
                final result = await env.chat.send(
                  question['question'] as String,
                );
                final added = (await traces.list(
                  project,
                  sessionId.value,
                )).where((t) => !beforeTraces.contains(t['id'])).toList();
                final answers = added
                    .where((t) => t['protocol'] == 'm1')
                    .toList();
                final accepted = answers
                    .where(
                      (t) =>
                          (t['completion'] as Map?)?['accepted_message_id'] !=
                          null,
                    )
                    .toList();
                final after = await states.load(project, sessionId.value);
                final row = <String, Object?>{
                  'scenario': scenario['id'],
                  'question_id': question['id'],
                  'question': question['question'],
                  'corpus': question['corpus'],
                  'accepted': accepted.isNotEmpty,
                  'command_success': result.isSuccess,
                  'workspace_error': env.chat.state.error?.message,
                  'elapsed_ms': watch.elapsedMilliseconds,
                  'state_after': after.toJson(),
                  'messages_before': beforeMessages,
                  'transcript': env.chat.state.selectedSession!.transcript
                      .toJson(),
                  'traces': added,
                  'error': env.rag.error,
                };
                write(row);
                expect(
                  accepted,
                  hasLength(1),
                  reason: '${question['id']}: ${env.rag.error}',
                );
                expect(
                  env.chat.state.selectedSession!.transcript.messages.length,
                  beforeMessages + 2,
                );
                expect(accepted.single['request']['tools_count'], 0);
                expect(
                  accepted.single['task_state']['revision'],
                  after.revision,
                );
                expect(
                  added.where((t) => t['protocol'] == 'task_state_extraction'),
                  hasLength(1),
                );
                expect(
                  (await states.load(
                    'other-project-$stamp',
                    sessionId.value,
                  )).facts,
                  isEmpty,
                );
                expect(
                  (await states.load(project, 'other-chat-$stamp')).facts,
                  isEmpty,
                );
              }
              final originalTranscript = env
                  .chat
                  .state
                  .selectedSession!
                  .transcript
                  .toJson();
              final stateBeforeReplay = await states.load(
                project,
                sessionId.value,
              );
              final replays = await env.rag.replayLastQuestion(
                env.chat.state.selectedSession!,
                CancellationSource().token,
              );
              expect(replays, hasLength(2));
              for (final replay in replays) {
                final on = replay['state_enabled'] == true;
                write({
                  ...replay,
                  'scenario': scenario['id'],
                  'question_id':
                      '${scenario['id']}-replay-${on ? 'on' : 'off'}',
                  'diagnostic_replay': true,
                  'state_after': (await states.load(
                    project,
                    sessionId.value,
                  )).toJson(),
                });
                expect(replay['accepted'], true);
                final added = replay['traces'] as List;
                expect(
                  added.where((t) => t['protocol'] == 'task_state_extraction'),
                  isEmpty,
                );
                expect(
                  added.where(
                    (t) => t['completion']['accepted_message_id'] != null,
                  ),
                  isEmpty,
                  reason: 'Replay does not link to original accepted history',
                );
                final accepted = added
                    .where((t) => t['completion']['replay_message_id'] != null)
                    .single;
                expect(accepted['task_state_used'], on);
                expect(accepted['request']['messages'], hasLength(3));
                expect(accepted['request']['tools_count'], 0);
                expect(accepted['request']['continuation_count'], 0);
              }
              final a = (replays[0]['traces'] as List).last['request'] as Map;
              final b = (replays[1]['traces'] as List).last['request'] as Map;
              expect(a['model'], b['model']);
              expect(a['generation'], b['generation']);
              expect(a['messages'], b['messages']);
              expect(replays[0]['tail'], replays[1]['tail']);
              String withoutState(String prompt) => prompt
                  .replaceAll(
                    RegExp(
                      r'USER_TASK_STATE_EVIDENCE_JSON\n.*?\nEND_USER_TASK_STATE_EVIDENCE',
                      dotAll: true,
                    ),
                    '',
                  )
                  .split('\n')
                  .map((s) => s.trim())
                  .where((s) => s.isNotEmpty)
                  .join('\n');
              expect(
                withoutState(a['system_prompt'] as String),
                withoutState(b['system_prompt'] as String),
              );
              expect(
                env.chat.state.selectedSession!.transcript.toJson(),
                originalTranscript,
              );
              runConfig['diagnostic_replay'] = {
                'real_product_path': true,
                'original_transcript_unchanged': true,
                'tail_ids': replays.first['tail_message_ids'],
                'source_question_id':
                    replays.first['source_question_message_id'],
                'settings_matched': true,
                'no_extractor': true,
              };
              expect(
                (await states.load(project, sessionId.value)).toJson(),
                stateBeforeReplay.toJson(),
                reason:
                    'Final recovery question introduces no new selected conditions',
              );
            } finally {
              await env.close();
              knowledge.dispose();
            }
          }
        } finally {
          File('${output.path}.config.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(config),
            flush: true,
          );
          client.close();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}

final class _Env {
  _Env(
    http.Client client,
    ProviderCredentialResolver credentials,
    AgentSessionRepository sessions,
    JsonlRagRepository repo,
    JsonlRagTraceRepository traces,
    JsonlRagTaskStateRepository states,
    RagModelServiceClient models, {
    List<LlmMessage> initialMessages = const [],
    bool stateOn = true,
  }) {
    stack = buildProductionAgentStack(
      httpClient: client,
      credentials: credentials,
      repository: sessions,
      catalog: sessions as AgentSessionCatalog,
      diagnosticNoCompaction: true,
    );
    definition = AgentDefinition(
      id: AgentId('rag-day25-eval'),
      name: 'Day25 dialogue',
      systemPrompt: '',
      initialMessages: initialMessages,
      model: BuiltInLlmCatalog.deepSeekFlashModel.ref,
      generation: LlmGenerationConfig(
        reasoningMode: ReasoningMode.disabled,
        temperature: 0,
        maxOutputTokens: 2048,
      ),
    );
    rag =
        RagChatController(
          strictGrounding: true,
          coordinator: RagTurnCoordinator(repository: repo, models: models),
          traces: traces,
          registry: stack.registry,
          taskStates: states,
          taskExtractorFactory: (model, before, after) => CloudRagTaskExtractor(
            registry: stack.registry,
            model: model,
            beforeRequest: before,
            afterResult: after,
          ),
        )..configure(
          enabled: true,
          neutral: true,
          protocol: RagProtocol.m1,
          strategy: ChunkStrategy.fixed,
          taskStateEnabled: stateOn,
        );
    chat = ChatWorkspaceController(
      runtime: stack.runtime,
      definition: definition,
      catalog: sessions as AgentSessionCatalog,
      repository: sessions,
      registry: stack.registry,
      runPreparer: rag,
    );
  }
  late final ProductionAgentStack stack;
  late final AgentDefinition definition;
  late final RagChatController rag;
  late final ChatWorkspaceController chat;
  Future<void> close() async {
    await chat.dispose();
    rag.dispose();
    await stack.runtime.close();
  }
}

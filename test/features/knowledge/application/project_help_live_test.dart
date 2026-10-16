import 'dart:convert';
import 'dart:io';
import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/core/projects/project_context.dart';
import 'package:domovoy/core/projects/project_run_scope.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/knowledge/application/knowledge_controller.dart';
import 'package:domovoy/features/knowledge/application/project_help_preparer.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/features/mcp/domain/platform_capabilities.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_agent_session_store.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart';
import 'package:domovoy/infrastructure/mcp/local/local_mcp_server_host.dart';
import 'package:domovoy/infrastructure/projects/context/local_project_context_io.dart';
import 'package:domovoy/infrastructure/rag/document_importer.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:domovoy/infrastructure/rag/model_service_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Opt-in real provider + genuine source tree + actual embeddings + SDK MCP.
/// Does not configure credentials, launch services, or touch emulator state.
void main() {
  final root = Platform.environment['PROJECT_HELP_LIVE_ROOT'];
  test(
    'live project help through production runtime, RAG and MCP',
    () async {
      final temp = await Directory.systemTemp.createTemp('project-help-live-');
      final client = http.Client();
      final storage = JsonlFilesystemStreamStorage(
        applicationSupportDirectoryResolver: () async => temp,
      );
      final sessions = JsonlAgentSessionStore(storage: storage);
      final stack = buildProductionAgentStack(
        interactivePolicy: const AllowAllPolicy(),
        httpClient: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(),
          readEnvironment: (name) => Platform.environment[name],
        ),
        repository: sessions,
        catalog: sessions,
      );
      final service = LocalProjectContextService(
        resolveRoot: (_) async => root!,
      );
      final scopes = ProjectRunScopes();
      final mcp = DomovoyMcpComposition.build(
        runtime: stack.runtime,
        tools: stack.runtime.tools,
        policies: stack.runtime.policies,
        registry: stack.registry,
        sessions: sessions,
        catalog: sessions,
        piToolIds: {},
        projectContext: service,
        projectScopes: scopes,
        inputs: const McpCompositionInputs(
          capabilities: McpPlatformCapabilities.mobile,
          localTransportPreference: McpLocalTransportPreference.stream,
        ),
      );
      final models = RagModelServiceClient(
        client,
        Uri.parse(
          Platform.environment['RAG_MODEL_BASE_URL'] ?? 'http://127.0.0.1:8765',
        ),
      );
      final repository = JsonlRagRepository(storage);
      final coordinator = RagTurnCoordinator(
        repository: repository,
        models: models,
      );
      final traces = JsonlRagTraceRepository(storage);
      final fallback = RagChatController(
        coordinator: coordinator,
        traces: traces,
        registry: stack.registry,
      );
      final knowledge = KnowledgeController(
        repository: repository,
        models: models,
        importer: NativeRagDocumentImporter(client),
        projectContext: service,
      );
      try {
        final project = ProjectId('live-source-checkout');
        await knowledge.initialize(projectId: project.value);
        await knowledge.selectCorpus(projectDocumentationCorpus);
        expect(knowledge.error, isNull);
        await knowledge.buildIndex();
        expect(knowledge.error, isNull);
        final session = await stack.runtime
            .agent(stack.promptDefinition)
            .createSession(projectId: project);
        final preparer = ProjectHelpPreparer(
          projects: service,
          coordinator: coordinator,
          scopes: scopes,
          traces: traces,
          fallback: fallback,
          ensureMcpReady: mcp.initialize,
        );
        final question =
            Platform.environment['PROJECT_HELP_LIVE_QUESTION'] ?? '/help';
        final prepared = await preparer.prepare(
          session.snapshot,
          question,
          CancellationSource().token,
        );
        final events = await session
            .run(question, options: prepared!.options)
            .events
            .toList();
        await prepared.onSettled!(session.snapshot, events.last);
        expect(events.last, isA<AgentRunCompleted>());
        expect(events.whereType<AgentToolStarted>(), isNotEmpty);
        final tools = session.snapshot.transcript.messages
            .where((m) => m.role == LlmMessageRole.tool)
            .map(
              (m) => m.parts
                  .whereType<LlmToolResultPart>()
                  .map((p) => jsonDecode(p.content))
                  .toList(),
            )
            .expand((p) => p)
            .toList();
        expect(
          jsonEncode(tools),
          contains((await service.gitContext(project)).head),
        );
        final answer = session.snapshot.transcript.messages.last.parts
            .whereType<LlmTextPart>()
            .map((p) => p.text)
            .join();
        expect(answer.trim(), isNotEmpty);
        final trace = (await traces.list(project.value, session.id.value)).last;
        final report = {
          'documents': knowledge.documents
              .map((d) => {'source': d.source, 'revision': d.revision})
              .toList(),
          'generation': knowledge.activeIndex!.generation,
          'fingerprint': knowledge.activeIndex!.fingerprint,
          'chunks': knowledge.activeIndex!.chunks.length,
          'tool_results': tools,
          'overview_policy': trace['overview_policy'],
          'source_provenance': (trace['candidates'] as List)
              .where((c) => c['sent'] == true)
              .map(
                (c) => {
                  'source': c['chunk']['source'],
                  'retrieval_kind': c['retrieval_kind'] ?? 'dense',
                  'dense_rank': c['dense_rank'],
                  'cosine': c['cosine'],
                },
              )
              .toList(),
          'sources': (trace['candidates'] as List)
              .where((c) => c['sent'] == true)
              .map((c) => c['chunk'])
              .toList(),
          'answer': answer,
          'terminal': events.last.runtimeType.toString(),
        };
        final output = Platform.environment['PROJECT_HELP_LIVE_REPORT'];
        if (output != null) {
          await File(
            output,
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        }
        // No credential, raw request, scope capability or reasoning is printed.
        // ignore: avoid_print
        print(
          'Live project help: ${knowledge.documents.length} files, ${knowledge.activeIndex!.chunks.length} chunks, ${tools.length} MCP results.',
        );
      } finally {
        knowledge.dispose();
        fallback.dispose();
        await mcp.close();
        await stack.runtime.close();
        await stack.providerModelCatalog?.close();
        client.close();
        await temp.delete(recursive: true);
      }
    },
    skip: root == null
        ? 'Set PROJECT_HELP_LIVE_ROOT and DEEPSEEK_API_KEY; start the genuine RAG gateway.'
        : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

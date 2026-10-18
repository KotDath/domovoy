import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/contracts.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/support/support.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/support/application/support_catalog.dart';
import 'package:domovoy/features/support/application/support_controller.dart';
import 'package:domovoy/features/support/application/support_run_preparer.dart';
import 'package:domovoy/features/support/application/support_service.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_agent_session_store.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:domovoy/infrastructure/support/jsonl_support_repository.dart';
import 'package:domovoy/infrastructure/support/support_manual.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';

import 'agent_harness.dart';
import 'memory_jsonl_storage.dart';
import 'rag_fakes.dart';

const supportSnapshot = SupportSnapshot(
  observedAt: 100,
  platform: 'android',
  version: 'test',
  provider: 'deepseek',
  model: 'deepseek-chat',
  mcp: 'not checked',
  rag: 'not checked',
);

final class SupportHarness {
  SupportHarness({
    List<List<LlmEvent>> turns = const [],
    RagModelProvider? models,
    Future<SupportManual> Function()? manualLoader,
    JsonlStreamStorage? ticketStorage,
    JsonlStreamStorage? sessionStorage,
    this.withMcp = true,
  }) {
    tickets = JsonlSupportRepository(ticketStorage ?? FakeMemoryJsonlStorage());
    sessions = JsonlAgentSessionStore(
      storage: sessionStorage ?? FakeMemoryJsonlStorage(),
    );
    provider = QueueScriptedLlmProvider(
      id: ProviderId('deepseek'),
      wireFamily: LlmWireFamily.openaiChatCompletions,
      turns: turns,
    );
    runtime = testRuntime(
      provider: provider,
      repository: sessions,
      policies: {
        'deny': const DenyAllPolicy(),
        'allow': const AllowAllPolicy(),
        'support': SupportToolPolicy(scopes),
      },
    );
    service = SupportService(
      tickets: tickets,
      sessions: sessions,
      catalog: sessions,
      runtime: runtime,
      definition: supportDefinition(BuiltInLlmCatalog.deepSeekV4FlashModel.ref),
    );
    if (withMcp) {
      mcp = DomovoyMcpComposition.build(
        runtime: runtime,
        tools: runtime.tools,
        policies: runtime.policies,
        registry: runtime.registry,
        sessions: sessions,
        catalog: SupportSessionCatalog(sessions),
        piToolIds: const {},
        supportRepository: tickets,
        supportScopes: scopes,
        inputs: const McpCompositionInputs(
          localTransportPreference: McpLocalTransportPreference.stream,
        ),
      );
    }
    preparer = SupportRunPreparer(
      tickets: tickets,
      scopes: scopes,
      repository: JsonlRagRepository(ragStorage),
      models: models ?? FakeRagModels(),
      traces: JsonlRagTraceRepository(ragStorage),
      ensureMcpReady: () async {
        await mcp?.initialize();
      },
      mcpReady: () =>
          !withMcp ||
          supportToolIds.every(
            (id) => mcp!.host.snapshot.catalog.lookup(id) != null,
          ),
      loadManual:
          manualLoader ??
          () async => SupportManual('test', [
            RagDocument(
              source: 'domovoy://manual/mcp',
              title: 'MCP',
              text:
                  '# MCP\nНа Android сторонний stdio недоступен. Используйте Streamable HTTPS.\n',
            ),
          ], packageVersion: 'test'),
    );
    chat = ChatWorkspaceController(
      runtime: runtime,
      definition: service.definition,
      catalog: SupportSessionCatalog(sessions, support: true),
      repository: sessions,
      registry: runtime.registry,
      runPreparer: preparer,
      supportMode: true,
    );
    controller = SupportController(
      service: service,
      chat: chat,
      preparer: preparer,
      captureSnapshot: (_) => supportSnapshot,
      initialSelection: () =>
          AgentSessionSelection.fromDefinition(service.definition),
    );
  }
  final bool withMcp;
  final scopes = SupportRunScopes();
  final ragStorage = FakeMemoryJsonlStorage();
  late final JsonlSupportRepository tickets;
  late final JsonlAgentSessionStore sessions;
  late final QueueScriptedLlmProvider provider;
  late final InMemoryAgentRuntime runtime;
  late final SupportService service;
  late final SupportRunPreparer preparer;
  late final ChatWorkspaceController chat;
  late final SupportController controller;
  DomovoyMcpComposition? mcp;
  Future<SupportTicket> create({
    String subject = 'MCP на телефоне',
    String description = 'Как подключить сервер?',
  }) => service.create(
    subject: subject,
    description: description,
    snapshot: supportSnapshot,
  );
  Future<void> close() async {
    await controller.close();
    await mcp?.close();
    await runtime.close();
  }
}

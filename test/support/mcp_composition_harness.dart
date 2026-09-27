import 'dart:async';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/features/mcp/mcp.dart' show McpPlatformCapabilities;
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/servers/arxiv/arxiv.dart';

import 'agent_harness.dart';
import 'memory_jsonl_storage.dart';

/// Scriptable provider that routes by request content.
///
/// The agent loop and the digest MCP server share the composition's registry,
/// so one provider instance answers both: requests whose system prompt is the
/// digest prompt are answered by [digestResponder], every other request by
/// [agentResponder]. In-flight calls are recorded for assertions about which
/// model was pinned.
final class RoutingLlmProvider implements LlmProvider {
  RoutingLlmProvider({
    required this.id,
    this.wireFamily = LlmWireFamily.openaiChatCompletions,
    required this.agentResponder,
    this.digestResponder,
    this.scheduledResponder,
  });

  @override
  final ProviderId id;

  @override
  final LlmWireFamily wireFamily;

  final List<LlmRequest> requests = <LlmRequest>[];

  /// Every agent (non-digest) request; the digest requests are separated.
  final List<LlmRequest> agentRequests = <LlmRequest>[];
  final List<LlmRequest> digestRequests = <LlmRequest>[];

  /// Mutable so a test can script one agent run at a time; call
  /// [resetAgentTurns] before each run.
  FutureOr<List<LlmEvent>> Function(LlmRequest request, int index)
  agentResponder;

  final FutureOr<List<LlmEvent>> Function(LlmRequest request, int index)?
  digestResponder;

  /// Answers Domovoy-owned scheduled runs (automation tasks).
  final FutureOr<List<LlmEvent>> Function(LlmRequest request, int index)?
  scheduledResponder;

  var _agentIndex = 0;
  var _digestIndex = 0;
  var _scheduledIndex = 0;

  /// Every scheduled-run request, recorded before the responder settles.
  final List<LlmRequest> scheduledRequests = <LlmRequest>[];

  /// Restarts the agent turn script for the next run.
  void resetAgentTurns() {
    _agentIndex = 0;
  }

  static bool isDigestRequest(LlmRequest request) =>
      (request.context.systemPrompt ?? '').contains('MCP-сервера digest');

  static bool isScheduledRequest(LlmRequest request) =>
      (request.context.systemPrompt ?? '').contains('запущенный по расписанию');

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    requests.add(request);
    final digest = isDigestRequest(request);
    final scheduled = !digest && isScheduledRequest(request);
    final List<LlmEvent> events;
    if (digest) {
      // Recorded before the responder settles so a gated test can observe
      // the request while it is still in flight.
      digestRequests.add(request);
      final digestEvents = digestResponder?.call(request, _digestIndex++);
      events = digestEvents == null
          ? const <LlmEvent>[LlmCompleted(finishReason: LlmFinishReason.stop)]
          : await digestEvents;
    } else if (scheduled) {
      scheduledRequests.add(request);
      final scheduledEvents = scheduledResponder?.call(
        request,
        _scheduledIndex++,
      );
      events = scheduledEvents == null
          ? const <LlmEvent>[
              LlmTextDelta('Задача выполнена по расписанию.'),
              LlmCompleted(finishReason: LlmFinishReason.stop),
            ]
          : await scheduledEvents;
    } else {
      agentRequests.add(request);
      events = await agentResponder(request, _agentIndex++);
    }
    if (cancellation.isCancelled) {
      yield const LlmCancelled();
      return;
    }
    for (final event in events) {
      if (cancellation.isCancelled) {
        yield const LlmCancelled();
        return;
      }
      yield event;
      if (event.isTerminal) {
        return;
      }
    }
    yield const LlmCompleted(finishReason: LlmFinishReason.stop);
  }
}

/// One production MCP composition over in-memory storage for integration
/// tests: real local servers (in-process streams), the real agent bridge, the
/// real permission policy and the real tasks/library controllers.
final class McpCompositionHarness {
  McpCompositionHarness._({
    required this.runtime,
    required this.tools,
    required this.policies,
    required this.sessions,
    required this.mcp,
    required this.provider,
    required this.connectionStorage,
    required this.selectionStorage,
    required this.libraryStorage,
    required this.automationStorage,
    required this.automationChatStorage,
  });

  final InMemoryAgentRuntime runtime;
  final AgentToolRegistry tools;
  final Map<String, ToolPermissionPolicy> policies;

  /// Session repository and catalog of the composition (same instance).
  final InMemoryAgentSessionRepository sessions;
  final DomovoyMcpComposition mcp;
  final RoutingLlmProvider provider;

  final FakeMemoryJsonlStorage connectionStorage;
  final FakeMemoryJsonlStorage selectionStorage;
  final FakeMemoryJsonlStorage libraryStorage;
  final FakeMemoryJsonlStorage automationStorage;
  final FakeMemoryJsonlStorage automationChatStorage;

  static final readDescriptor = LlmToolDescriptor(
    name: 'read',
    description: 'Pi read',
    parameters: <String, Object?>{'type': 'object'},
  );
  static final writeDescriptor = LlmToolDescriptor(
    name: 'write',
    description: 'Pi write',
    parameters: <String, Object?>{'type': 'object'},
  );
  static final editDescriptor = LlmToolDescriptor(
    name: 'edit',
    description: 'Pi edit',
    parameters: <String, Object?>{'type': 'object'},
  );
  static final bashDescriptor = LlmToolDescriptor(
    name: 'bash',
    description: 'Pi bash',
    parameters: <String, Object?>{'type': 'object'},
  );

  static final piDescriptors = <LlmToolDescriptor>[
    readDescriptor,
    writeDescriptor,
    editDescriptor,
    bashDescriptor,
  ];

  /// Builds and initializes the composition.
  ///
  /// Reusing the storage instances across two calls models an application
  /// restart with the same device files.
  static Future<McpCompositionHarness> start({
    required RoutingLlmProvider provider,
    FakeMemoryJsonlStorage? connectionStorage,
    FakeMemoryJsonlStorage? selectionStorage,
    FakeMemoryJsonlStorage? libraryStorage,
    FakeMemoryJsonlStorage? automationStorage,
    FakeMemoryJsonlStorage? automationChatStorage,
    ArxivHttpAdapter? arxivHttpAdapter,
    ArxivClock? arxivClock,
    AutomationClock? automationClock,
    List<LlmToolDescriptor>? piTools,
    McpPlatformCapabilities? capabilities,
    bool withLibrary = true,
    bool withAutomation = true,
    bool pauseAutomationInBackground = false,
    Duration legacyDiscoveryTimeout = defaultMcpLegacyDiscoveryTimeout,
  }) async {
    final descriptors = piTools ?? McpCompositionHarness.piDescriptors;
    final tools = AgentToolRegistry();
    for (final descriptor in descriptors) {
      tools.register(
        AgentTool(
          descriptor: descriptor,
          executor: ScriptedToolExecutor(
            (invocation, {required cancellation, required liveness}) async =>
                ToolExecutionResult.success(<String, Object?>{
                  'tool': invocation.name,
                }),
          ),
        ),
      );
    }
    final policies = <String, ToolPermissionPolicy>{
      'deny': const DenyAllPolicy(),
      'allow': const AllowAllPolicy(),
    };
    final runtime = testRuntime(
      provider: provider,
      tools: tools,
      policies: policies,
    );
    final sessions = InMemoryAgentSessionRepository();
    final connections = connectionStorage ?? FakeMemoryJsonlStorage();
    final selections = selectionStorage ?? FakeMemoryJsonlStorage();
    final library = libraryStorage ?? FakeMemoryJsonlStorage();
    final automationStore = automationStorage ?? FakeMemoryJsonlStorage();
    final automationChat = automationChatStorage ?? FakeMemoryJsonlStorage();
    final mcp = DomovoyMcpComposition.build(
      runtime: runtime,
      tools: tools,
      policies: policies,
      registry: runtime.registry,
      sessions: sessions,
      catalog: sessions,
      piToolIds: <String>{
        for (final descriptor in descriptors) descriptor.name,
      },
      inputs: McpCompositionInputs(
        connectionStorage: connections,
        selectionStorage: selections,
        libraryStorage: withLibrary ? library : null,
        automationStorage: withAutomation ? automationStore : null,
        automationChatStorage: withAutomation ? automationChat : null,
        secretVault: InMemoryMcpSecretVault(),
        capabilities: capabilities ?? McpPlatformCapabilities.desktop,
        localTransportPreference: McpLocalTransportPreference.stream,
        pauseAutomationInBackground: pauseAutomationInBackground,
        legacyDiscoveryTimeout: legacyDiscoveryTimeout,
        arxivHttpAdapter: arxivHttpAdapter,
        arxivClock: arxivClock,
        automationClock: automationClock,
      ),
    );
    await mcp.initialize();
    return McpCompositionHarness._(
      runtime: runtime,
      tools: tools,
      policies: policies,
      sessions: sessions,
      mcp: mcp,
      provider: provider,
      connectionStorage: connections,
      selectionStorage: selections,
      libraryStorage: library,
      automationStorage: automationStore,
      automationChatStorage: automationChat,
    );
  }

  /// Model-facing id of one built-in tool.
  String toolId(String connectionId, String originalName) =>
      McpToolNamePolicy().candidate(
        connectionId: McpConnectionId(connectionId),
        originalToolName: originalName,
      );

  Future<void> dispose() async {
    await runtime.close();
    await mcp.close();
  }

  /// Runs one prompt through a session of the composition runtime.
  ///
  /// With [withRunContext] the harness acts as the app composition does: it
  /// issues an app-owned tool context for the session's model, passes it
  /// through `AgentRunOptions` and releases it when the run settles.
  ///
  /// [bindLibraryRunId] models a Domovoy-owned scheduled run: the runtime run
  /// id is bound to local `library.save_digest` calls.
  Future<List<AgentRunEvent>> runSession({
    required String prompt,
    required List<ToolId> enabledTools,
    required AgentSessionId sessionId,
    ProjectId? projectId,
    ModelRef? model,
    bool withRunContext = false,
    bool bindLibraryRunId = false,
  }) async {
    final definition = AgentDefinition(
      id: AgentId('composition-${sessionId.value}'),
      name: sessionId.value,
      systemPrompt: 'You are a composition test agent.',
      model: model ?? BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      enabledTools: enabledTools,
      policy: PolicyId('allow'),
      // A finite cap keeps a mis-scripted responder from looping forever;
      // policy behavior is independent of the quota.
      limits: AgentRunLimits(maxModelTurns: 12, maxToolCalls: 12),
    );
    final session = await runtime
        .agent(definition)
        .createSession(id: sessionId, projectId: projectId);
    final context = withRunContext
        ? mcp.runToolContexts.begin(
            model: definition.model,
            bindLibraryRunId: bindLibraryRunId,
          )
        : null;
    try {
      return await session
          .run(
            prompt,
            options: context == null
                ? null
                : AgentRunOptions(toolContext: context),
          )
          .events
          .toList();
    } finally {
      if (context != null) {
        mcp.runToolContexts.end(context);
      }
      await session.close();
    }
  }
}

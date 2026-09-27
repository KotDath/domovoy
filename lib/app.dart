import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'core/agents/agents.dart';
import 'core/automation/automation.dart';
import 'core/environment/platform_environment_reader.dart';
import 'core/llm/llm.dart';
import 'core/mcp/mcp.dart';
import 'core/memory/memory.dart';
import 'core/personalization/personalization.dart';
import 'design_system/design_system.dart';
import 'features/chat/application/chat_workspace_controller.dart';
import 'features/chat/presentation/chat_workspace_page.dart';
import 'features/library/application/library_controller.dart';
import 'features/library/presentation/library_page.dart';
import 'features/mcp/mcp.dart';
import 'features/memory/application/memory_inspector_controller.dart';
import 'features/memory/application/memory_inspector_state.dart';
import 'features/projects/application/project_application_service.dart';
import 'features/projects/application/project_workspace_controller.dart';
import 'features/projects/presentation/project_workspace_page.dart';
import 'features/profile/application/profile_controller.dart';
import 'features/profile/application/profile_interview.dart';
import 'features/prompt/domain/prompt_workspace.dart';
import 'features/settings/data/secure_api_key_override_store.dart';
import 'features/settings/data/secure_model_settings_store.dart';
import 'features/settings/domain/api_key_credentials.dart';
import 'features/settings/domain/model_settings.dart';
import 'features/settings/presentation/api_key_settings_dialog.dart';
import 'features/settings/presentation/provider_api_keys_dialog.dart';
import 'features/tasks/application/automation_chat_delivery_sink.dart';
import 'features/tasks/application/task_editor_controller.dart';
import 'features/tasks/application/tasks_controller.dart';
import 'features/tasks/presentation/tasks_page.dart';
import 'infrastructure/credentials/credentials.dart';
import 'infrastructure/agents/jsonl/jsonl.dart';
import 'infrastructure/automation/automation.dart';
import 'infrastructure/automation_chat/automation_chat.dart';
import 'infrastructure/mcp/mcp.dart';
import 'infrastructure/mcp/servers/arxiv/arxiv.dart';
import 'infrastructure/mcp/servers/automation/automation.dart';
import 'infrastructure/mcp/servers/digest/digest.dart';
import 'infrastructure/mcp/servers/library/library.dart';
import 'infrastructure/memory/memory.dart';
import 'infrastructure/personalization/personalization.dart';
import 'infrastructure/projects/platform_projects.dart';
import 'infrastructure/tools/local_workspace_tools.dart';
import 'infrastructure/llm/openai_compatible/openai_compatible.dart';
import 'infrastructure/llm/openai_responses/openai_responses.dart';
import 'infrastructure/llm/discovery/native_streaming_provider.dart';
import 'infrastructure/llm/discovery/provider_manifest.dart';
import 'infrastructure/llm/discovery/provider_model_catalog.dart';

final class ProductionAgentStack {
  ProductionAgentStack({
    required this.registry,
    required this.runtime,
    required this.promptDefinition,
    required this.credentials,
    required this.repository,
    required this.catalog,
    this.providerModelCatalog,
  });

  final LlmProviderRegistry registry;
  final InMemoryAgentRuntime runtime;
  final AgentDefinition promptDefinition;
  final ProviderCredentialResolver credentials;
  final AgentSessionRepository repository;
  final AgentSessionCatalog catalog;
  final ProviderModelCatalog? providerModelCatalog;
}

ProductionAgentStack buildProductionAgentStack({
  required http.Client httpClient,
  required ProviderCredentialResolver credentials,
  AgentSessionRepository? repository,
  AgentSessionCatalog? catalog,
  bool diagnosticNoCompaction = false,
  AgentIdFactory? ids,
  AgentDynamicContextProvider? dynamicContextProvider,
  AgentToolRegistry? tools,
  List<ToolId> enabledTools = const <ToolId>[],
  ToolPermissionPolicy? interactivePolicy,
}) {
  if ((repository == null) != (catalog == null)) {
    throw ArgumentError(
      'Repository and catalog replacements must be supplied together.',
    );
  }
  if (interactivePolicy != null && interactivePolicy.id != PolicyId('allow')) {
    throw ArgumentError.value(
      interactivePolicy.id.value,
      'interactivePolicy',
      'The interactive policy must keep the stable "allow" id so existing '
          'sessions resolve it without a migration.',
    );
  }
  final durableStore = repository == null
      ? JsonlAgentSessionStore(storage: createPlatformJsonlStreamStorage())
      : null;
  final resolvedRepository = repository ?? durableStore!;
  final resolvedCatalog = catalog ?? durableStore!;
  final registry = LlmProviderRegistry();
  final compatibleProfiles = <String, OpenAiCompatibleProfile>{};
  final responseProfiles = <String, OpenAiResponsesProfile>{};
  for (final spec in ApiKeyProviderManifest.entries) {
    final initial = BuiltInLlmCatalog.models
        .where((model) => model.providerId.value == spec.id)
        .toList(growable: false);
    registry.registerProfile(spec.profile);
    switch (spec.protocol) {
      case ApiKeyProviderProtocol.chatCompletions:
        final profile = OpenAiCompatibleProfile.builtInDynamic(
          snapshot: spec.profile,
          models: initial,
          dialectFor: (modelId) {
            if (spec.id == 'deepseek' || spec.id == 'moonshotai') {
              final builtIn = ChatCompletionsDialect.forBuiltInModel(modelId);
              if (builtIn != ChatCompletionsDialect.generic) return builtIn;
            }
            return _dialectForReasoningFormat(spec.reasoningFormat);
          },
          sessionAffinityHeader: spec.sessionAffinityHeader,
        );
        compatibleProfiles[spec.id] = profile;
        registry.registerProvider(
          OpenAiChatCompletionsLlmProvider(
            profile: profile,
            client: httpClient,
            credentials: credentials,
          ),
        );
      case ApiKeyProviderProtocol.responses:
        final profile = OpenAiResponsesProfile(
          snapshot: spec.profile,
          models: initial,
          allowEmptyModels: true,
        );
        responseProfiles[spec.id] = profile;
        registry.registerProvider(
          OpenAiResponsesLlmProvider(
            profile: profile,
            client: httpClient,
            credentials: credentials,
          ),
        );
      case ApiKeyProviderProtocol.anthropicMessages:
      case ApiKeyProviderProtocol.geminiGenerateContent:
        registry.registerProvider(
          NativeStreamingLlmProvider(
            spec: spec,
            client: httpClient,
            credentials: credentials,
          ),
        );
    }
  }
  registry.replaceModels(BuiltInLlmCatalog.models);
  final providerModelCatalog = ProviderModelCatalog(
    client: httpClient,
    credentials: credentials,
    publishModels: (models) {
      registry.replaceModels(models);
      for (final entry in compatibleProfiles.entries) {
        entry.value.replaceModels(
          models
              .where((model) => model.providerId.value == entry.key)
              .toList(growable: false),
        );
      }
      for (final entry in responseProfiles.entries) {
        entry.value.replaceModels(
          models
              .where((model) => model.providerId.value == entry.key)
              .toList(growable: false),
        );
      }
    },
  );
  const contextEstimator = Utf8FramingAgentContextEstimator();
  final compactionTrigger = OpenCodeCompactionTrigger();
  final modelSwitchFitPolicy = OpenCodeAgentModelSwitchFitPolicy();
  final historyCompactor = OpenCodeSummaryCompactor(
    llm: RegistryAgentSummaryLlmInvocation(registry),
    contextEstimator: contextEstimator,
  );
  final interactiveTools = enabledTools.isNotEmpty || interactivePolicy != null;
  final runtime = InMemoryAgentRuntime(
    registry: registry,
    tools: tools ?? AgentToolRegistry(),
    policies: <String, ToolPermissionPolicy>{
      'deny': const DenyAllPolicy(),
      'allow': interactivePolicy ?? const AllowAllPolicy(),
    },
    repository: resolvedRepository,
    router: InMemorySessionRouter(),
    profile: AgentRuntimeProfile(),
    contextEstimator: contextEstimator,
    compactionTrigger: diagnosticNoCompaction ? null : compactionTrigger,
    modelSwitchFitPolicy: modelSwitchFitPolicy,
    historyCompactor: diagnosticNoCompaction ? null : historyCompactor,
    ids: ids ?? AgentIdFactory(namespace: _newRuntimeNamespace()),
    dynamicContextProvider: dynamicContextProvider,
  );
  return ProductionAgentStack(
    registry: registry,
    runtime: runtime,
    promptDefinition: PromptWorkspace.definition(
      enabledTools: enabledTools,
      policy: interactiveTools ? PolicyId('allow') : PolicyId('deny'),
      runLimits: PromptWorkspace.interactiveLimits,
    ),
    credentials: credentials,
    repository: resolvedRepository,
    catalog: resolvedCatalog,
    providerModelCatalog: providerModelCatalog,
  );
}

/// Build flavor selected with `--dart-define=DOMOVOY_FLAVOR=aurora`.
///
/// Aurora can report `Platform.isLinux`, so the composition needs an explicit
/// fact to disable third-party stdio, pause automation in background and use
/// the in-process stream transport until a device smoke confirms loopback.
const domovoyBuildFlavor = String.fromEnvironment('DOMOVOY_FLAVOR');

bool get isAuroraBuildFlavor => domovoyBuildFlavor == 'aurora';

/// Platform capabilities when no explicit composition override is supplied.
McpPlatformCapabilities defaultMcpPlatformCapabilities() {
  if (kIsWeb) {
    return McpPlatformCapabilities.web;
  }
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    return McpPlatformCapabilities.mobile;
  }
  return McpPlatformCapabilities.desktop;
}

/// Injectable storage, platform facts and policy overrides of the MCP stack.
///
/// Every field is optional; `null` platform storage means "this build has no
/// such storage" and the composition falls back to an in-memory store (user
/// connections and tool selections) or leaves the owning server unregistered
/// (library and automation), never inventing an ad hoc file path.
final class McpCompositionInputs {
  const McpCompositionInputs({
    this.connectionStorage,
    this.selectionStorage,
    this.libraryStorage,
    this.automationStorage,
    this.automationChatStorage,
    this.secretVault,
    this.capabilities,
    this.localTransportPreference = McpLocalTransportPreference.auto,
    this.useDesktopSidecar = false,
    this.forceDisableStdio = false,
    this.stdioDisabledReason,
    this.pauseAutomationInBackground = false,
    this.legacyDiscoveryTimeout = defaultMcpLegacyDiscoveryTimeout,
    this.diagnostics = const NoopMcpDiagnosticsSink(),
    this.arxivHttpAdapter,
    this.arxivClock,
    this.automationClock,
  });

  final JsonlStreamStorage? connectionStorage;
  final JsonlStreamStorage? selectionStorage;
  final JsonlStreamStorage? libraryStorage;
  final JsonlStreamStorage? automationStorage;
  final JsonlStreamStorage? automationChatStorage;
  final McpSecretVault? secretVault;
  final McpPlatformCapabilities? capabilities;
  final McpLocalTransportPreference localTransportPreference;

  /// Desktop production hosts expose each built-in MCP endpoint from its own
  /// child process; tests and mobile builds keep the in-process launcher.
  final bool useDesktopSidecar;
  final bool forceDisableStdio;
  final String? stdioDisabledReason;
  final bool pauseAutomationInBackground;
  final Duration legacyDiscoveryTimeout;
  final McpDiagnosticsSink diagnostics;

  /// Test seam for the built-in `arxiv` server: controlled HTTP responses and
  /// a virtual clock so the rate limiter never slows a test down.
  final ArxivHttpAdapter? arxivHttpAdapter;
  final ArxivClock? arxivClock;

  /// Test seam for the scheduler clock (catch-up and DST scenarios).
  final AutomationClock? automationClock;
}

/// Explicit production composition of the MCP host, the four built-in
/// servers, the agent bridge, the permission feature and the tasks/library UI.
///
/// One instance is created by [DomovoyDependencies.production]; [initialize]
/// starts the built-in servers, connects every configured client and loads the
/// B7 permission store. Nothing here is implicit: the composition owns the
/// lifecycle, and [close] releases scopes, stops the scheduler, the clients
/// and the local servers in order.
final class DomovoyMcpComposition {
  DomovoyMcpComposition._({
    required this.localServers,
    required this.host,
    required this.bridge,
    required this.feature,
    required this.connectionRepository,
    required this.runtimeSecrets,
    required this.secretVault,
    required this.pins,
    required this.runToolContexts,
    required this.builtInConnectionIds,
    required Set<String> declaredBuiltInConnectionIds,
    required Map<String, String> builtInFailures,
    required this.arxivFactory,
    this.automation,
    this.chatDeliveryStore,
    this.tasks,
    this.taskEditor,
    this.library,
    this.automationObserver,
  }) : declaredBuiltInConnectionIds = Set<String>.unmodifiable(
         declaredBuiltInConnectionIds,
       ),
       _builtInFailures = Map<String, String>.of(builtInFailures);

  /// Starts the built-ins and connects every enabled saved connection.
  ///
  /// Errors from one built-in server are recorded in [builtInFailures] and do
  /// not stop the others; configuration corruption is rethrown so the caller
  /// can surface it.
  static DomovoyMcpComposition build({
    required AgentRuntime runtime,
    required AgentToolRegistry tools,
    required Map<String, ToolPermissionPolicy> policies,
    required LlmProviderRegistry registry,
    required AgentSessionRepository sessions,
    required AgentSessionCatalog catalog,
    required Set<String> piToolIds,
    required McpCompositionInputs inputs,
  }) {
    final diagnostics = inputs.diagnostics;
    final capabilities =
        inputs.capabilities ?? defaultMcpPlatformCapabilities();
    final secretVault = inputs.secretVault ?? InMemoryMcpSecretVault();
    final runtimeSecrets = RuntimeMcpSecretResolver(fallback: secretVault);
    final localServers = LocalMcpServerHost(
      preference: inputs.localTransportPreference,
      runtimeSecrets: runtimeSecrets,
      diagnostics: diagnostics,
      httpLauncher: createMcpHttpServerLauncher(
        useDesktopSidecar: inputs.useDesktopSidecar,
      ),
    );
    final transports = McpSdkTransportFactory(
      streams: localServers,
      diagnostics: diagnostics,
      legacyDiscoveryTimeout: inputs.legacyDiscoveryTimeout,
      stdioLauncher: createMcpStdioLauncher(
        forceDisabled: inputs.forceDisableStdio,
        disabledReason: inputs.stdioDisabledReason,
        legacyDiscoveryTimeout: inputs.legacyDiscoveryTimeout,
      ),
    );
    const builtInIds = <String>{'arxiv', 'digest', 'library', 'automation'};
    final connectionRepository = AppOwnedMcpConnectionRepository(
      userStore: inputs.connectionStorage == null
          ? InMemoryMcpConnectionRepository()
          : JsonlMcpConnectionStore(storage: inputs.connectionStorage!),
      appOwnedConnectionIds: builtInIds,
    );
    final host = McpHostManager(
      transports: transports,
      repository: connectionRepository,
      secrets: runtimeSecrets,
      appOwnedConnectionIds: builtInIds,
      diagnostics: diagnostics,
    );

    final pins = DigestModelPinRegistry(
      scopeKeyOf: (scope) => scope.meta['domovoy/runScope'] as String?,
    );
    final runToolContexts = DigestRunToolContextFactory(pins: pins);

    // --- Built-in servers of this device -------------------------------
    final arxivFactory = ArxivMcpServerFactory(
      httpAdapter: inputs.arxivHttpAdapter,
      clock: inputs.arxivClock,
    );
    localServers.register(arxivFactory);
    final digestFactory = DigestMcpServerFactory(
      registry: registry,
      pins: pins,
    );
    localServers.register(digestFactory);
    final builtInFailures = <String, String>{};
    final startedBuiltIns = <String>{'arxiv', 'digest'};

    // Library owns the device library JSONL; without native storage the
    // server is not registered at all (web/unknown targets).
    if (inputs.libraryStorage != null) {
      localServers.register(
        LibraryMcpServerFactory(storage: inputs.libraryStorage!),
      );
      startedBuiltIns.add('library');
    } else {
      builtInFailures['library'] =
          'На этой платформе нет локального хранилища библиотеки.';
    }

    // --- Automation: one scheduler shared by MCP tools and the UI -------
    AutomationStack? automation;
    JsonlAutomationChatDeliveryStore? chatDeliveryStore;
    AutomationForegroundObserver? automationObserver;
    AutomationResultDelivery? delivery;
    if (inputs.automationStorage != null) {
      final chatStorage = inputs.automationChatStorage;
      if (chatStorage != null) {
        chatDeliveryStore = JsonlAutomationChatDeliveryStore(
          storage: chatStorage,
        );
        delivery = AutomationChatDeliverySink(
          store: chatDeliveryStore,
          chatExists: SessionRepositoryChatExistence(sessions),
        );
      }
      automation = buildAutomationStack(
        storage: inputs.automationStorage!,
        runtime: runtime,
        policies: policies,
        models: registry,
        tools: tools,
        runToolContexts: runToolContexts,
        delivery: delivery,
        clock: inputs.automationClock,
      );
      localServers.register(
        AutomationMcpServerFactory(service: automation.service),
      );
      startedBuiltIns.add('automation');
      automationObserver = AutomationForegroundObserver(
        service: automation.service,
        pauseWhenBackgrounded: () => inputs.pauseAutomationInBackground,
      );
    } else {
      builtInFailures['automation'] =
          'На этой платформе нет локального хранилища задач.';
    }

    // --- Agent bridge + permissions -------------------------------------
    final bridge = McpAgentToolBridge(
      host: host,
      digestScopeConnectionIds: const <String>{'digest'},
      libraryRunIdConnectionIds: const <String>{'library'},
    );
    bridge.attachTo(tools);

    final feature = McpFeature.build(
      host: host,
      repository: connectionRepository,
      secrets: secretVault,
      selections: inputs.selectionStorage == null
          ? InMemoryMcpToolSelectionStore()
          : JsonlMcpToolSelectionStore(storage: inputs.selectionStorage!),
      capabilities: capabilities,
      probeTransports: transports,
      hostChanges: host,
      builtInConnectionIds: builtInIds,
      builtInProcessId: (id) => switch (localServers.endpointFor(id)) {
        LocalMcpHttpEndpoint(:final processId) => processId,
        _ => null,
      },
      unavailableReasons: () => bridge.source.unavailableTools,
    );

    // The stable `allow` id is kept: legacy sessions resolve it without a
    // migration, but its behavior now separates built-in identities from
    // explicitly granted MCP routes and denies everything unknown.
    policies['allow'] = CompositeToolAccessPolicy(
      id: PolicyId('allow'),
      piToolIds: piToolIds,
      catalog: () => host.snapshot.catalog,
      selectedToolIds: (invocation) => feature.toolAccess.effectiveToolIds(
        chatId: invocation.sessionId,
        projectId: invocation.projectId,
      ),
    );

    TasksController? tasksController;
    TaskEditorController? taskEditor;
    LibraryController? libraryController;
    if (automation != null) {
      tasksController = TasksController(
        service: automation.service,
        delivery: delivery,
      );
      taskEditor = TaskEditorController(
        service: automation.service,
        mcpHost: host,
        hostChanges: host,
        chats: catalog,
      );
    }
    if (startedBuiltIns.contains('library')) {
      libraryController = LibraryController(host);
    }

    return DomovoyMcpComposition._(
      localServers: localServers,
      host: host,
      bridge: bridge,
      feature: feature,
      connectionRepository: connectionRepository,
      runtimeSecrets: runtimeSecrets,
      secretVault: secretVault,
      pins: pins,
      runToolContexts: runToolContexts,
      builtInConnectionIds: Set<String>.unmodifiable(startedBuiltIns),
      declaredBuiltInConnectionIds: builtInIds,
      builtInFailures: builtInFailures,
      arxivFactory: arxivFactory,
      automation: automation,
      chatDeliveryStore: chatDeliveryStore,
      tasks: tasksController,
      taskEditor: taskEditor,
      library: libraryController,
      automationObserver: automationObserver,
    );
  }

  final LocalMcpServerHost localServers;
  final McpHostManager host;
  final McpAgentToolBridge bridge;
  final McpFeature feature;
  final AppOwnedMcpConnectionRepository connectionRepository;
  final RuntimeMcpSecretResolver runtimeSecrets;
  final McpSecretVault secretVault;
  final DigestModelPinRegistry pins;
  final DigestRunToolContextFactory runToolContexts;

  /// Ids of built-in servers actually started in this build.
  final Set<String> builtInConnectionIds;

  /// Every built-in id this build may own, started or not; user settings must
  /// never be able to shadow any of them.
  final Set<String> declaredBuiltInConnectionIds;

  final Map<String, String> _builtInFailures;

  /// Human-readable reasons built-ins are unavailable, including failures
  /// discovered while starting them.
  Map<String, String> get builtInErrors =>
      Map<String, String>.unmodifiable(_builtInFailures);

  final ArxivMcpServerFactory arxivFactory;
  final AutomationStack? automation;
  final JsonlAutomationChatDeliveryStore? chatDeliveryStore;
  final TasksController? tasks;
  final TaskEditorController? taskEditor;
  final LibraryController? library;
  final AutomationForegroundObserver? automationObserver;
  Future<void>? _initializeFuture;
  Future<void>? _closeFuture;

  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    for (final id in builtInConnectionIds) {
      try {
        await localServers.start(id);
        connectionRepository.register(localServers.connectionConfig(id));
      } on McpException catch (error) {
        _builtInFailures[id] = error.error.message;
      } on Object {
        _builtInFailures[id] = 'Встроенный MCP-сервер не запустился.';
      }
    }
    await host.start();
    await feature.initialize();
    final stack = automation;
    if (stack != null) {
      await stack.service.start();
      automationObserver?.attach();
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    automationObserver?.detach();
    try {
      await automation?.service.stop();
    } on Object {
      // Scheduler shutdown is best effort; the app is closing.
    }
    pins.clear();
    tasks?.dispose();
    taskEditor?.dispose();
    library?.dispose();
    chatDeliveryStore?.dispose();
    feature.dispose();
    bridge.dispose();
    try {
      await host.stop();
    } on Object {
      // Connection shutdown is best effort.
    }
    host.dispose();
    try {
      await localServers.stopAll();
    } on Object {
      // Local server shutdown is best effort.
    }
    arxivFactory.dispose();
  }
}

/// Delivery sink of the automation stack, or null when no durable card store
/// exists on this platform (the tasks UI then reports delivery unavailable).
ChatCompletionsDialect _dialectForReasoningFormat(
  ApiKeyProviderReasoningFormat format,
) => switch (format) {
  ApiKeyProviderReasoningFormat.none => ChatCompletionsDialect.generic,
  ApiKeyProviderReasoningFormat.openAiEffort =>
    ChatCompletionsDialect.openAiReasoningEffort,
  ApiKeyProviderReasoningFormat.deepSeekThinking =>
    ChatCompletionsDialect.catalogDeepSeekThinking,
  ApiKeyProviderReasoningFormat.zaiThinking =>
    ChatCompletionsDialect.zaiThinking,
  ApiKeyProviderReasoningFormat.qwenThinking =>
    ChatCompletionsDialect.qwenThinking,
  ApiKeyProviderReasoningFormat.openRouterReasoning =>
    ChatCompletionsDialect.openRouterReasoning,
  ApiKeyProviderReasoningFormat.antLingReasoning =>
    ChatCompletionsDialect.antLingReasoning,
  ApiKeyProviderReasoningFormat.togetherReasoning =>
    ChatCompletionsDialect.togetherReasoning,
};

String _newRuntimeNamespace() {
  final random = Random.secure();
  final nonce = List<String>.generate(
    4,
    (_) => random.nextInt(1 << 30).toRadixString(36),
  ).join('-');
  return 'runtime-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$nonce';
}

/// Fail-closed placeholder for the stable `allow` policy id.
///
/// `buildProductionAgentStack` publishes it synchronously, so legacy sessions
/// resolve the same policy id they always used; [DomovoyMcpComposition.build]
/// replaces the map entry with the composed permission policy before any run
/// can start. Until then every call is denied.
final class _McpInteractivePolicySlot implements ToolPermissionPolicy {
  @override
  PolicyId get id => PolicyId('allow');

  @override
  ToolPermission decide(ToolInvocation invocation) => ToolPermission.deny;
}

final class DomovoyDependencies {
  DomovoyDependencies({
    required this.runtime,
    required this.registry,
    required this.promptDefinition,
    required this.repository,
    required this.catalog,
    this.providerModelCatalog,
    this.providerCredentialStore,
    this.environmentReader,
    required this.overrideStore,
    required this.apiKeyResolver,
    this.projectStack,
    this.memoryInspector,
    this.profileController,
    this.profileInterviewLlm,
    this.mcp,
    DeepSeekModelSettingsStore? modelSettingsStore,
    http.Client? httpClient,
    this.disposeCallback,
  }) : modelSettingsStore =
           modelSettingsStore ?? InMemoryDeepSeekModelSettingsStore(),
       _httpClient = httpClient;

  factory DomovoyDependencies.production({
    http.Client? httpClient,
    ProviderCredentialStore? credentialStore,
    McpCompositionInputs? mcpInputs,
  }) {
    const storage = FlutterSecureStorage();
    final overrideStore = SecureApiKeyOverrideStore(storage);
    final modelSettingsStore = SecureDeepSeekModelSettingsStore(storage);
    const environment = PlatformEnvironmentReader();
    final resolver = ApiKeyResolver(
      overrideStore: overrideStore,
      environment: environment,
    );
    final client = httpClient ?? http.Client();
    final providerCredentialStore =
        credentialStore ??
        NamespacedProviderCredentialStore(FlutterSecureStringStore(storage));
    final credentials = DefaultProviderCredentialResolver(
      store: providerCredentialStore,
      readEnvironment: environment.read,
    );
    final memoryToggles = MemoryReadTogglesController();
    final memoryStack = MemoryJsonlStack(
      storage: createPlatformMemoryJsonlStreamStorage(),
    );
    final memoryRepositories = MemoryRepositories(
      workingRepository: memoryStack.workingRepository,
      longTermRepository: memoryStack.longTermRepository,
      candidateRepository: memoryStack.candidateRepository,
    );
    final memoryRetrieval = LayeredMemoryRetrievalService(
      repositories: memoryRepositories,
    );
    final profileRepository = JsonlProfileRepository(
      storage: createPlatformProfileJsonlStreamStorage(),
    );
    final profileCatalog = ProfileCatalogService(
      profiles: profileRepository,
      activeProfile: profileRepository,
      nowMicros: () => DateTime.now().microsecondsSinceEpoch,
    );
    final projectStack = createPlatformProjectStack();
    final localTools = createLocalWorkspaceTools(projectStack);
    // The interactive policy starts fail-closed and is replaced by the MCP
    // composition below; no run can start before that replacement happens.
    final interactivePolicy = _McpInteractivePolicySlot();
    final stack = buildProductionAgentStack(
      httpClient: client,
      credentials: credentials,
      tools: localTools.registry,
      enabledTools: localTools.enabled,
      interactivePolicy: interactivePolicy,
      dynamicContextProvider:
          CompositeAgentDynamicContextProvider(<AgentDynamicContextProvider>[
            PersonalizationDynamicContextProvider(catalog: profileCatalog),
            MemoryDynamicContextProvider(
              retrieval: memoryRetrieval,
              toggles: memoryToggles,
            ),
          ]),
    );
    final aurora = isAuroraBuildFlavor;
    final resolvedMcpInputs =
        mcpInputs ??
        McpCompositionInputs(
          connectionStorage: createPlatformMcpJsonlStreamStorage(),
          selectionStorage: createPlatformMcpJsonlStreamStorage(),
          libraryStorage: createPlatformLibraryJsonlStreamStorage(),
          automationStorage: createPlatformAutomationJsonlStreamStorage(),
          automationChatStorage:
              createPlatformAutomationChatJsonlStreamStorage(),
          secretVault: FlutterSecureMcpSecretVault(
            FlutterSecureStringStore(storage),
          ),
          capabilities: aurora
              ? McpPlatformCapabilities.aurora
              : defaultMcpPlatformCapabilities(),
          forceDisableStdio: aurora,
          stdioDisabledReason: aurora ? auroraStdioDisabledReason : null,
          pauseAutomationInBackground: aurora,
          localTransportPreference: aurora
              ? McpLocalTransportPreference.stream
              : McpLocalTransportPreference.auto,
          useDesktopSidecar:
              !aurora &&
              !kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.linux ||
                  defaultTargetPlatform == TargetPlatform.windows ||
                  defaultTargetPlatform == TargetPlatform.macOS),
        );
    final mcp = DomovoyMcpComposition.build(
      runtime: stack.runtime,
      tools: stack.runtime.tools,
      policies: stack.runtime.policies,
      registry: stack.registry,
      sessions: stack.repository,
      catalog: stack.catalog,
      piToolIds: <String>{for (final id in localTools.enabled) id.value},
      inputs: resolvedMcpInputs,
    );
    final profileController = ProfileController(
      profiles: profileRepository,
      activeProfile: profileRepository,
      catalog: profileCatalog,
      nowMicros: () => DateTime.now().microsecondsSinceEpoch,
      preferences: SharedPreferencesProfilePreferenceRepository(),
    );
    final profileInterviewLlm = AgentProfileInterviewLlm(
      runtime: stack.runtime,
      definition: AgentProfileInterviewLlm.definitionFrom(
        stack.promptDefinition,
      ),
    );
    final memoryExtractionLlm = RegistryMemoryExtractionLlmInvocation(
      stack.registry,
    );
    final memoryExtraction = MemoryExtractionCoordinator(
      extractor: LlmMemoryBatchExtractor(
        llm: memoryExtractionLlm,
        model: stack.promptDefinition.model,
      ),
      commandClassifier: LlmMemoryCommandClassifier(
        llm: memoryExtractionLlm,
        model: stack.promptDefinition.model,
      ),
      repositories: memoryRepositories,
      checkpoints: memoryStack.extractionCheckpointRepository,
      clock: SystemAgentClock(),
      ids: MemoryExtractionIdFactory(namespace: 'extract'),
    );
    final memoryInspector = MemoryInspectorController(
      repositories: memoryRepositories,
      retrieval: memoryRetrieval,
      toggles: memoryToggles,
      extraction: memoryExtraction,
    );
    return DomovoyDependencies(
      runtime: stack.runtime,
      registry: stack.registry,
      promptDefinition: stack.promptDefinition,
      repository: stack.repository,
      catalog: stack.catalog,
      providerModelCatalog: stack.providerModelCatalog,
      providerCredentialStore: providerCredentialStore,
      environmentReader: environment.read,
      overrideStore: overrideStore,
      apiKeyResolver: resolver,
      modelSettingsStore: modelSettingsStore,
      httpClient: client,
      projectStack: projectStack,
      memoryInspector: memoryInspector,
      profileController: profileController,
      profileInterviewLlm: profileInterviewLlm,
      mcp: mcp,
    );
  }

  final AgentRuntime runtime;
  final LlmProviderRegistry registry;
  final AgentDefinition promptDefinition;
  final AgentSessionRepository repository;
  final AgentSessionCatalog catalog;
  final ProviderModelCatalog? providerModelCatalog;
  final ProviderCredentialStore? providerCredentialStore;
  final EnvironmentVariableReader? environmentReader;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver apiKeyResolver;
  final DeepSeekModelSettingsStore modelSettingsStore;
  final ProjectPlatformStack? projectStack;
  final MemoryInspectorController? memoryInspector;
  final ProfileController? profileController;
  final ProfileInterviewLlm? profileInterviewLlm;
  final DomovoyMcpComposition? mcp;
  final VoidCallback? disposeCallback;
  final http.Client? _httpClient;
  Future<void>? _closeFuture;
  Future<void>? _mcpInitializationFuture;

  /// Starts built-in MCP servers, connects configured clients and loads the
  /// durable permission store. Called by the app shell after the first frame
  /// so the UI can show statuses while connections settle.
  Future<void> initializeMcp() {
    final composition = mcp;
    if (composition == null) {
      return Future<void>.value();
    }
    return _mcpInitializationFuture ??= composition.initialize();
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    AgentError? firstError;
    try {
      memoryInspector?.dispose();
      profileController?.dispose();
    } on Object catch (error) {
      firstError = sanitizeCloseFailure(error);
    }
    try {
      await mcp?.close();
    } on Object catch (error) {
      firstError ??= sanitizeCloseFailure(error);
    }
    try {
      await runtime.close();
    } on Object catch (error) {
      firstError ??= sanitizeCloseFailure(error);
    }
    try {
      await providerModelCatalog?.close();
      _httpClient?.close();
    } on Object catch (error) {
      firstError ??= sanitizeCloseFailure(error);
    }
    try {
      disposeCallback?.call();
    } on Object catch (error) {
      firstError ??= sanitizeCloseFailure(error);
    }
    if (firstError != null) {
      throw AgentException(firstError);
    }
  }

  void dispose() {
    unawaited(
      close().catchError((Object error, StackTrace stackTrace) {
        return;
      }),
    );
  }
}

class DomovoyApp extends StatefulWidget {
  const DomovoyApp({required this.dependencies, super.key});

  factory DomovoyApp.production() {
    return DomovoyApp(dependencies: DomovoyDependencies.production());
  }

  final DomovoyDependencies dependencies;

  @override
  State<DomovoyApp> createState() => _DomovoyAppState();
}

class _DomovoyAppState extends State<DomovoyApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final ChatWorkspaceController _chatController;
  ProjectWorkspaceController? _projectController;
  var _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final dependencies = widget.dependencies;
    unawaited(dependencies.profileController?.initialize());
    unawaited(
      dependencies.initializeMcp().catchError((Object error, StackTrace _) {
        // Connection and configuration failures are visible through the MCP
        // connection page and host snapshot; the shell stays usable.
      }),
    );
    final mcp = dependencies.mcp;
    _chatController = ChatWorkspaceController(
      runtime: dependencies.runtime,
      definition: dependencies.promptDefinition,
      catalog: dependencies.catalog,
      repository: dependencies.repository,
      registry: dependencies.registry,
      providerModelCatalog: dependencies.providerModelCatalog,
      onTurnCompleted: dependencies.memoryInspector?.recordCompletedTurn,
      chatDeliveries: mcp?.chatDeliveryStore,
      runToolContexts: mcp?.runToolContexts,
      additionalRunTools: mcp == null
          ? null
          : (snapshot) => <ToolId>[
              for (final id in mcp.feature.toolAccess.effectiveToolIds(
                chatId: snapshot.id,
                projectId: snapshot.projectId,
              ))
                ToolId(id),
            ],
      settingsLauncher: _ApiKeyDialogLauncher(
        navigatorKey: _navigatorKey,
        overrideStore: dependencies.overrideStore,
        resolver: dependencies.apiKeyResolver,
        modelSettingsStore: dependencies.modelSettingsStore,
        providerCredentialStore: dependencies.providerCredentialStore,
        environmentReader: dependencies.environmentReader,
        providerModelCatalog: dependencies.providerModelCatalog,
      ),
    );
    final projectStack = dependencies.projectStack;
    if (projectStack != null) {
      _projectController = ProjectWorkspaceController(
        service: ProjectApplicationService(
          projects: projectStack.repository,
          projectCatalog: projectStack.catalog,
          sessions: dependencies.repository,
          sessionCatalog: dependencies.catalog,
          provisioner: projectStack.provisioner,
          grants: projectStack.grants,
        ),
        projects: projectStack.repository,
        projectCatalog: projectStack.catalog,
        sessionCatalog: dependencies.catalog,
        chat: _chatController,
        grants: projectStack.grants,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(
      (_projectController?.dispose() ?? Future<void>.value())
          .then((_) => _chatController.dispose())
          .then((_) => widget.dependencies.close())
          .catchError((Object error, StackTrace stackTrace) {
            return;
          }),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final memory = widget.dependencies.memoryInspector;
    if (memory == null) {
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(memory.resumeExtraction());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        memory.pauseExtraction();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Domovoy',
      debugShowCheckedModeBanner: false,
      theme: DomovoyTheme.light(),
      darkTheme: DomovoyTheme.dark(),
      themeMode: _themeMode,
      home: _projectController == null
          ? ChatWorkspacePage(
              controller: _chatController,
              memory: widget.dependencies.memoryInspector,
              profiles: widget.dependencies.profileController,
              profileInterviewLlm: widget.dependencies.profileInterviewLlm,
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
              providersView: _providersView(),
              mcpToolAccess: widget.dependencies.mcp?.feature.toolAccess,
              onOpenTasks: _openTasks,
              onOpenLibrary: _openLibrary,
              onOpenMcpConnections: _openMcpConnections,
            )
          : ProjectWorkspacePage(
              controller: _projectController!,
              memory: widget.dependencies.memoryInspector,
              profiles: widget.dependencies.profileController,
              profileInterviewLlm: widget.dependencies.profileInterviewLlm,
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
              providersView: _providersView(),
              mcpToolAccess: widget.dependencies.mcp?.feature.toolAccess,
              onOpenTasks: _openTasks,
              onOpenLibrary: _openLibrary,
              onOpenMcpConnections: _openMcpConnections,
            ),
    );
  }

  void _setThemeMode(ThemeMode mode) => setState(() => _themeMode = mode);

  VoidCallback? get _openTasks {
    final composition = widget.dependencies.mcp;
    if (composition == null ||
        composition.tasks == null ||
        composition.taskEditor == null) {
      return null;
    }
    return () => _pushSection(
      _TasksSection(
        dependencies: widget.dependencies,
        composition: composition,
      ),
    );
  }

  VoidCallback? get _openLibrary {
    final composition = widget.dependencies.mcp;
    if (composition == null || composition.library == null) {
      return null;
    }
    return () =>
        _pushSection(_LibrarySection(controller: composition.library!));
  }

  VoidCallback? get _openMcpConnections {
    final composition = widget.dependencies.mcp;
    if (composition == null) {
      return null;
    }
    return () => _pushSection(
      Scaffold(
        appBar: AppBar(title: const Text('MCP-подключения')),
        body: composition.feature.buildConnectionsPage(),
      ),
    );
  }

  void _pushSection(Widget page) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      return;
    }
    navigator
        .push<void>(MaterialPageRoute<void>(builder: (_) => page))
        .ignore();
  }

  Widget? _providersView() {
    final dependencies = widget.dependencies;
    final store = dependencies.providerCredentialStore;
    final environment = dependencies.environmentReader;
    if (store == null || environment == null) return null;
    return ProviderApiKeysDialog(
      store: store,
      environment: environment,
      catalog: dependencies.providerModelCatalog,
      embedded: true,
    );
  }
}

final class _ApiKeyDialogLauncher implements ChatSettingsLauncher {
  const _ApiKeyDialogLauncher({
    required this.navigatorKey,
    required this.overrideStore,
    required this.resolver,
    required this.modelSettingsStore,
    this.providerCredentialStore,
    this.environmentReader,
    this.providerModelCatalog,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver resolver;
  final DeepSeekModelSettingsStore modelSettingsStore;
  final ProviderCredentialStore? providerCredentialStore;
  final EnvironmentVariableReader? environmentReader;
  final ProviderModelCatalog? providerModelCatalog;

  @override
  Future<void> openSettings() {
    final context = navigatorKey.currentContext;
    if (context == null) {
      throw StateError('Workspace navigator is not ready.');
    }
    if (providerCredentialStore != null && environmentReader != null) {
      return showProviderApiKeysDialog(
        context: context,
        store: providerCredentialStore!,
        environment: environmentReader!,
        catalog: providerModelCatalog,
      );
    }
    return showApiKeySettingsDialog(
      context: context,
      overrideStore: overrideStore,
      resolver: resolver,
      isWeb: kIsWeb,
      modelSettingsStore: modelSettingsStore,
    );
  }
}

/// Tasks section route: the page keeps the same controller/service instances
/// as the rest of the application, and [TasksPage.availableModels] is rebuilt
/// from the live provider catalog on every discovery snapshot.
class _TasksSection extends StatelessWidget {
  const _TasksSection({required this.dependencies, required this.composition});

  final DomovoyDependencies dependencies;
  final DomovoyMcpComposition composition;

  @override
  Widget build(BuildContext context) {
    final tasks = composition.tasks!;
    final editor = composition.taskEditor!;
    return StreamBuilder<ProviderCatalogSnapshot>(
      stream: dependencies.providerModelCatalog?.updates,
      builder: (context, snapshot) => TasksPage(
        controller: tasks,
        editor: editor,
        availableModels: <ModelRef>[
          for (final model in dependencies.registry.models) model.ref,
        ],
      ),
    );
  }
}

/// Library section route over the single `library` MCP read API.
class _LibrarySection extends StatelessWidget {
  const _LibrarySection({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) => LibraryPage(controller: controller);
}

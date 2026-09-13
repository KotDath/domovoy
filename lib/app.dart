import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'core/agents/agents.dart';
import 'core/environment/platform_environment_reader.dart';
import 'core/llm/llm.dart';
import 'design_system/design_system.dart';
import 'features/chat/application/chat_workspace_controller.dart';
import 'features/chat/presentation/chat_workspace_page.dart';
import 'features/prompt/domain/prompt_workspace.dart';
import 'features/settings/data/secure_api_key_override_store.dart';
import 'features/settings/data/secure_model_settings_store.dart';
import 'features/settings/domain/api_key_credentials.dart';
import 'features/settings/domain/model_settings.dart';
import 'features/settings/presentation/api_key_settings_dialog.dart';
import 'infrastructure/credentials/credentials.dart';
import 'infrastructure/agents/jsonl/jsonl.dart';
import 'infrastructure/llm/openai_compatible/openai_compatible.dart';
import 'infrastructure/llm/openai_responses/openai_responses.dart';

final class ProductionAgentStack {
  ProductionAgentStack({
    required this.registry,
    required this.runtime,
    required this.promptDefinition,
    required this.credentials,
    required this.repository,
    required this.catalog,
  });

  final LlmProviderRegistry registry;
  final InMemoryAgentRuntime runtime;
  final AgentDefinition promptDefinition;
  final ProviderCredentialResolver credentials;
  final AgentSessionRepository repository;
  final AgentSessionCatalog catalog;
}

ProductionAgentStack buildProductionAgentStack({
  required http.Client httpClient,
  required ProviderCredentialResolver credentials,
  AgentSessionRepository? repository,
  AgentSessionCatalog? catalog,
}) {
  if ((repository == null) != (catalog == null)) {
    throw ArgumentError(
      'Repository and catalog replacements must be supplied together.',
    );
  }
  final durableStore = repository == null
      ? JsonlAgentSessionStore(storage: createPlatformJsonlStreamStorage())
      : null;
  final resolvedRepository = repository ?? durableStore!;
  final resolvedCatalog = catalog ?? durableStore!;
  final deepSeek = OpenAiCompatibleProfile.deepSeek();
  final moonshot = OpenAiCompatibleProfile.moonshotAi();
  final openAi = OpenAiResponsesProfile.builtIn();
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  registry.registerProvider(
    OpenAiChatCompletionsLlmProvider(
      profile: deepSeek,
      client: httpClient,
      credentials: credentials,
    ),
  );
  registry.registerProvider(
    OpenAiChatCompletionsLlmProvider(
      profile: moonshot,
      client: httpClient,
      credentials: credentials,
    ),
  );
  registry.registerProvider(
    OpenAiResponsesLlmProvider(
      profile: openAi,
      client: httpClient,
      credentials: credentials,
    ),
  );
  const contextEstimator = Utf8FramingAgentContextEstimator();
  final compactionTrigger = OpenCodeCompactionTrigger();
  final modelSwitchFitPolicy = OpenCodeAgentModelSwitchFitPolicy();
  final historyCompactor = OpenCodeSummaryCompactor(
    llm: RegistryAgentSummaryLlmInvocation(registry),
    contextEstimator: contextEstimator,
  );
  final runtime = InMemoryAgentRuntime(
    registry: registry,
    tools: AgentToolRegistry(),
    policies: <String, ToolPermissionPolicy>{
      'deny': const DenyAllPolicy(),
      'allow': const AllowAllPolicy(),
    },
    repository: resolvedRepository,
    router: InMemorySessionRouter(),
    profile: AgentRuntimeProfile(),
    contextEstimator: contextEstimator,
    compactionTrigger: compactionTrigger,
    modelSwitchFitPolicy: modelSwitchFitPolicy,
    historyCompactor: historyCompactor,
  );
  return ProductionAgentStack(
    registry: registry,
    runtime: runtime,
    promptDefinition: PromptWorkspace.definition(),
    credentials: credentials,
    repository: resolvedRepository,
    catalog: resolvedCatalog,
  );
}

final class DomovoyDependencies {
  DomovoyDependencies({
    required this.runtime,
    required this.registry,
    required this.promptDefinition,
    required this.repository,
    required this.catalog,
    required this.overrideStore,
    required this.apiKeyResolver,
    DeepSeekModelSettingsStore? modelSettingsStore,
    http.Client? httpClient,
    this.disposeCallback,
  }) : modelSettingsStore =
           modelSettingsStore ?? InMemoryDeepSeekModelSettingsStore(),
       _httpClient = httpClient;

  factory DomovoyDependencies.production() {
    const storage = FlutterSecureStorage();
    final overrideStore = SecureApiKeyOverrideStore(storage);
    final modelSettingsStore = SecureDeepSeekModelSettingsStore(storage);
    const environment = PlatformEnvironmentReader();
    final resolver = ApiKeyResolver(
      overrideStore: overrideStore,
      environment: environment,
    );
    final client = http.Client();
    final credentials = DefaultProviderCredentialResolver(
      store: NamespacedProviderCredentialStore(
        FlutterSecureStringStore(storage),
      ),
      readEnvironment: environment.read,
    );
    final stack = buildProductionAgentStack(
      httpClient: client,
      credentials: credentials,
    );
    return DomovoyDependencies(
      runtime: stack.runtime,
      registry: stack.registry,
      promptDefinition: stack.promptDefinition,
      repository: stack.repository,
      catalog: stack.catalog,
      overrideStore: overrideStore,
      apiKeyResolver: resolver,
      modelSettingsStore: modelSettingsStore,
      httpClient: client,
    );
  }

  final AgentRuntime runtime;
  final LlmProviderRegistry registry;
  final AgentDefinition promptDefinition;
  final AgentSessionRepository repository;
  final AgentSessionCatalog catalog;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver apiKeyResolver;
  final DeepSeekModelSettingsStore modelSettingsStore;
  final VoidCallback? disposeCallback;
  final http.Client? _httpClient;
  Future<void>? _closeFuture;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    AgentError? firstError;
    try {
      await runtime.close();
    } on Object catch (error) {
      firstError = sanitizeCloseFailure(error);
    }
    try {
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

class _DomovoyAppState extends State<DomovoyApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final ChatWorkspaceController _chatController;

  @override
  void initState() {
    super.initState();
    final dependencies = widget.dependencies;
    _chatController = ChatWorkspaceController(
      runtime: dependencies.runtime,
      definition: dependencies.promptDefinition,
      catalog: dependencies.catalog,
      repository: dependencies.repository,
      registry: dependencies.registry,
      settingsLauncher: _ApiKeyDialogLauncher(
        navigatorKey: _navigatorKey,
        overrideStore: dependencies.overrideStore,
        resolver: dependencies.apiKeyResolver,
        modelSettingsStore: dependencies.modelSettingsStore,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(
      _chatController
          .dispose()
          .then((_) => widget.dependencies.close())
          .catchError((Object error, StackTrace stackTrace) {
            return;
          }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Domovoy',
      debugShowCheckedModeBanner: false,
      theme: DomovoyTheme.light(),
      darkTheme: DomovoyTheme.dark(),
      themeMode: ThemeMode.dark,
      home: ChatWorkspacePage(controller: _chatController),
    );
  }
}

final class _ApiKeyDialogLauncher implements ChatSettingsLauncher {
  const _ApiKeyDialogLauncher({
    required this.navigatorKey,
    required this.overrideStore,
    required this.resolver,
    required this.modelSettingsStore,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver resolver;
  final DeepSeekModelSettingsStore modelSettingsStore;

  @override
  Future<void> openSettings() {
    final context = navigatorKey.currentContext;
    if (context == null) {
      throw StateError('Workspace navigator is not ready.');
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

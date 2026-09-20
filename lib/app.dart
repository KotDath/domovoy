import 'dart:async';
import 'dart:math';

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
import 'features/projects/application/project_application_service.dart';
import 'features/projects/application/project_workspace_controller.dart';
import 'features/projects/presentation/project_workspace_page.dart';
import 'features/prompt/domain/prompt_workspace.dart';
import 'features/settings/data/secure_api_key_override_store.dart';
import 'features/settings/data/secure_model_settings_store.dart';
import 'features/settings/domain/api_key_credentials.dart';
import 'features/settings/domain/model_settings.dart';
import 'features/settings/presentation/api_key_settings_dialog.dart';
import 'features/settings/presentation/provider_api_keys_dialog.dart';
import 'infrastructure/credentials/credentials.dart';
import 'infrastructure/agents/jsonl/jsonl.dart';
import 'infrastructure/projects/platform_projects.dart';
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
    compactionTrigger: diagnosticNoCompaction ? null : compactionTrigger,
    modelSwitchFitPolicy: modelSwitchFitPolicy,
    historyCompactor: diagnosticNoCompaction ? null : historyCompactor,
    ids: ids ?? AgentIdFactory(namespace: _newRuntimeNamespace()),
  );
  return ProductionAgentStack(
    registry: registry,
    runtime: runtime,
    promptDefinition: PromptWorkspace.definition(),
    credentials: credentials,
    repository: resolvedRepository,
    catalog: resolvedCatalog,
    providerModelCatalog: providerModelCatalog,
  );
}

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
    DeepSeekModelSettingsStore? modelSettingsStore,
    http.Client? httpClient,
    this.disposeCallback,
  }) : modelSettingsStore =
           modelSettingsStore ?? InMemoryDeepSeekModelSettingsStore(),
       _httpClient = httpClient;

  factory DomovoyDependencies.production({
    http.Client? httpClient,
    ProviderCredentialStore? credentialStore,
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
      providerModelCatalog: stack.providerModelCatalog,
      providerCredentialStore: providerCredentialStore,
      environmentReader: environment.read,
      overrideStore: overrideStore,
      apiKeyResolver: resolver,
      modelSettingsStore: modelSettingsStore,
      httpClient: client,
      projectStack: createPlatformProjectStack(),
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

class _DomovoyAppState extends State<DomovoyApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final ChatWorkspaceController _chatController;
  ProjectWorkspaceController? _projectController;
  var _themeMode = ThemeMode.system;

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
      providerModelCatalog: dependencies.providerModelCatalog,
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
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
              providersView: _providersView(),
            )
          : ProjectWorkspacePage(
              controller: _projectController!,
              themeMode: _themeMode,
              onThemeModeChanged: _setThemeMode,
              providersView: _providersView(),
            ),
    );
  }

  void _setThemeMode(ThemeMode mode) => setState(() => _themeMode = mode);

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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'core/agents/agents.dart';
import 'core/environment/platform_environment_reader.dart';
import 'core/llm/llm.dart';
import 'features/prompt/domain/prompt_workspace.dart';
import 'features/prompt/presentation/prompt_page.dart';
import 'features/settings/data/secure_api_key_override_store.dart';
import 'features/settings/data/secure_model_settings_store.dart';
import 'features/settings/domain/api_key_credentials.dart';
import 'features/settings/domain/model_settings.dart';
import 'infrastructure/credentials/credentials.dart';
import 'infrastructure/llm/openai_compatible/openai_compatible.dart';
import 'infrastructure/llm/openai_responses/openai_responses.dart';

final class ProductionAgentStack {
  ProductionAgentStack({
    required this.registry,
    required this.runtime,
    required this.promptDefinition,
    required this.credentials,
  });

  final LlmProviderRegistry registry;
  final InMemoryAgentRuntime runtime;
  final AgentDefinition promptDefinition;
  final ProviderCredentialResolver credentials;
}

ProductionAgentStack buildProductionAgentStack({
  required http.Client httpClient,
  required ProviderCredentialResolver credentials,
}) {
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
  final runtime = InMemoryAgentRuntime(
    registry: registry,
    tools: AgentToolRegistry(),
    policies: <String, ToolPermissionPolicy>{
      'deny': const DenyAllPolicy(),
      'allow': const AllowAllPolicy(),
    },
    repository: InMemoryAgentSessionRepository(),
    router: InMemorySessionRouter(),
    profile: AgentRuntimeProfile(),
  );
  return ProductionAgentStack(
    registry: registry,
    runtime: runtime,
    promptDefinition: PromptWorkspace.definition(),
    credentials: credentials,
  );
}

final class DomovoyDependencies {
  DomovoyDependencies({
    required this.runtime,
    required this.promptDefinition,
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
      promptDefinition: stack.promptDefinition,
      overrideStore: overrideStore,
      apiKeyResolver: resolver,
      modelSettingsStore: modelSettingsStore,
      httpClient: client,
    );
  }

  final AgentRuntime runtime;
  final AgentDefinition promptDefinition;
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
  @override
  void dispose() {
    unawaited(
      widget.dependencies.close().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        return;
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = widget.dependencies;
    return MaterialApp(
      title: 'Domovoy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: PromptPage(
        key: const ValueKey('prompt-destination'),
        runtime: dependencies.runtime,
        promptDefinition: dependencies.promptDefinition,
        overrideStore: dependencies.overrideStore,
        apiKeyResolver: dependencies.apiKeyResolver,
        modelSettingsStore: dependencies.modelSettingsStore,
      ),
    );
  }
}

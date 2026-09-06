import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'core/environment/platform_environment_reader.dart';
import 'core/environment/environment_reader.dart';
import 'features/comparison/data/comparison_profile_store.dart';
import 'features/comparison/data/profile_agent_factory.dart';
import 'features/comparison/data/profile_credential_resolver.dart';
import 'features/comparison/presentation/comparison_page.dart';
import 'features/comparison/presentation/comparison_profile_catalog.dart';
import 'features/lab/presentation/lab_page.dart';
import 'features/prompt/data/chat_completions_provider_profile.dart';
import 'features/reasoning/presentation/reasoning_page.dart';
import 'features/prompt/data/openai_compatible_chat_agent.dart';
import 'features/prompt/domain/agent.dart';
import 'features/prompt/presentation/prompt_page.dart';
import 'features/temperature/presentation/temperature_page.dart';
import 'features/settings/data/secure_api_key_override_store.dart';
import 'features/settings/data/secure_model_settings_store.dart';
import 'features/settings/domain/api_key_credentials.dart';
import 'features/settings/domain/model_settings.dart';
import 'features/settings/presentation/reasoning_settings.dart';

final class DomovoyDependencies {
  DomovoyDependencies({
    required this.agent,
    required this.overrideStore,
    required this.apiKeyResolver,
    DeepSeekModelSettingsStore? modelSettingsStore,
    ComparisonProfileStore? comparisonProfileStore,
    ProfileApiKeyOverrideStore? profileOverrideStore,
    ComparisonAgentFactory? comparisonAgentFactory,
    EnvironmentReader? environment,
    this.disposeCallback,
  }) : modelSettingsStore =
           modelSettingsStore ?? InMemoryDeepSeekModelSettingsStore(),
       comparisonProfileStore =
           comparisonProfileStore ?? InMemoryComparisonProfileStore(),
       profileOverrideStore =
           profileOverrideStore ?? InMemoryProfileApiKeyOverrideStore(),
       environment = environment ?? const MapEnvironmentReader({}),
       comparisonAgentFactory = comparisonAgentFactory ?? ((profile) => agent);

  factory DomovoyDependencies.production() {
    const storage = FlutterSecureStorage();
    final overrideStore = SecureApiKeyOverrideStore(storage);
    final modelSettingsStore = SecureDeepSeekModelSettingsStore(storage);
    final comparisonProfileStore = SecureComparisonProfileStore(storage);
    final profileOverrideStore = SecureProfileApiKeyOverrideStore(storage);
    const environment = PlatformEnvironmentReader();
    final resolver = ApiKeyResolver(
      overrideStore: overrideStore,
      environment: environment,
    );
    final client = http.Client();
    final agent = OpenAiCompatibleChatAgent(
      client: client,
      apiKeyResolver: resolver,
      profile: ChatCompletionsProviderProfile.deepSeekV4Flash(),
    );
    final factory = ProfileChatAgentFactory(
      client: client,
      sharedDeepSeekResolver: resolver,
      profileOverrideStore: profileOverrideStore,
      environment: environment,
    );
    return DomovoyDependencies(
      agent: agent,
      overrideStore: overrideStore,
      apiKeyResolver: resolver,
      modelSettingsStore: modelSettingsStore,
      comparisonProfileStore: comparisonProfileStore,
      profileOverrideStore: profileOverrideStore,
      comparisonAgentFactory: factory.create,
      environment: environment,
      disposeCallback: client.close,
    );
  }

  final Agent agent;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver apiKeyResolver;
  final DeepSeekModelSettingsStore modelSettingsStore;
  final ComparisonProfileStore comparisonProfileStore;
  final ProfileApiKeyOverrideStore profileOverrideStore;
  final ComparisonAgentFactory comparisonAgentFactory;
  final EnvironmentReader environment;
  final VoidCallback? disposeCallback;

  void dispose() => disposeCallback?.call();
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
  int _index = 0;
  late final ReasoningSettings _reasoning;
  late final ComparisonProfileCatalog _comparisonProfiles;

  @override
  void initState() {
    super.initState();
    _reasoning = ReasoningSettings(
      store: widget.dependencies.modelSettingsStore,
    );
    _comparisonProfiles = ComparisonProfileCatalog(
      repository: ComparisonProfileRepository(
        widget.dependencies.comparisonProfileStore,
      ),
    );
    unawaited(_reasoning.load());
    unawaited(_comparisonProfiles.load());
  }

  @override
  void dispose() {
    _reasoning.dispose();
    _comparisonProfiles.dispose();
    widget.dependencies.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (_index == index) {
      return;
    }
    setState(() => _index = index);
    if (index == 1) {
      // The laboratory stays alive inside the IndexedStack, so refresh the
      // shared reasoning state explicitly when it becomes active again.
      unawaited(_reasoning.load());
    }
    if (index == 4) {
      unawaited(_comparisonProfiles.load());
    }
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
      home: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            PromptPage(
              key: const ValueKey('prompt-destination'),
              agent: dependencies.agent,
              overrideStore: dependencies.overrideStore,
              apiKeyResolver: dependencies.apiKeyResolver,
              modelSettingsStore: dependencies.modelSettingsStore,
              reasoningSettings: _reasoning,
              onOpenLab: () => _select(1),
            ),
            LabPage(
              key: const ValueKey('lab-destination'),
              agent: dependencies.agent,
              overrideStore: dependencies.overrideStore,
              apiKeyResolver: dependencies.apiKeyResolver,
              modelSettingsStore: dependencies.modelSettingsStore,
              reasoningSettings: _reasoning,
            ),
            ReasoningPage(
              key: const ValueKey('reasoning-destination'),
              agent: dependencies.agent,
              overrideStore: dependencies.overrideStore,
              apiKeyResolver: dependencies.apiKeyResolver,
              modelSettingsStore: dependencies.modelSettingsStore,
            ),
            TemperaturePage(
              key: const ValueKey('temperature-destination'),
              agent: dependencies.agent,
              overrideStore: dependencies.overrideStore,
              apiKeyResolver: dependencies.apiKeyResolver,
              modelSettingsStore: dependencies.modelSettingsStore,
            ),
            ComparisonPage(
              key: const ValueKey('comparison-destination'),
              agentFactory: dependencies.comparisonAgentFactory,
              catalog: _comparisonProfiles,
              sharedDeepSeekResolver: dependencies.apiKeyResolver,
              profileOverrideStore: dependencies.profileOverrideStore,
              environment: dependencies.environment,
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: const [
            NavigationDestination(
              key: ValueKey('nav-prompt'),
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Запрос',
            ),
            NavigationDestination(
              key: ValueKey('nav-lab'),
              icon: Icon(Icons.science_outlined),
              selectedIcon: Icon(Icons.science),
              label: 'День 2',
            ),
            NavigationDestination(
              key: ValueKey('nav-reasoning'),
              icon: Icon(Icons.psychology_outlined),
              selectedIcon: Icon(Icons.psychology),
              label: 'День 3',
            ),
            NavigationDestination(
              key: ValueKey('nav-temperature'),
              icon: Icon(Icons.thermostat_outlined),
              selectedIcon: Icon(Icons.thermostat),
              label: 'День 4',
            ),
            NavigationDestination(
              key: ValueKey('nav-comparison'),
              icon: Icon(Icons.compare_outlined),
              selectedIcon: Icon(Icons.compare),
              label: 'День 5',
            ),
          ],
        ),
      ),
    );
  }
}

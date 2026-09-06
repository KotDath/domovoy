import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'core/environment/platform_environment_reader.dart';
import 'features/lab/presentation/lab_page.dart';
import 'features/prompt/data/chat_completions_provider_profile.dart';
import 'features/prompt/data/openai_compatible_chat_agent.dart';
import 'features/prompt/domain/agent.dart';
import 'features/prompt/presentation/prompt_page.dart';
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
    this.disposeCallback,
  }) : modelSettingsStore =
           modelSettingsStore ?? InMemoryDeepSeekModelSettingsStore();

  factory DomovoyDependencies.production() {
    const storage = FlutterSecureStorage();
    final overrideStore = SecureApiKeyOverrideStore(storage);
    final modelSettingsStore = SecureDeepSeekModelSettingsStore(storage);
    final resolver = ApiKeyResolver(
      overrideStore: overrideStore,
      environment: const PlatformEnvironmentReader(),
    );
    final client = http.Client();
    final agent = OpenAiCompatibleChatAgent(
      client: client,
      apiKeyResolver: resolver,
      profile: ChatCompletionsProviderProfile.deepSeekV4Flash(),
    );
    return DomovoyDependencies(
      agent: agent,
      overrideStore: overrideStore,
      apiKeyResolver: resolver,
      modelSettingsStore: modelSettingsStore,
      disposeCallback: client.close,
    );
  }

  final Agent agent;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver apiKeyResolver;
  final DeepSeekModelSettingsStore modelSettingsStore;
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

  @override
  void initState() {
    super.initState();
    _reasoning = ReasoningSettings(
      store: widget.dependencies.modelSettingsStore,
    );
    unawaited(_reasoning.load());
  }

  @override
  void dispose() {
    _reasoning.dispose();
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
              label: 'Лаборатория · День 2',
            ),
          ],
        ),
      ),
    );
  }
}

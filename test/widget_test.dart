import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/prompt/domain/prompt_workspace.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/features/settings/presentation/api_key_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/agent_harness.dart';
import 'support/fakes.dart';

void main() {
  testWidgets('production destination is the durable chat workspace shell', (
    tester,
  ) async {
    final harness = _Harness();
    await _wideView(tester);
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('chat-workspace-destination')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('workspace-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.byKey(const ValueKey('prompt-destination')), findsNothing);
    expect(find.byKey(const ValueKey('prompt-input')), findsNothing);
    expect(find.byKey(const ValueKey('open-lab')), findsNothing);
    await _disposeHarness(tester, harness);
  });

  testWidgets('new chat action creates and selects a repository session', (
    tester,
  ) async {
    final harness = _Harness();
    await _wideView(tester);
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('chat-new')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-selected')), findsOneWidget);
    expect(find.text('Чат готов'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-composer-field')), findsOneWidget);
    expect((await harness.persistence.list()).available, hasLength(1));
    await _disposeHarness(tester, harness);
  });

  testWidgets('credential settings remain reachable from the workspace', (
    tester,
  ) async {
    final harness = _Harness();
    await _wideView(tester);
    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Настройки DeepSeek'), findsOneWidget);
    expect(find.byKey(const ValueKey('api-key-input')), findsOneWidget);
    expect(find.textContaining('Значение скрыто'), findsNothing);
    await _disposeHarness(tester, harness);
  });

  testWidgets('production shell moves chat navigation into a narrow drawer', (
    tester,
  ) async {
    final harness = _Harness();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-narrow')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-list')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('chat-list-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _disposeHarness(tester, harness);
  });

  testWidgets('settings save masked override and remove it to environment', (
    tester,
  ) async {
    final store = MemoryApiKeyOverrideStore();
    final resolver = ApiKeyResolver(
      overrideStore: store,
      environment: const MapEnvironmentReader({
        deepSeekApiKeyEnvironmentVariable: 'environment-key',
      }),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.light(),
        home: Scaffold(
          body: ApiKeySettingsDialog(
            overrideStore: store,
            resolver: resolver,
            isWeb: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('переменная окружения'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('api-key-input')),
      '  application-key  ',
    );
    await tester.tap(find.byKey(const ValueKey('save-api-key')));
    await tester.pumpAndSettle();
    expect(store.value, 'application-key');
    expect(find.textContaining('настроек приложения'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('api-key-input')))
          .controller
          ?.text,
      isEmpty,
    );

    await tester.tap(find.byKey(const ValueKey('remove-api-key')));
    await tester.pumpAndSettle();
    expect(store.value, isNull);
    expect(find.textContaining('переменная окружения'), findsOneWidget);
  });

  testWidgets('settings reject blank key and show browser warning', (
    tester,
  ) async {
    final store = MemoryApiKeyOverrideStore('existing');
    final resolver = ApiKeyResolver(
      overrideStore: store,
      environment: const MapEnvironmentReader({}),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.dark(),
        home: Scaffold(
          body: ApiKeySettingsDialog(
            overrideStore: store,
            resolver: resolver,
            isWeb: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('web-key-warning')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('save-api-key')));
    await tester.pump();
    expect(find.text('Введите непустой API-ключ.'), findsOneWidget);
    expect(store.value, 'existing');
  });
}

final class _Harness {
  _Harness() {
    store = MemoryApiKeyOverrideStore();
    resolver = ApiKeyResolver(
      overrideStore: store,
      environment: const MapEnvironmentReader({}),
    );
    persistence = InMemoryAgentSessionRepository();
    registry = LlmProviderRegistry();
    BuiltInLlmCatalog.registerInto(registry);
    registry.registerProvider(
      QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: const <List<LlmEvent>>[],
      ),
    );
    runtime = InMemoryAgentRuntime(
      registry: registry,
      tools: AgentToolRegistry(),
      policies: const <String, ToolPermissionPolicy>{
        'deny': DenyAllPolicy(),
        'allow': AllowAllPolicy(),
      },
      repository: persistence,
      router: InMemorySessionRouter(),
    );
    dependencies = DomovoyDependencies(
      runtime: runtime,
      registry: registry,
      promptDefinition: PromptWorkspace.definition(),
      repository: persistence,
      catalog: persistence,
      overrideStore: store,
      apiKeyResolver: resolver,
    );
  }

  late final MemoryApiKeyOverrideStore store;
  late final ApiKeyResolver resolver;
  late final InMemoryAgentSessionRepository persistence;
  late final LlmProviderRegistry registry;
  late final InMemoryAgentRuntime runtime;
  late final DomovoyDependencies dependencies;

  Widget get app => DomovoyApp(dependencies: dependencies);

  Future<void> dispose() => dependencies.close();
}

Future<void> _wideView(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 800);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _disposeHarness(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox());
  await harness.dispose();
}

import 'package:domovoy/app.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/features/settings/presentation/api_key_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('shows only the prompt workspace without laboratory navigation', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app);

    expect(find.byKey(const ValueKey('prompt-destination')), findsOneWidget);
    expect(find.byKey(const ValueKey('prompt-input')), findsOneWidget);
    expect(find.byKey(const ValueKey('output-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('submit-prompt')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-lab')), findsNothing);
    expect(find.byKey(const ValueKey('nav-prompt')), findsNothing);
    expect(find.byKey(const ValueKey('nav-lab')), findsNothing);
    expect(find.byKey(const ValueKey('nav-reasoning')), findsNothing);
    expect(find.byKey(const ValueKey('nav-temperature')), findsNothing);
    expect(find.byKey(const ValueKey('nav-comparison')), findsNothing);
    expect(find.text('День 2'), findsNothing);
    expect(find.text('День 3'), findsNothing);
    expect(find.text('День 4'), findsNothing);
    expect(find.text('День 5'), findsNothing);
  });

  testWidgets('opens credential settings from the prompt workspace', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app);

    final openSettings = tester.widget<IconButton>(
      find.byKey(const ValueKey('open-settings')),
    );
    openSettings.onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('Настройки DeepSeek'), findsOneWidget);
  });

  testWidgets('uses stacked and side-by-side responsive layouts', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    tester.view.physicalSize = const Size(700, 900);
    await tester.pumpWidget(harness.app);
    expect(find.byKey(const ValueKey('narrow-prompt-layout')), findsOneWidget);

    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wide-prompt-layout')), findsOneWidget);
  });

  testWidgets('streams reasoning and answer and toggles disclosure', (
    tester,
  ) async {
    final harness = _Harness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app);

    await tester.enterText(
      find.byKey(const ValueKey('prompt-input')),
      'Explain this',
    );
    await tester.tap(find.byKey(const ValueKey('submit-prompt')));
    await tester.pump();
    expect(find.text('Генерация…'), findsOneWidget);

    harness.agent.latest.add(const AgentReasoningDelta('reasoning'));
    harness.agent.latest.add(const AgentAnswerDelta('answer'));
    await tester.pump();
    expect(find.byKey(const ValueKey('reasoning-text')), findsOneWidget);
    expect(find.text('reasoning'), findsOneWidget);
    expect(find.text('answer'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reasoning-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('reasoning-text')), findsNothing);
    expect(find.text('answer'), findsOneWidget);

    harness.agent.latest.add(const AgentReasoningDelta(' hidden'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reasoning-toggle')));
    await tester.pump();
    expect(find.text('reasoning hidden'), findsOneWidget);

    harness.agent.latest.add(const AgentCompleted());
    await harness.agent.latest.close();
    await tester.pumpAndSettle();
    expect(find.text('Отправить'), findsOneWidget);
  });

  testWidgets('allows another independent submission after termination', (
    tester,
  ) async {
    final agent = QueueScriptedAgent(const [
      <AgentEvent>[AgentAnswerDelta('first answer'), AgentCompleted()],
      <AgentEvent>[AgentAnswerDelta('second answer'), AgentCompleted()],
    ]);
    final harness = _Harness(agent: agent);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app);

    await tester.enterText(find.byKey(const ValueKey('prompt-input')), 'first');
    await tester.tap(find.byKey(const ValueKey('submit-prompt')));
    await tester.pumpAndSettle();
    expect(find.text('first answer'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('prompt-input')),
      'second',
    );
    await tester.tap(find.byKey(const ValueKey('submit-prompt')));
    await tester.pumpAndSettle();
    expect(find.text('first answer'), findsNothing);
    expect(find.text('second answer'), findsOneWidget);
    expect(find.text('Отправить'), findsOneWidget);
  });

  testWidgets(
    'retains partial output and links missing-key error to settings',
    (tester) async {
      final failureAgent = ScriptedAgent(const <AgentEvent>[
        AgentAnswerDelta('partial'),
        AgentFailed(
          AgentFailure(
            kind: AgentFailureKind.configuration,
            message: 'Configure DEEPSEEK_API_KEY.',
          ),
        ),
      ]);
      final harness = _Harness(agent: failureAgent);
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.app);

      await tester.enterText(
        find.byKey(const ValueKey('prompt-input')),
        'Hello',
      );
      await tester.tap(find.byKey(const ValueKey('submit-prompt')));
      await tester.pumpAndSettle();

      expect(find.text('partial'), findsOneWidget);
      expect(find.byKey(const ValueKey('prompt-error')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('error-open-settings')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('error-open-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Настройки DeepSeek'), findsOneWidget);
    },
  );

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
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
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
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
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
  _Harness({Agent? agent})
    : agent = agent is ControlledAgent ? agent : ControlledAgent(),
      _providedAgent = agent {
    store = MemoryApiKeyOverrideStore();
    resolver = ApiKeyResolver(
      overrideStore: store,
      environment: const MapEnvironmentReader({}),
    );
    dependencies = DomovoyDependencies(
      agent: _providedAgent ?? this.agent,
      overrideStore: store,
      apiKeyResolver: resolver,
    );
  }

  final ControlledAgent agent;
  final Agent? _providedAgent;
  late final MemoryApiKeyOverrideStore store;
  late final ApiKeyResolver resolver;
  late final DomovoyDependencies dependencies;

  Widget get app => DomovoyApp(dependencies: dependencies);

  void dispose() {
    for (final controller in agent.controllers) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
  }
}

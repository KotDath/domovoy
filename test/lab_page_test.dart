import 'package:domovoy/app.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/lab/domain/format_contracts.dart';
import 'package:domovoy/features/lab/presentation/lab_page.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/features/settings/domain/model_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Widget _labApp({Agent? agent}) {
  final controlled = agent is ControlledAgent ? agent : ControlledAgent();
  final store = MemoryApiKeyOverrideStore();
  final resolver = ApiKeyResolver(
    overrideStore: store,
    environment: const MapEnvironmentReader({}),
  );
  final modelStore = InMemoryDeepSeekModelSettingsStore();
  final dependencies = DomovoyDependencies(
    agent: agent ?? controlled,
    overrideStore: store,
    apiKeyResolver: resolver,
    modelSettingsStore: modelStore,
  );
  return DomovoyApp(dependencies: dependencies);
}

void main() {
  group('Response laboratory widgets', () {
    testWidgets('navigates from prompt workspace to the laboratory', (
      tester,
    ) async {
      final harnessAgent = ControlledAgent();
      final store = MemoryApiKeyOverrideStore();
      final resolver = ApiKeyResolver(
        overrideStore: store,
        environment: const MapEnvironmentReader({}),
      );
      final app = DomovoyApp(
        dependencies: DomovoyDependencies(
          agent: harnessAgent,
          overrideStore: store,
          apiKeyResolver: resolver,
        ),
      );
      await tester.pumpWidget(app);

      expect(find.byKey(const ValueKey('prompt-destination')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-lab')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lab-destination')), findsOneWidget);
      expect(find.byKey(const ValueKey('experiment-selector')), findsOneWidget);
      expect(find.byKey(const ValueKey('reasoning-banner')), findsOneWidget);
    });

    testWidgets(
      'reasoning disabled on the prompt page applies to the next lab run',
      (tester) async {
        final agent = ControlledAgent();
        await tester.pumpWidget(_labApp(agent: agent));

        // Change the shared setting from the Day 1 workspace.
        await tester.tap(find.byKey(const ValueKey('open-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reasoning-switch')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Закрыть'));
        await tester.pumpAndSettle();

        // The laboratory picks up the change without a restart.
        await tester.tap(find.byKey(const ValueKey('nav-lab')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('reasoning-state')), findsOneWidget);
        expect(find.textContaining('выключено'), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('format-prompt')),
          'base task',
        );
        await tester.ensureVisible(find.byKey(const ValueKey('run-format')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('run-format')));
        await tester.pump();

        expect(agent.inputs, isNotEmpty);
        expect(agent.inputs.first.thinking, ThinkingMode.disabled);
        for (final controller in agent.controllers) {
          await controller.close();
        }
      },
    );

    testWidgets('shows reasoning state and opens settings', (tester) async {
      await tester.pumpWidget(_labApp());
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('reasoning-state')), findsOneWidget);
      expect(find.textContaining('Reasoning:'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('open-deepseek-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reasoning-switch')), findsOneWidget);
    });

    testWidgets('format form shows inline errors without requests', (
      tester,
    ) async {
      final agent = ControlledAgent();
      await tester.pumpWidget(_labApp(agent: agent));
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('format-prompt')),
        '   ',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('run-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run-format')));
      await tester.pumpAndSettle();

      expect(find.text('Введите базовый запрос.'), findsOneWidget);
      expect(agent.inputs, isEmpty);
    });

    testWidgets('format form rejects counts above the supported maximum', (
      tester,
    ) async {
      final agent = ControlledAgent();
      await tester.pumpWidget(_labApp(agent: agent));
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('format-json-spec')),
        'title:string, items:array:99',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('run-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run-format')));
      await tester.pumpAndSettle();

      expect(find.textContaining('не должно превышать'), findsOneWidget);
      expect(agent.inputs, isEmpty);
    });

    testWidgets('length form validates numbers and warns on small budgets', (
      tester,
    ) async {
      await tester.pumpWidget(_labApp());
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Длина'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('length-max-chars')),
        'oops',
      );
      await tester.enterText(
        find.byKey(const ValueKey('length-max-tokens')),
        '0',
      );
      await tester.tap(find.byKey(const ValueKey('run-length')));
      await tester.pump();

      expect(find.text('Введите число символов.'), findsOneWidget);

      // Small token ceiling with reasoning enabled shows the warning.
      await tester.enterText(
        find.byKey(const ValueKey('length-max-chars')),
        '300',
      );
      await tester.enterText(
        find.byKey(const ValueKey('length-max-tokens')),
        '100',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reasoning-budget-warning')),
        findsOneWidget,
      );
    });

    testWidgets('stop form validates markers', (tester) async {
      await tester.pumpWidget(_labApp());
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Стоп'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('stop-marker')), '   ');
      await tester.tap(find.byKey(const ValueKey('run-stop')));
      await tester.pump();

      expect(find.text('Введите непустой стоп-маркер.'), findsOneWidget);
    });

    testWidgets('streams paired lanes and keeps applied controls visible', (
      tester,
    ) async {
      final agent = ControlledAgent();
      await tester.pumpWidget(_labApp(agent: agent));
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('format-prompt')),
        'base task',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('run-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run-format')));
      await tester.pump();

      expect(find.byKey(const ValueKey('baseline-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('controlled-card')), findsOneWidget);
      // While running, the run action is disabled (not removed).
      final runButton = tester.widget<FilledButton>(
        find.byKey(const ValueKey('run-format')),
      );
      expect(runButton.onPressed, isNull);

      agent.latest.add(const AgentAnswerDelta('base answer'));
      await tester.pump();
      expect(find.text('base answer'), findsOneWidget);

      agent.latest.add(const AgentCompleted());
      await agent.latest.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Controlled lane is now streaming; complete it with valid JSON.
      agent.latest.add(
        const AgentAnswerDelta(
          '{"title": "t", "summary": "s", "items": ["a", "b", "c"]}',
        ),
      );
      agent.latest.add(const AgentCompleted());
      await agent.latest.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('applied-control')), findsOneWidget);
      expect(find.byKey(const ValueKey('conclusion-format')), findsOneWidget);
      expect(find.textContaining('Валидация:'), findsWidgets);
    });

    testWidgets('stop evidence reports the sentence without the marker', (
      tester,
    ) async {
      final agent = ControlledAgent();
      await tester.pumpWidget(_labApp(agent: agent));
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Стоп'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const ValueKey('run-stop')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run-stop')));
      await tester.pump();

      agent.latest
        ..add(const AgentAnswerDelta('совет. Продолжение после маркера'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      agent.latest
        ..add(const AgentAnswerDelta('совет <END_OF_ANSWER> хвост'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('stop-post-marker-sentence')),
        findsNWidgets(2),
      );
      for (final controller in agent.controllers) {
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    });

    testWidgets('repair freezes the format contract selectors', (tester) async {
      final agent = ControlledAgent();
      await tester.pumpWidget(_labApp(agent: agent));
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('format-prompt')),
        'base task',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('run-format')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('run-format')));
      await tester.pump();

      agent.latest
        ..add(const AgentAnswerDelta('plain baseline'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      agent.latest
        ..add(const AgentAnswerDelta('still plain'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.ensureVisible(find.byKey(const ValueKey('repair-format')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('repair-format')));
      await tester.pump();

      // While the one-shot repair streams, the visible controls must not
      // drift from the active immutable repair contract.
      expect(
        tester
            .widget<SegmentedButton<ResponseFormatKind>>(
              find.byKey(const ValueKey('format-kind')),
            )
            .onSelectionChanged,
        isNull,
      );
      expect(
        tester
            .widget<SegmentedButton<MarkdownListKind>>(
              find.byKey(const ValueKey('format-markdown-list-kind')),
            )
            .onSelectionChanged,
        isNull,
      );

      for (final controller in agent.controllers) {
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    });

    testWidgets('stacks result cards on narrow windows', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 900);

      await tester.pumpWidget(_labApp());
      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('narrow-lab-layout')), findsOneWidget);

      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wide-lab-layout')), findsOneWidget);
    });

    testWidgets('lab page renders all conclusions', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LabPage(
            agent: ControlledAgent(),
            overrideStore: MemoryApiKeyOverrideStore(),
            apiKeyResolver: ApiKeyResolver(
              overrideStore: MemoryApiKeyOverrideStore(),
              environment: const MapEnvironmentReader({}),
            ),
            modelSettingsStore: InMemoryDeepSeekModelSettingsStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('conclusion-format')), findsOneWidget);

      await tester.tap(find.text('Длина'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('conclusion-length')), findsOneWidget);

      await tester.tap(find.text('Стоп'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('conclusion-stop')), findsOneWidget);
      expect(find.textContaining('в ответ не возвращается'), findsOneWidget);
      expect(find.textContaining('не доказывает'), findsOneWidget);
    });
  });
}

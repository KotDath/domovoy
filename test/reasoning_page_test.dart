import 'package:domovoy/app.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/reasoning/domain/four_house_puzzle.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Widget _app({Agent? agent}) {
  final store = MemoryApiKeyOverrideStore();
  return DomovoyApp(
    dependencies: DomovoyDependencies(
      agent: agent ?? ControlledAgent(),
      overrideStore: store,
      apiKeyResolver: ApiKeyResolver(
        overrideStore: store,
        environment: const MapEnvironmentReader({}),
      ),
    ),
  );
}

Future<void> _openDay3(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('nav-reasoning')));
  await tester.pumpAndSettle();
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump();
  }
}

List<List<AgentEvent>> _expertSuccessScripts() => const [
  [AgentAnswerDelta('ANALYST-ANSWER'), AgentCompleted()],
  [AgentAnswerDelta('ENGINEER-ANSWER'), AgentCompleted()],
  [AgentAnswerDelta('CRITIC-ANSWER'), AgentCompleted()],
  [AgentAnswerDelta('SYNTHESIS-ANSWER'), AgentCompleted()],
];

void main() {
  group('Day 3 laboratory widgets', () {
    testWidgets('navigates to Day 3 without clearing Day 1 or Day 2', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await tester.enterText(
        find.byKey(const ValueKey('prompt-input')),
        'day-one draft',
      );

      await _openDay3(tester);
      expect(
        find.byKey(const ValueKey('reasoning-destination')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('day3-task')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('strategy-card-direct')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('strategy-card-stepByStep')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('strategy-card-generatedPrompt')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('strategy-card-expertGroup')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('eight-call-cost')), findsOneWidget);
      expect(find.textContaining('8 API-вызовов'), findsOneWidget);
      expect(find.textContaining('Стоимость: 4 API-вызова'), findsOneWidget);
      expect(find.byKey(const ValueKey('run-reasoning')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reasoning-off-banner')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('day3-task')),
        'day3-edit',
      );
      await tester.tap(find.byKey(const ValueKey('nav-prompt')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('prompt-destination')),
          matching: find.text('day-one draft'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('prompt-destination')),
          matching: find.text('day3-edit'),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lab-destination')), findsOneWidget);
      expect(find.byKey(const ValueKey('experiment-selector')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lab-destination')),
          matching: find.byKey(const ValueKey('strategy-card-direct')),
        ),
        findsNothing,
      );

      await _openDay3(tester);
      expect(find.text('day3-edit'), findsOneWidget);
    });

    testWidgets('disables empty execution and editing while running', (
      tester,
    ) async {
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);

      await tester.enterText(find.byKey(const ValueKey('day3-task')), '   ');
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await tester.pump();
      expect(find.text('Введите задачу.'), findsOneWidget);
      expect(agent.inputs, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('day3-task')),
        fourHousePresetTask,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('run-reasoning')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('day3-task')))
            .enabled,
        isFalse,
      );
      expect(agent.inputs, hasLength(1));
      await agent.latest.close();
    });

    testWidgets('streams one card without changing the others', (tester) async {
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await tester.pump();

      agent.latest.add(const AgentAnswerDelta('only-direct'));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('strategy-card-direct')),
          matching: find.text('only-direct'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('strategy-card-stepByStep')),
          matching: find.text('only-direct'),
        ),
        findsNothing,
      );
      await agent.latest.close();
    });

    testWidgets('shows generated prompt separately from the solver answer', (
      tester,
    ) async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('direct-a'), AgentCompleted()],
        const [AgentAnswerDelta('step-a'), AgentCompleted()],
        const [AgentAnswerDelta('BUILDER-PROMPT'), AgentCompleted()],
        const [AgentAnswerDelta('SOLVER-ANSWER'), AgentCompleted()],
        ..._expertSuccessScripts(),
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await _pumpFrames(tester);

      await tester.ensureVisible(
        find.byKey(const ValueKey('generated-prompt-evidence')),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-prompt-evidence')),
          matching: find.text('BUILDER-PROMPT'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-prompt-evidence')),
          matching: find.text('SOLVER-ANSWER'),
        ),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('generated-solver-answer')),
      );
      expect(find.text('SOLVER-ANSWER'), findsOneWidget);
      expect(find.text('Этап 1 · Генерация промпта'), findsOneWidget);
      expect(find.text('Этап 2 · Выполнение промпта'), findsOneWidget);
    });

    testWidgets('shows builder metadata separately from the solver stage', (
      tester,
    ) async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('direct-a'), AgentCompleted()],
        const [AgentAnswerDelta('step-a'), AgentCompleted()],
        const [
          AgentAnswerDelta('BUILDER-PROMPT'),
          AgentCompleted(
            finishReason: AgentFinishReason.stop,
            usage: AgentTokenUsage(
              promptTokens: 4,
              completionTokens: 5,
              totalTokens: 9,
            ),
          ),
        ],
        const [
          AgentAnswerDelta('SOLVER-ANSWER'),
          AgentCompleted(
            finishReason: AgentFinishReason.length,
            usage: AgentTokenUsage(totalTokens: 7),
          ),
        ],
        ..._expertSuccessScripts(),
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await _pumpFrames(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-prompt-evidence')),
          matching: find.text('Причина завершения: stop'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-prompt-evidence')),
          matching: find.textContaining('completion=5'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-solver-section')),
          matching: find.text('Причина завершения: length'),
        ),
        findsOneWidget,
      );
      expect(find.text('Ход рассуждений'), findsNothing);
    });

    testWidgets('shows builder failure without a solver answer', (
      tester,
    ) async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('direct-a'), AgentCompleted()],
        const [AgentAnswerDelta('step-a'), AgentCompleted()],
        const [
          AgentAnswerDelta('partial builder'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'down'),
          ),
        ],
        ..._expertSuccessScripts(),
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await _pumpFrames(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-prompt-evidence')),
          matching: find.text('partial builder'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-prompt-evidence')),
          matching: find.text('down'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('generated-solver-answer')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-solver-section')),
          matching: find.text('down'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows empty builder skip without solver output', (
      tester,
    ) async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('direct-a'), AgentCompleted()],
        const [AgentAnswerDelta('step-a'), AgentCompleted()],
        const [AgentCompleted()],
        ..._expertSuccessScripts(),
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await _pumpFrames(tester);

      expect(
        find.byKey(const ValueKey('generated-prompt-evidence')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('generated-solver-answer')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-solver-section')),
          matching: find.textContaining('пуст'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('streams builder prompt text as soon as the stage starts', (
      tester,
    ) async {
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await tester.pump();

      agent.latest
        ..add(const AgentAnswerDelta('direct-a'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await tester.pump();
      await tester.pump();

      agent.latest
        ..add(const AgentAnswerDelta('step-a'))
        ..add(const AgentCompleted());
      await agent.latest.close();
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('generated-prompt-evidence')),
        findsOneWidget,
      );
      expect(find.text('Ожидаем промпт…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('generated-solver-section')),
        findsNothing,
      );

      agent.latest.add(const AgentAnswerDelta('partial-prompt'));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('generated-prompt-evidence')),
          matching: find.text('partial-prompt'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('generated-solver-answer')),
        findsNothing,
      );
      await agent.latest.close();
    });

    testWidgets('shows three independent expert results and final synthesis', (
      tester,
    ) async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('direct-a'), AgentCompleted()],
        const [AgentAnswerDelta('step-a'), AgentCompleted()],
        const [AgentAnswerDelta('builder-a'), AgentCompleted()],
        const [AgentAnswerDelta('solver-a'), AgentCompleted()],
        ..._expertSuccessScripts(),
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await _pumpFrames(tester, 40);

      for (final entry in const <(String, String)>[
        ('expert-analyst-evidence', 'ANALYST-ANSWER'),
        ('expert-engineer-evidence', 'ENGINEER-ANSWER'),
        ('expert-critic-evidence', 'CRITIC-ANSWER'),
        ('expert-synthesis-section', 'SYNTHESIS-ANSWER'),
      ]) {
        final panel = find.byKey(ValueKey(entry.$1));
        expect(panel, findsOneWidget);
        expect(
          find.descendant(of: panel, matching: find.text(entry.$2)),
          findsOneWidget,
        );
      }
      expect(find.text('Прогресс: 8 из 8 API-вызовов'), findsOneWidget);
      expect(agent.inputs, hasLength(8));
    });

    testWidgets('keeps expert failure visible and still shows synthesis', (
      tester,
    ) async {
      final agent = QueueScriptedAgent(const [
        [AgentAnswerDelta('direct-a'), AgentCompleted()],
        [AgentAnswerDelta('step-a'), AgentCompleted()],
        [AgentAnswerDelta('builder-a'), AgentCompleted()],
        [AgentAnswerDelta('solver-a'), AgentCompleted()],
        [
          AgentAnswerDelta('PARTIAL-ANALYST'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'offline'),
          ),
        ],
        [AgentAnswerDelta('ENGINEER-ANSWER'), AgentCompleted()],
        [AgentAnswerDelta('CRITIC-ANSWER'), AgentCompleted()],
        [AgentAnswerDelta('SYNTHESIS-ANSWER'), AgentCompleted()],
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await _pumpFrames(tester, 40);

      final analyst = find.byKey(const ValueKey('expert-analyst-evidence'));
      expect(
        find.descendant(of: analyst, matching: find.text('PARTIAL-ANALYST')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: analyst, matching: find.text('offline')),
        findsOneWidget,
      );
      expect(find.text('SYNTHESIS-ANSWER'), findsOneWidget);
      expect(agent.inputs.last.text, contains('PARTIAL-ANALYST'));
      expect(agent.inputs.last.text, contains('offline'));
    });

    testWidgets('shows unique reference only for the unchanged preset', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await _openDay3(tester);
      expect(find.byKey(const ValueKey('reference-grid')), findsOneWidget);
      expect(find.textContaining('Вера'), findsWidgets);
      expect(find.textContaining('кофе'), findsWidgets);
      expect(find.textContaining('попугай'), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey('day3-task')),
        'другая задача',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reference-not-applicable')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reference-grid')), findsNothing);
    });

    testWidgets('records ratings and a user-selected summary', (tester) async {
      final agent = QueueScriptedAgent([
        const [AgentAnswerDelta('direct-a'), AgentCompleted()],
        const [AgentAnswerDelta('step-a'), AgentCompleted()],
        const [AgentAnswerDelta('builder-a'), AgentCompleted()],
        const [AgentAnswerDelta('solver-a'), AgentCompleted()],
        ..._expertSuccessScripts(),
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay3(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-reasoning')));
      await tester.tap(find.byKey(const ValueKey('run-reasoning')));
      await _pumpFrames(tester);

      await tester.ensureVisible(
        find.byKey(const ValueKey('verdict-direct-correct')),
      );
      await tester.tap(find.byKey(const ValueKey('verdict-direct-correct')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('most-accurate-direct')),
      );
      await tester.tap(find.byKey(const ValueKey('most-accurate-direct')));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('comparison-summary')),
      );
      expect(
        find.textContaining(
          'Самый точный способ по вашей оценке: Прямой ответ',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('суждение пользователя'), findsOneWidget);
      expect(find.textContaining('Прямой ответ: Точно'), findsOneWidget);
    });

    testWidgets('uses two columns on wide windows and stacks on narrow', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 900);

      await tester.pumpWidget(_app());
      await _openDay3(tester);
      expect(
        find.byKey(const ValueKey('narrow-reasoning-layout')),
        findsOneWidget,
      );

      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('wide-reasoning-layout')),
        findsOneWidget,
      );
    });
  });
}

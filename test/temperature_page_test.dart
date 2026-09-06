import 'package:domovoy/app.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/features/temperature/domain/temperature_metrics.dart';
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

void _useTallWindow(WidgetTester tester) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1600);
}

Future<void> _openDay4(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('nav-temperature')));
  await tester.pumpAndSettle();
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump();
  }
}

void main() {
  group('Day 4 laboratory widgets', () {
    testWidgets('navigates to Day 4 without clearing Days 1–3', (tester) async {
      await tester.pumpWidget(_app());
      await tester.enterText(
        find.byKey(const ValueKey('prompt-input')),
        'day-one draft',
      );

      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lab-destination')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nav-reasoning')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('day3-task')),
        'day3-edit',
      );

      await _openDay4(tester);
      expect(
        find.byKey(const ValueKey('temperature-destination')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('day4-prompt')), findsOneWidget);
      expect(find.byKey(const ValueKey('temperature-card-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('temperature-card-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('temperature-card-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('three-call-cost')), findsOneWidget);
      expect(find.byKey(const ValueKey('run-temperature')), findsOneWidget);
      expect(find.textContaining('0.0'), findsWidgets);
      expect(find.textContaining('0.7'), findsWidgets);
      expect(find.textContaining('1.2'), findsWidgets);
      expect(find.text('День 2'), findsOneWidget);
      expect(find.text('День 3'), findsOneWidget);
      expect(find.text('День 4'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('day4-prompt')),
        'day4-edit',
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
          matching: find.text('day4-edit'),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('experiment-selector')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lab-destination')),
          matching: find.byKey(const ValueKey('temperature-card-0')),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('nav-reasoning')));
      await tester.pumpAndSettle();
      expect(find.text('day3-edit'), findsOneWidget);

      await _openDay4(tester);
      expect(find.text('day4-edit'), findsOneWidget);
    });

    testWidgets('sliders, reset, and distinct validation work', (tester) async {
      _useTallWindow(tester);
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay4(tester);

      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('temperature-slider-0')))
            .value,
        0.0,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('temperature-slider-1')))
            .value,
        0.7,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('temperature-slider-2')))
            .value,
        1.2,
      );

      tester
          .widget<Slider>(find.byKey(const ValueKey('temperature-slider-1')))
          .onChanged!(1.1);
      await tester.pump();
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('temperature-slider-0')))
            .value,
        0.0,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('temperature-slider-1')))
            .value,
        1.1,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('temperature-slider-2')))
            .value,
        1.2,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('reset-temperatures')),
      );
      await tester.tap(find.byKey(const ValueKey('reset-temperatures')));
      await tester.pump();
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('temperature-slider-1')))
            .value,
        0.7,
      );

      tester
          .widget<Slider>(find.byKey(const ValueKey('temperature-slider-1')))
          .onChanged!(0.0);
      tester
          .widget<Slider>(find.byKey(const ValueKey('temperature-slider-2')))
          .onChanged!(0.0);
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('run-temperature')));
      await tester.tap(find.byKey(const ValueKey('run-temperature')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('temperature-distinct-error')),
        findsOneWidget,
      );
      expect(find.textContaining('различаться'), findsOneWidget);
      expect(agent.inputs, isEmpty);
    });

    testWidgets('rejects an empty prompt without calling the agent', (
      tester,
    ) async {
      _useTallWindow(tester);
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay4(tester);
      await tester.enterText(find.byKey(const ValueKey('day4-prompt')), '   ');
      await tester.ensureVisible(find.byKey(const ValueKey('run-temperature')));
      await tester.tap(find.byKey(const ValueKey('run-temperature')));
      await tester.pump();
      expect(find.text('Введите запрос.'), findsOneWidget);
      expect(agent.inputs, isEmpty);
    });

    testWidgets('locks editing and duplicate runs while streaming', (
      tester,
    ) async {
      _useTallWindow(tester);
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay4(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-temperature')));
      await tester.tap(find.byKey(const ValueKey('run-temperature')));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('run-temperature')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('day4-prompt')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<Slider>(find.byKey(const ValueKey('temperature-slider-0')))
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('reset-temperatures')),
            )
            .onPressed,
        isNull,
      );
      expect(agent.inputs, hasLength(1));
      await agent.latest.close();
    });

    testWidgets('streams one card without changing the others', (tester) async {
      _useTallWindow(tester);
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay4(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-temperature')));
      await tester.tap(find.byKey(const ValueKey('run-temperature')));
      await tester.pump();

      agent.latest.add(const AgentAnswerDelta('only-low'));
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('temperature-card-0')),
          matching: find.text('only-low'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('temperature-card-1')),
          matching: find.text('only-low'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('temperature-destination')),
          matching: find.text('Ход рассуждений'),
        ),
        findsNothing,
      );
      await agent.latest.close();
    });

    testWidgets('keeps sanitized errors and continues later lanes', (
      tester,
    ) async {
      _useTallWindow(tester);
      final agent = QueueScriptedAgent(const [
        [
          AgentAnswerDelta('partial-low'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'down'),
          ),
        ],
        [AgentAnswerDelta('mid-ok'), AgentCompleted()],
        [AgentAnswerDelta('high-ok'), AgentCompleted()],
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay4(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-temperature')));
      await tester.tap(find.byKey(const ValueKey('run-temperature')));
      await _pumpFrames(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('temperature-card-0')),
          matching: find.text('partial-low'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('temperature-card-0')),
          matching: find.text('down'),
        ),
        findsOneWidget,
      );
      expect(find.text('mid-ok'), findsOneWidget);
      expect(find.text('high-ok'), findsOneWidget);
    });

    testWidgets('records ratings, notes, metrics, and unrated summary', (
      tester,
    ) async {
      _useTallWindow(tester);
      const low = 'hello hello world';
      const mid = 'hello world extra words';
      const high = 'unrelated text here now';
      final agent = QueueScriptedAgent(const [
        [
          AgentAnswerDelta(low),
          AgentCompleted(
            finishReason: AgentFinishReason.stop,
            usage: AgentTokenUsage(totalTokens: 4),
          ),
        ],
        [
          AgentAnswerDelta(mid),
          AgentCompleted(
            finishReason: AgentFinishReason.stop,
            usage: AgentTokenUsage(totalTokens: 4),
          ),
        ],
        [
          AgentAnswerDelta(high),
          AgentCompleted(
            finishReason: AgentFinishReason.stop,
            usage: AgentTokenUsage(totalTokens: 4),
          ),
        ],
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay4(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-temperature')));
      await tester.tap(find.byKey(const ValueKey('run-temperature')));
      await _pumpFrames(tester);

      expect(find.byKey(const ValueKey('run-progress')), findsOneWidget);
      expect(find.textContaining('3 из 3'), findsWidgets);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('applied-temperature-0')))
            .data,
        't=0.0',
      );
      expect(find.text('Причина завершения: stop'), findsWidgets);
      expect(find.textContaining('total=4'), findsWidgets);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('character-count-0')))
            .data,
        'Символов: ${unicodeCharacterCount(low)}',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('character-count-1')))
            .data,
        'Символов: ${unicodeCharacterCount(mid)}',
      );
      expect(
        find.textContaining(formatLexicalRatio(uniqueWordRatio(low)!)!),
        findsWidgets,
      );
      expect(find.byKey(const ValueKey('similarity-0-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('pairwise-similarity')), findsOneWidget);
      expect(
        find.textContaining('Оцените точность, креативность и разнообразие'),
        findsOneWidget,
      );
      expect(find.textContaining('победитель'), findsWidgets);

      await tester.ensureVisible(
        find.byKey(const ValueKey('rating-accuracy-0')),
      );
      await tester.tap(find.byKey(const ValueKey('rating-accuracy-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('note-0')),
        'код и факты',
      );
      await tester.pump();

      expect(find.textContaining('точность 5'), findsOneWidget);
      expect(find.textContaining('заметка: код и факты'), findsOneWidget);
      expect(find.textContaining('Автоматический победитель'), findsOneWidget);
    });

    testWidgets('new comparison really clears scores and notes', (
      tester,
    ) async {
      _useTallWindow(tester);
      final agent = QueueScriptedAgent(const [
        [AgentAnswerDelta('first-low'), AgentCompleted()],
        [AgentAnswerDelta('first-mid'), AgentCompleted()],
        [AgentAnswerDelta('first-high'), AgentCompleted()],
        [AgentAnswerDelta('second-low'), AgentCompleted()],
        [AgentAnswerDelta('second-mid'), AgentCompleted()],
        [AgentAnswerDelta('second-high'), AgentCompleted()],
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay4(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-temperature')));
      await tester.tap(find.byKey(const ValueKey('run-temperature')));
      await _pumpFrames(tester);

      await tester.ensureVisible(
        find.byKey(const ValueKey('rating-accuracy-0')),
      );
      await tester.tap(find.byKey(const ValueKey('rating-accuracy-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('note-0')),
        'код и факты',
      );
      await tester.pump();
      expect(find.textContaining('точность 5'), findsOneWidget);
      expect(find.textContaining('заметка: код и факты'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const ValueKey('run-temperature')));
      await tester.tap(find.byKey(const ValueKey('run-temperature')));
      await _pumpFrames(tester);

      expect(find.text('second-low'), findsOneWidget);
      expect(find.text('first-low'), findsNothing);
      expect(find.textContaining('точность 5'), findsNothing);
      expect(find.textContaining('заметка: код и факты'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('summary-lane-0'))).data,
        contains('точность Без оценки'),
      );
      expect(
        tester
            .widget<DropdownButtonFormField<int?>>(
              find.byKey(const ValueKey('rating-accuracy-0')),
            )
            .initialValue,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('note-0')))
            .controller
            ?.text,
        isEmpty,
      );
    });

    testWidgets('shows provider guidance and single-sample limits', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await _openDay4(tester);

      expect(
        find.byKey(const ValueKey('temperature-guidance')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('official-recommendations')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('exercise-inferences')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('single-sample-limitation')),
        findsOneWidget,
      );
      expect(find.textContaining('0.0 до 2.0'), findsOneWidget);
      expect(find.textContaining('thinking'), findsWidgets);
      expect(find.textContaining('top_p'), findsWidgets);
      expect(find.textContaining('1.5'), findsWidgets);
      expect(find.textContaining('не точные рекомендации'), findsOneWidget);
      expect(find.textContaining('распределен'), findsOneWidget);
    });

    testWidgets('uses three columns on wide windows and stacks on narrow', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 900);

      await tester.pumpWidget(_app());
      await _openDay4(tester);
      expect(
        find.byKey(const ValueKey('narrow-temperature-layout')),
        findsOneWidget,
      );

      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('wide-temperature-layout')),
        findsOneWidget,
      );
    });
  });
}

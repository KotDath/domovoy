import 'package:domovoy/app.dart';
import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/comparison/data/comparison_profile_store.dart';
import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/comparison/domain/token_cost.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Widget _app({Agent? agent, ComparisonProfileStore? profileStore}) {
  final store = MemoryApiKeyOverrideStore();
  final resolvedAgent = agent ?? ControlledAgent();
  return DomovoyApp(
    dependencies: DomovoyDependencies(
      agent: resolvedAgent,
      overrideStore: store,
      apiKeyResolver: ApiKeyResolver(
        overrideStore: store,
        environment: const MapEnvironmentReader({}),
      ),
      comparisonProfileStore: profileStore,
      comparisonAgentFactory: (_) => resolvedAgent,
    ),
  );
}

void _useTallWindow(WidgetTester tester) {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1800);
}

Future<void> _openDay5(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('nav-comparison')));
  await tester.pumpAndSettle();
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 20]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump();
  }
}

void main() {
  group('Day 5 laboratory widgets', () {
    testWidgets('navigates to Day 5 without clearing Days 1–4', (tester) async {
      await tester.pumpWidget(_app());
      await tester.enterText(
        find.byKey(const ValueKey('prompt-input')),
        'day-one draft',
      );

      await tester.tap(find.byKey(const ValueKey('nav-lab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-reasoning')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('day3-task')),
        'day3-edit',
      );
      await tester.tap(find.byKey(const ValueKey('nav-temperature')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('day4-prompt')),
        'day4-edit',
      );

      await _openDay5(tester);
      expect(
        find.byKey(const ValueKey('comparison-destination')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('day5-prompt')), findsOneWidget);
      expect(find.byKey(const ValueKey('comparison-card-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('comparison-card-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('comparison-card-2')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('day5-three-call-cost')),
        findsOneWidget,
      );
      expect(find.textContaining('qwen3.5:2b'), findsWidgets);
      expect(find.textContaining('deepseek-v4-flash'), findsWidgets);
      expect(find.textContaining('deepseek-v4-pro'), findsWidgets);
      expect(find.text('День 5'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('day5-prompt')),
        'day5-edit',
      );
      await tester.tap(find.byKey(const ValueKey('nav-prompt')));
      await tester.pumpAndSettle();
      expect(find.text('day-one draft'), findsOneWidget);
      expect(find.text('day5-edit'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('nav-temperature')));
      await tester.pumpAndSettle();
      expect(find.text('day4-edit'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('temperature-destination')),
          matching: find.byKey(const ValueKey('comparison-card-0')),
        ),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('nav-reasoning')));
      await tester.pumpAndSettle();
      expect(find.text('day3-edit'), findsOneWidget);

      await _openDay5(tester);
      expect(find.text('day5-edit'), findsOneWidget);
    });

    testWidgets('shows identities, links, caveats, and validation', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await _openDay5(tester);

      expect(find.byKey(const ValueKey('tier-caveat')), findsOneWidget);
      expect(find.byKey(const ValueKey('warmup-limitation')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('single-run-limitation')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('pricing-limitation')), findsOneWidget);
      expect(find.textContaining('localhost'), findsWidgets);
      expect(
        find.textContaining(
          'https://api-docs.deepseek.com/quick_start/pricing',
        ),
        findsWidgets,
      );
      expect(find.textContaining('2B / 2.7 GB'), findsWidgets);
    });

    testWidgets('locks editing and duplicate runs while streaming', (
      tester,
    ) async {
      _useTallWindow(tester);
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay5(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-comparison')));
      await tester.tap(find.byKey(const ValueKey('run-comparison')));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('run-comparison')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('day5-prompt')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('open-day5-settings')),
            )
            .onPressed,
        isNull,
      );
      expect(agent.inputs, hasLength(1));
      await agent.latest.close();
    });

    testWidgets('streams one card and keeps sanitized errors', (tester) async {
      _useTallWindow(tester);
      final agent = QueueScriptedAgent(const [
        [
          AgentAnswerDelta('partial-weak'),
          AgentFailed(
            AgentFailure(kind: AgentFailureKind.network, message: 'down'),
          ),
        ],
        [AgentAnswerDelta('mid-ok'), AgentCompleted()],
        [AgentAnswerDelta('strong-ok'), AgentCompleted()],
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay5(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-comparison')));
      await tester.tap(find.byKey(const ValueKey('run-comparison')));
      await _pumpFrames(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('comparison-card-0')),
          matching: find.text('partial-weak'),
        ),
        findsOneWidget,
      );
      expect(find.text('down'), findsOneWidget);
      expect(find.text('mid-ok'), findsOneWidget);
      expect(find.text('strong-ok'), findsOneWidget);
    });

    testWidgets('shows measurement, cost, ratings, links, and reset', (
      tester,
    ) async {
      _useTallWindow(tester);
      const answer =
          '```dart\nclass SparseSet {}\n```\nsparse/dense swap-remove O(1) component storage query';
      final agent = QueueScriptedAgent([
        [
          const AgentAnswerDelta(answer),
          const AgentCompleted(
            finishReason: AgentFinishReason.stop,
            usage: AgentTokenUsage(
              promptTokens: 10,
              completionTokens: 20,
              totalTokens: 30,
            ),
          ),
        ],
        [
          const AgentAnswerDelta(answer),
          AgentCompleted(
            finishReason: AgentFinishReason.stop,
            usage: const AgentTokenUsage(
              promptTokens: 10,
              completionTokens: 20,
              totalTokens: 30,
              cacheHitPromptTokens: 4,
              cacheMissPromptTokens: 6,
            ),
          ),
        ],
        [
          const AgentAnswerDelta(answer),
          const AgentCompleted(finishReason: AgentFinishReason.stop),
        ],
        [const AgentAnswerDelta('second-a'), const AgentCompleted()],
        [const AgentAnswerDelta('second-b'), const AgentCompleted()],
        [const AgentAnswerDelta('second-c'), const AgentCompleted()],
      ]);
      await tester.pumpWidget(_app(agent: agent));
      await _openDay5(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('run-comparison')));
      await tester.tap(find.byKey(const ValueKey('run-comparison')));
      await _pumpFrames(tester);

      expect(find.textContaining(r'$0'), findsWidgets);
      expect(
        find.textContaining(
          formatEstimatedCost(
            estimateProviderCost(
              pricing: kDeepSeekFlashPricing,
              usage: const AgentTokenUsage(
                promptTokens: 10,
                completionTokens: 20,
                cacheHitPromptTokens: 4,
                cacheMissPromptTokens: 6,
              ),
            ),
          ),
        ),
        findsWidgets,
      );
      expect(find.textContaining('недоступно'), findsWidgets);
      expect(find.byKey(const ValueKey('checklist-0')), findsOneWidget);
      expect(find.textContaining('swap-remove: есть'), findsWidgets);
      expect(find.byKey(const ValueKey('request-evaluation')), findsOneWidget);
      expect(find.byKey(const ValueKey('no-cost-winner')), findsNothing);
      expect(
        find.byKey(const ValueKey('no-token-cost-winner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('unavailable-cost-evidence')),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('rating-correctness-0')),
      );
      await tester.tap(find.byKey(const ValueKey('rating-correctness-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('day5-note-0')),
        'хорошо для черновика',
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('day5-conclusion')),
        'локальная модель слабее',
      );
      await tester.pump();
      expect(find.textContaining('корректность 5'), findsOneWidget);
      expect(
        find.textContaining('заметка: хорошо для черновика'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.byKey(const ValueKey('run-comparison')));
      await tester.tap(find.byKey(const ValueKey('run-comparison')));
      await _pumpFrames(tester);
      expect(find.text('second-a'), findsOneWidget);
      expect(find.textContaining('корректность 5'), findsNothing);
      expect(find.text('локальная модель слабее'), findsNothing);
    });

    testWidgets('rejects an empty prompt without calling the agent', (
      tester,
    ) async {
      _useTallWindow(tester);
      final agent = ControlledAgent();
      await tester.pumpWidget(_app(agent: agent));
      await _openDay5(tester);
      await tester.enterText(find.byKey(const ValueKey('day5-prompt')), '   ');
      await tester.ensureVisible(find.byKey(const ValueKey('run-comparison')));
      await tester.tap(find.byKey(const ValueKey('run-comparison')));
      await tester.pump();
      expect(find.text('Введите запрос.'), findsOneWidget);
      expect(agent.inputs, isEmpty);
    });

    testWidgets('edits a profile without revealing secrets', (tester) async {
      _useTallWindow(tester);
      final profiles = InMemoryComparisonProfileStore();
      await tester.pumpWidget(_app(profileStore: profiles));
      await _openDay5(tester);
      await tester.tap(find.byKey(const ValueKey('open-day5-settings')));
      await tester.pumpAndSettle();

      expect(find.text('Профили сравнения'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('profile-key-input-0')),
            )
            .obscureText,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('profile-key-input-0')),
            )
            .controller
            ?.text,
        isEmpty,
      );
      expect(find.textContaining('Authorization'), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey('profile-model-0')),
        'custom-local',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('save-profile-0')));
      await tester.tap(find.byKey(const ValueKey('save-profile-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.textContaining('custom-local'), findsWidgets);
      expect(profiles.value, isNot(contains('sk-')));
      expect(profiles.value, contains('custom-local'));

      await tester.tap(find.byKey(const ValueKey('open-day5-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('profile-tab-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('profile-endpoint-1')),
        'http://example.com/chat/completions',
      );
      await tester.tap(find.byKey(const ValueKey('save-profile-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTPS'), findsWidgets);
    });

    testWidgets('uses three columns on wide windows and stacks on narrow', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(500, 900);

      await tester.pumpWidget(_app());
      await _openDay5(tester);
      expect(
        find.byKey(const ValueKey('narrow-comparison-layout')),
        findsOneWidget,
      );

      tester.view.physicalSize = const Size(1200, 800);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('wide-comparison-layout')),
        findsOneWidget,
      );
    });
  });
}

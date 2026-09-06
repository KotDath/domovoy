import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/comparison/domain/comparison_prompts.dart';
import 'package:domovoy/features/comparison/domain/elapsed_timer.dart';
import 'package:domovoy/features/comparison/domain/structural_checklist.dart';
import 'package:domovoy/features/comparison/domain/token_cost.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Day 5 prompt', () {
    test('asks for a Dart sparse-set ECS', () {
      expect(kComparisonStarterPrompt, contains('Dart'));
      expect(kComparisonStarterPrompt.toLowerCase(), contains('sparse'));
      expect(kComparisonStarterPrompt.toLowerCase(), contains('ecs'));
      expect(kComparisonStarterPrompt.toLowerCase(), contains('swap-remove'));
      expect(kComparisonStarterPrompt, contains('O(1)'));
      expect(kComparisonStarterPrompt.toLowerCase(), contains('query'));
    });

    test('lane input disables thinking and omits controls', () {
      final input = buildComparisonLaneInput('  code  ');
      expect(input.text, 'code');
      expect(input.thinking, ThinkingMode.disabled);
      expect(input.control, isNull);
      expect(input.temperature, isNull);
    });
  });

  group('elapsed clock', () {
    test('stopwatch clock is monotonic and increasing', () async {
      final clock = StopwatchElapsedClock();
      final first = clock.elapsed();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = clock.elapsed();
      expect(second >= first, isTrue);
    });
  });

  group('token cost', () {
    test('uses cache split for an exact estimate', () {
      final cost = estimateProviderCost(
        pricing: kDeepSeekFlashPricing,
        usage: const AgentTokenUsage(
          promptTokens: 10,
          completionTokens: 20,
          cacheHitPromptTokens: 4,
          cacheMissPromptTokens: 6,
        ),
      );
      expect(cost, isA<ExactEstimatedCost>());
      final exact = cost as ExactEstimatedCost;
      expect(
        exact.amount,
        closeTo(4 / 1e6 * 0.0028 + 6 / 1e6 * 0.14 + 20 / 1e6 * 0.28, 1e-12),
      );
      expect(formatEstimatedCost(cost), contains('2026-09-07'));
    });

    test('shows a hit/miss range when the split is absent', () {
      final cost = estimateProviderCost(
        pricing: kDeepSeekFlashPricing,
        usage: const AgentTokenUsage(promptTokens: 100, completionTokens: 10),
      );
      expect(cost, isA<RangedEstimatedCost>());
      final range = cost as RangedEstimatedCost;
      expect(range.minimum < range.maximum, isTrue);
      expect(formatEstimatedCost(cost), contains('–'));
    });

    test('declares zero provider fee without inventing hardware cost', () {
      final cost = estimateProviderCost(
        pricing: kOllamaZeroProviderPricing,
        usage: null,
      );
      expect(cost, isA<ZeroProviderFeeCost>());
      expect(formatEstimatedCost(cost), contains(r'$0'));
      expect(formatEstimatedCost(cost), contains('не измерены'));
    });

    test('keeps cost unavailable when rates or tokens are missing', () {
      expect(
        estimateProviderCost(pricing: null, usage: const AgentTokenUsage()),
        isA<UnavailableEstimatedCost>(),
      );
      expect(
        estimateProviderCost(
          pricing: kDeepSeekFlashPricing,
          usage: const AgentTokenUsage(promptTokens: 10),
        ),
        isA<UnavailableEstimatedCost>(),
      );
      expect(
        formatEstimatedCost(const UnavailableEstimatedCost()),
        'недоступно',
      );
    });
  });

  group('structural checklist', () {
    test('matches lexical evidence without scoring quality', () {
      const answer = '''
```dart
class SparseSet {}
```
sparse/dense mapping, swap-remove, O(1) lookups, component storage and query.
''';
      final evidence = evaluateStructuralChecklist(answer);
      expect(evidence.hasDartCode, isTrue);
      expect(evidence.hasSparseDenseMapping, isTrue);
      expect(evidence.hasSwapRemove, isTrue);
      expect(evidence.hasConstantTime, isTrue);
      expect(evidence.hasComponentStorage, isTrue);
      expect(evidence.hasQuery, isTrue);
      expect(evidence.matchedCount, 6);
    });

    test('reports absences independently', () {
      final evidence = evaluateStructuralChecklist('just prose');
      expect(evidence.hasDartCode, isFalse);
      expect(evidence.hasSparseDenseMapping, isFalse);
      expect(evidence.hasSwapRemove, isFalse);
      expect(evidence.hasConstantTime, isFalse);
      expect(evidence.hasComponentStorage, isFalse);
      expect(evidence.hasQuery, isFalse);
    });
  });
}

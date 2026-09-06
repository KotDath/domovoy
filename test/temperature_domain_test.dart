import 'package:domovoy/features/prompt/data/chat_completions_provider_profile.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/temperature/domain/temperature_metrics.dart';
import 'package:domovoy/features/temperature/domain/temperature_models.dart';
import 'package:domovoy/features/temperature/domain/temperature_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Day 4 presets and inputs', () {
    test('starter prompt mixes factual and creative demands', () {
      expect(kTemperatureStarterPrompt, contains('голубым'));
      expect(kTemperatureStarterPrompt, contains('научную точность'));
      expect(kTemperatureStarterPrompt, contains('метафор'));
      expect(kTemperatureStarterPrompt, contains('120'));
    });

    test('required presets stay in demonstration order', () {
      expect(kTemperaturePresetValues, [0.0, 0.7, 1.2]);
    });

    test('lane inputs disable thinking and omit response control', () {
      final input = buildTemperatureLaneInput(
        prompt: '  sky  ',
        temperature: 0.7,
      );
      expect(input.text, 'sky');
      expect(input.thinking, ThinkingMode.disabled);
      expect(input.control, isNull);
      expect(input.temperature, 0.7);
    });

    test('Day 4 request body sends temperature and omits top_p', () {
      final body = ChatCompletionsProviderProfile.deepSeekV4Flash().requestBody(
        buildTemperatureLaneInput(prompt: 'sky', temperature: 1.2),
      );
      expect(body['temperature'], 1.2);
      expect(body['thinking'], {'type': 'disabled'});
      expect(body.containsKey('top_p'), isFalse);
      expect(body.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('lexical metrics', () {
    test('counts Unicode grapheme characters', () {
      expect(unicodeCharacterCount('небо'), 4);
      expect(unicodeCharacterCount('a👍b'), 3);
      expect(unicodeCharacterCount(''), 0);
    });

    test('computes unique-word ratio after Unicode normalization', () {
      expect(uniqueWordRatio('Hello hello world'), closeTo(2 / 3, 0.0001));
      expect(uniqueWordRatio('Ёлка ёлка 42'), closeTo(2 / 3, 0.0001));
      expect(normalizedWords('Sky-blue, SKY!'), ['sky', 'blue', 'sky']);
    });

    test('empty or wordless text yields unavailable evidence', () {
      expect(uniqueWordRatio(''), isNull);
      expect(uniqueWordRatio('   '), isNull);
      expect(uniqueWordRatio('!!!'), isNull);
      expect(pairwiseJaccardSimilarity('', 'hello'), isNull);
      expect(pairwiseJaccardSimilarity('hello', ''), isNull);
      expect(pairwiseJaccardSimilarity('!!!', '???'), isNull);
    });

    test('computes pairwise Jaccard similarity over word sets', () {
      expect(pairwiseJaccardSimilarity('a b c', 'b c d'), closeTo(0.5, 0.0001));
      expect(pairwiseJaccardSimilarity('one two', 'one two'), 1.0);
      expect(pairwiseJaccardSimilarity('alpha', 'beta'), 0.0);
    });
  });

  group('evaluation models', () {
    test('lanes start idle without scores or applied temperature', () {
      final state = TemperatureExperimentState();
      expect(state.temperatures, kTemperaturePresetValues);
      expect(state.lanes, hasLength(3));
      for (final lane in state.lanes) {
        expect(lane.status, TemperatureLaneStatus.idle);
        expect(lane.appliedTemperature, isNull);
        expect(lane.evaluation.hasAnyScore, isFalse);
        expect(lane.evaluation.note, isEmpty);
      }
    });
  });
}

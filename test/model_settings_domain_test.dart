import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/settings/domain/model_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeepSeekModelSettings', () {
    test('defaults to reasoning enabled', () {
      expect(DeepSeekModelSettings.defaults.reasoningEnabled, isTrue);
    });

    test('persists and restores selection independently', () async {
      final store = InMemoryDeepSeekModelSettingsStore();
      expect(await store.read(), isNull);

      await store.write(const DeepSeekModelSettings(reasoningEnabled: false));
      expect((await store.read())?.reasoningEnabled, isFalse);

      await store.write(const DeepSeekModelSettings(reasoningEnabled: true));
      expect((await store.read())?.reasoningEnabled, isTrue);
    });
  });

  group('AgentInput', () {
    test('constructor trims text and defaults thinking to enabled', () {
      final input = AgentInput('  hello  ');
      expect(input.text, 'hello');
      expect(input.thinking, ThinkingMode.enabled);
    });

    test('rejects blank text', () {
      expect(() => AgentInput('   '), throwsArgumentError);
    });

    test('terminal metadata defaults to absent', () {
      const completed = AgentCompleted();
      expect(completed.finishReason, isNull);
      expect(completed.usage, isNull);
    });

    test('terminal metadata carries finish reason and usage', () {
      const completed = AgentCompleted(
        finishReason: AgentFinishReason.length,
        usage: AgentTokenUsage(
          promptTokens: 10,
          completionTokens: 20,
          totalTokens: 30,
        ),
      );
      expect(completed.finishReason, AgentFinishReason.length);
      expect(completed.usage?.completionTokens, 20);
    });
  });
}

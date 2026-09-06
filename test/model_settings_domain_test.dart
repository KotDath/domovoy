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
    test('Day 1 constructor stays unrestricted with thinking enabled', () {
      final input = AgentInput('  hello  ');
      expect(input.text, 'hello');
      expect(input.thinking, ThinkingMode.enabled);
      expect(input.control, isNull);
      expect(input.isUnrestricted, isTrue);
    });

    test('rejects blank text', () {
      expect(() => AgentInput('   '), throwsArgumentError);
    });

    test('length control requires positive values', () {
      expect(
        () => LengthControl(maxChars: 0, maxTokens: 10),
        throwsArgumentError,
      );
      expect(
        () => LengthControl(maxChars: 10, maxTokens: 0),
        throwsArgumentError,
      );
    });

    test('stop control rejects blank marker and trims', () {
      expect(() => StopControl('   '), throwsArgumentError);
      expect(StopControl('  <END>  ').marker, '<END>');
    });

    test('format control rejects empty contract', () {
      expect(
        () => FormatControl(kind: ResponseFormatKind.json, contractText: '   '),
        throwsArgumentError,
      );
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
      expect(agentFinishReasonLabel(AgentFinishReason.stop), 'stop');
      expect(agentFinishReasonLabel(AgentFinishReason.length), 'length');
      expect(agentFinishReasonLabel(AgentFinishReason.unknown), 'unknown');
    });
  });
}

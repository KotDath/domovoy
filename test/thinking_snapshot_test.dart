import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/prompt/presentation/prompt_controller.dart';
import 'package:domovoy/features/settings/domain/model_settings.dart';
import 'package:domovoy/features/settings/presentation/reasoning_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('PromptController thinking snapshot', () {
    test('sends enabled thinking by default (Day 1 behavior)', () {
      final agent = ControlledAgent();
      final controller = PromptController(agent);
      addTearDown(controller.dispose);

      expect(controller.thinking, ThinkingMode.enabled);
      expect(controller.submit('hello'), isTrue);
      expect(agent.inputs.single.thinking, ThinkingMode.enabled);
    });

    test('snapshots disabled reasoning from the persisted store', () async {
      final agent = ControlledAgent();
      final controller = PromptController(
        agent,
        modelSettingsStore: InMemoryDeepSeekModelSettingsStore(
          const DeepSeekModelSettings(reasoningEnabled: false),
        ),
      );
      addTearDown(controller.dispose);

      await controller.loadThinking();
      expect(controller.thinking, ThinkingMode.disabled);
      expect(controller.submit('hello'), isTrue);
      expect(agent.inputs.single.thinking, ThinkingMode.disabled);
    });

    test('falls back to enabled on missing values and read failures', () async {
      final agent = ControlledAgent();
      final missing = PromptController(
        agent,
        modelSettingsStore: InMemoryDeepSeekModelSettingsStore(),
      );
      addTearDown(missing.dispose);
      await missing.loadThinking();
      expect(missing.thinking, ThinkingMode.enabled);

      final failing = PromptController(
        agent,
        modelSettingsStore: _FailingModelStore(),
      );
      addTearDown(failing.dispose);
      await failing.loadThinking();
      expect(failing.thinking, ThinkingMode.enabled);
      expect(failing.submit('hello'), isTrue);
      expect(agent.inputs.single.thinking, ThinkingMode.enabled);
    });

    test('setThinkingMode applies to subsequent requests only', () {
      final agent = ControlledAgent();
      final controller = PromptController(agent);
      addTearDown(controller.dispose);

      controller.setThinkingMode(ThinkingMode.disabled);
      expect(controller.submit('one'), isTrue);
      expect(agent.inputs.single.thinking, ThinkingMode.disabled);
    });
  });

  group('ReasoningSettings shared state', () {
    test('defaults to enabled and restores the stored value', () async {
      final settings = ReasoningSettings(
        store: InMemoryDeepSeekModelSettingsStore(
          const DeepSeekModelSettings(reasoningEnabled: false),
        ),
      );
      addTearDown(settings.dispose);

      var notified = 0;
      settings.addListener(() => notified++);
      await settings.load();

      expect(settings.reasoningEnabled, isFalse);
      expect(settings.isLoaded, isTrue);
      expect(notified, greaterThan(0));
    });

    test('falls back to enabled when the store fails', () async {
      final settings = ReasoningSettings(store: _FailingModelStore());
      addTearDown(settings.dispose);

      await settings.load();
      expect(settings.reasoningEnabled, isTrue);
      expect(settings.isLoaded, isTrue);
    });

    test('setEnabled persists and notifies listeners', () async {
      final store = InMemoryDeepSeekModelSettingsStore();
      final settings = ReasoningSettings(store: store);
      addTearDown(settings.dispose);

      expect(await settings.setEnabled(false), isTrue);
      expect(settings.reasoningEnabled, isFalse);
      expect(store.value?.reasoningEnabled, isFalse);
    });
  });

  group('AgentFinishReason labels', () {
    test('covers every normalized value', () {
      expect(agentFinishReasonLabel(AgentFinishReason.stop), 'stop');
      expect(agentFinishReasonLabel(AgentFinishReason.length), 'length');
      expect(
        agentFinishReasonLabel(AgentFinishReason.contentFilter),
        'content_filter',
      );
      expect(agentFinishReasonLabel(AgentFinishReason.toolCalls), 'tool_calls');
      expect(
        agentFinishReasonLabel(AgentFinishReason.insufficientSystemResource),
        'insufficient_system_resource',
      );
      expect(agentFinishReasonLabel(AgentFinishReason.unknown), 'unknown');
      expect(agentFinishReasonLabel(null), '—');
    });
  });
}

final class _FailingModelStore implements DeepSeekModelSettingsStore {
  @override
  Future<DeepSeekModelSettings?> read() async {
    throw StateError('disk gone');
  }

  @override
  Future<void> write(DeepSeekModelSettings settings) async {
    throw StateError('disk gone');
  }
}

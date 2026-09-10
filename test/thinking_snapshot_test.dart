import 'package:domovoy/core/llm/generation.dart';
import 'package:domovoy/features/prompt/domain/prompt_workspace.dart';
import 'package:domovoy/features/prompt/presentation/prompt_controller.dart';
import 'package:domovoy/features/settings/domain/model_settings.dart';
import 'package:domovoy/features/settings/presentation/reasoning_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('PromptController thinking snapshot', () {
    test('sends enabled thinking by default', () {
      final runtime = ControlledAgentRuntime();
      final controller = PromptController(
        runtime,
        definition: PromptWorkspace.definition(),
      );
      addTearDown(controller.dispose);

      expect(controller.thinking, ReasoningMode.enabled);
      expect(controller.submit('hello'), isTrue);
      expect(
        runtime.definitions.single.generation.reasoningMode,
        ReasoningMode.enabled,
      );
    });

    test('snapshots disabled reasoning from the persisted store', () async {
      final runtime = ControlledAgentRuntime();
      final controller = PromptController(
        runtime,
        definition: PromptWorkspace.definition(),
        modelSettingsStore: InMemoryDeepSeekModelSettingsStore(
          const DeepSeekModelSettings(reasoningEnabled: false),
        ),
      );
      addTearDown(controller.dispose);

      await controller.loadThinking();
      expect(controller.thinking, ReasoningMode.disabled);
      expect(controller.submit('hello'), isTrue);
      expect(
        runtime.definitions.single.generation.reasoningMode,
        ReasoningMode.disabled,
      );
    });

    test('falls back to enabled on missing values and read failures', () async {
      final runtime = ControlledAgentRuntime();
      final missing = PromptController(
        runtime,
        definition: PromptWorkspace.definition(),
        modelSettingsStore: InMemoryDeepSeekModelSettingsStore(),
      );
      addTearDown(missing.dispose);
      await missing.loadThinking();
      expect(missing.thinking, ReasoningMode.enabled);

      final failing = PromptController(
        runtime,
        definition: PromptWorkspace.definition(),
        modelSettingsStore: _FailingModelStore(),
      );
      addTearDown(failing.dispose);
      await failing.loadThinking();
      expect(failing.thinking, ReasoningMode.enabled);
      expect(failing.submit('hello'), isTrue);
      expect(
        runtime.definitions.single.generation.reasoningMode,
        ReasoningMode.enabled,
      );
    });

    test('setThinkingMode applies to subsequent requests only', () {
      final runtime = ControlledAgentRuntime();
      final controller = PromptController(
        runtime,
        definition: PromptWorkspace.definition(),
      );
      addTearDown(controller.dispose);

      controller.setThinkingMode(ReasoningMode.disabled);
      expect(controller.submit('one'), isTrue);
      expect(
        runtime.definitions.single.generation.reasoningMode,
        ReasoningMode.disabled,
      );
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

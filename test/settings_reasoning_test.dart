import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/features/settings/domain/model_settings.dart';
import 'package:domovoy/features/settings/presentation/api_key_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

ApiKeyResolver _resolver(MemoryApiKeyOverrideStore store) {
  return ApiKeyResolver(
    overrideStore: store,
    environment: const MapEnvironmentReader({}),
  );
}

void main() {
  group('ApiKeySettingsController reasoning', () {
    test('restores saved reasoning selection on load', () async {
      final controller = ApiKeySettingsController(
        overrideStore: MemoryApiKeyOverrideStore(),
        resolver: _resolver(MemoryApiKeyOverrideStore()),
        modelSettingsStore: InMemoryDeepSeekModelSettingsStore(
          const DeepSeekModelSettings(reasoningEnabled: false),
        ),
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.reasoningEnabled, isFalse);
    });

    test('defaults to enabled when nothing is stored', () async {
      final controller = ApiKeySettingsController(
        overrideStore: MemoryApiKeyOverrideStore(),
        resolver: _resolver(MemoryApiKeyOverrideStore()),
        modelSettingsStore: InMemoryDeepSeekModelSettingsStore(),
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(controller.state.reasoningEnabled, isTrue);
    });

    test(
      'persists reasoning changes without touching the API key store',
      () async {
        final keyStore = MemoryApiKeyOverrideStore('key');
        final modelStore = InMemoryDeepSeekModelSettingsStore();
        final controller = ApiKeySettingsController(
          overrideStore: keyStore,
          resolver: _resolver(keyStore),
          modelSettingsStore: modelStore,
        );
        addTearDown(controller.dispose);
        await controller.load();

        expect(await controller.setReasoningEnabled(false), isTrue);
        expect(controller.state.reasoningEnabled, isFalse);
        expect(modelStore.value?.reasoningEnabled, isFalse);
        expect(keyStore.value, 'key');
        expect(keyStore.writeCount, 0);
      },
    );

    test('sanitizes model storage failures', () async {
      final controller = ApiKeySettingsController(
        overrideStore: MemoryApiKeyOverrideStore(),
        resolver: _resolver(MemoryApiKeyOverrideStore()),
        modelSettingsStore: _FailingModelStore(),
      );
      addTearDown(controller.dispose);

      await controller.load();
      // Falls back to default without throwing.
      expect(controller.state.reasoningEnabled, isTrue);
      expect(await controller.setReasoningEnabled(false), isFalse);
      expect(controller.state.message, isNotNull);
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

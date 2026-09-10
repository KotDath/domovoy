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
}

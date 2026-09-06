import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/model_settings.dart';

final class SecureDeepSeekModelSettingsStore
    implements DeepSeekModelSettingsStore {
  SecureDeepSeekModelSettingsStore(this._storage);

  static const storageKey = 'deepseek_reasoning_enabled';

  final FlutterSecureStorage _storage;

  @override
  Future<DeepSeekModelSettings?> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null) {
      return null;
    }
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') {
      return const DeepSeekModelSettings(reasoningEnabled: true);
    }
    if (normalized == 'false' || normalized == '0') {
      return const DeepSeekModelSettings(reasoningEnabled: false);
    }
    return null;
  }

  @override
  Future<void> write(DeepSeekModelSettings settings) {
    return _storage.write(
      key: storageKey,
      value: settings.reasoningEnabled ? 'true' : 'false',
    );
  }
}

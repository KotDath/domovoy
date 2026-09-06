import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/api_key_credentials.dart';

final class SecureApiKeyOverrideStore implements ApiKeyOverrideStore {
  SecureApiKeyOverrideStore(this._storage);

  static const _storageKey = 'deepseek_api_key_override';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _storageKey);

  @override
  Future<void> write(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'value', 'API key must not be empty.');
    }
    await _storage.write(key: _storageKey, value: normalized);
  }

  @override
  Future<void> delete() => _storage.delete(key: _storageKey);
}

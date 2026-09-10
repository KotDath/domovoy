import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../infrastructure/credentials/credentials.dart';
import '../domain/api_key_credentials.dart';

final class SecureApiKeyOverrideStore implements ApiKeyOverrideStore {
  SecureApiKeyOverrideStore(FlutterSecureStorage storage)
    : _strings = FlutterSecureStringStore(storage);

  final SecureStringStore _strings;

  @override
  Future<String?> read() =>
      NamespacedProviderCredentialStore.readDeepSeekOverride(_strings);

  @override
  Future<void> write(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'value', 'API key must not be empty.');
    }
    await NamespacedProviderCredentialStore.writeDeepSeekOverride(
      _strings,
      normalized,
    );
  }

  @override
  Future<void> delete() =>
      NamespacedProviderCredentialStore.deleteDeepSeekOverride(_strings);
}

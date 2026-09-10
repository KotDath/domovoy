import '../../core/llm/catalog.dart';
import '../../core/llm/credentials.dart';
import '../../core/llm/errors.dart';
import '../../core/llm/identifiers.dart';
import 'secure_string_store.dart';

final class NamespacedProviderCredentialStore
    implements ProviderCredentialStore {
  NamespacedProviderCredentialStore(this._strings);

  static const namespacePrefix = 'llm_provider_api_key_override/';
  static const legacyDeepSeekKey = 'deepseek_api_key_override';

  final SecureStringStore _strings;

  static String namespacedKey(ProviderId providerId) =>
      '$namespacePrefix${providerId.value}';

  static Future<String?> readDeepSeekOverride(SecureStringStore strings) async {
    final namespaced = _normalized(
      await strings.read(namespacedKey(BuiltInLlmCatalog.deepSeek)),
    );
    if (namespaced != null) {
      return namespaced;
    }
    return _normalized(await strings.read(legacyDeepSeekKey));
  }

  static Future<void> writeDeepSeekOverride(
    SecureStringStore strings,
    String value,
  ) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throwLlm(LlmErrorKind.configuration, 'API key must not be empty.');
    }
    await strings.write(namespacedKey(BuiltInLlmCatalog.deepSeek), normalized);
    await strings.write(legacyDeepSeekKey, normalized);
  }

  static Future<void> deleteDeepSeekOverride(SecureStringStore strings) async {
    await strings.delete(namespacedKey(BuiltInLlmCatalog.deepSeek));
    await strings.delete(legacyDeepSeekKey);
  }

  @override
  Future<String?> read(ProviderId providerId) async {
    if (providerId == BuiltInLlmCatalog.deepSeek) {
      return readDeepSeekOverride(_strings);
    }
    return _normalized(await _strings.read(namespacedKey(providerId)));
  }

  @override
  Future<void> write(ProviderId providerId, String value) async {
    if (providerId == BuiltInLlmCatalog.deepSeek) {
      await writeDeepSeekOverride(_strings, value);
      return;
    }
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throwLlm(LlmErrorKind.configuration, 'API key must not be empty.');
    }
    await _strings.write(namespacedKey(providerId), normalized);
  }

  @override
  Future<void> delete(ProviderId providerId) {
    if (providerId == BuiltInLlmCatalog.deepSeek) {
      return deleteDeepSeekOverride(_strings);
    }
    return _strings.delete(namespacedKey(providerId));
  }
}

String? _normalized(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return normalized;
}

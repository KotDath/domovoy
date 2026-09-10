import 'errors.dart';
import 'identifiers.dart';

enum LlmCredentialSource { storedOverride, environment }

final class LlmResolvedCredential {
  LlmResolvedCredential({required String value, required this.source})
    : value = value.trim() {
    if (this.value.isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Resolved credential must not be blank.',
      );
    }
  }

  final String value;
  final LlmCredentialSource source;
}

final class LlmMissingCredentialException implements Exception {
  LlmMissingCredentialException(this.providerId);

  final ProviderId providerId;

  @override
  String toString() => 'LlmMissingCredentialException(${providerId.value})';
}

abstract interface class ProviderCredentialStore {
  Future<String?> read(ProviderId providerId);

  Future<void> write(ProviderId providerId, String value);

  Future<void> delete(ProviderId providerId);
}

abstract interface class ProviderCredentialResolver {
  Future<LlmResolvedCredential> resolve({
    required ProviderId providerId,
    required String environmentVariable,
  });
}

typedef EnvironmentVariableReader = String? Function(String name);

final class MemoryProviderCredentialStore implements ProviderCredentialStore {
  MemoryProviderCredentialStore([Map<ProviderId, String>? initial])
    : _values = <String, String>{
        for (final entry in (initial ?? const <ProviderId, String>{}).entries)
          entry.key.value: entry.value,
      };

  final Map<String, String> _values;

  @override
  Future<String?> read(ProviderId providerId) async =>
      _values[providerId.value];

  @override
  Future<void> write(ProviderId providerId, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throwLlm(LlmErrorKind.configuration, 'API key must not be empty.');
    }
    _values[providerId.value] = normalized;
  }

  @override
  Future<void> delete(ProviderId providerId) async {
    _values.remove(providerId.value);
  }
}

final class DefaultProviderCredentialResolver
    implements ProviderCredentialResolver {
  DefaultProviderCredentialResolver({
    required this.store,
    required this.readEnvironment,
  });

  final ProviderCredentialStore store;
  final EnvironmentVariableReader readEnvironment;

  @override
  Future<LlmResolvedCredential> resolve({
    required ProviderId providerId,
    required String environmentVariable,
  }) async {
    final override = _normalized(await store.read(providerId));
    if (override != null) {
      return LlmResolvedCredential(
        value: override,
        source: LlmCredentialSource.storedOverride,
      );
    }
    final environmentValue = _normalized(readEnvironment(environmentVariable));
    if (environmentValue != null) {
      return LlmResolvedCredential(
        value: environmentValue,
        source: LlmCredentialSource.environment,
      );
    }
    throw LlmMissingCredentialException(providerId);
  }
}

String? _normalized(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return normalized;
}

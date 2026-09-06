import '../../../core/environment/environment_reader.dart';

const deepSeekApiKeyEnvironmentVariable = 'DEEPSEEK_API_KEY';

abstract interface class ApiKeyOverrideStore {
  Future<String?> read();

  Future<void> write(String value);

  Future<void> delete();
}

abstract interface class CredentialResolver {
  Future<ResolvedApiKey> resolve();

  Future<ApiKeyStatus> status();
}

enum ApiKeySource { applicationOverride, environment, missing, none }

final class ResolvedApiKey {
  const ResolvedApiKey({required this.value, required this.source});

  final String value;
  final ApiKeySource source;
}

final class ApiKeyStatus {
  const ApiKeyStatus({
    required this.source,
    required this.hasApplicationOverride,
  });

  final ApiKeySource source;
  final bool hasApplicationOverride;
}

final class MissingApiKeyException implements Exception {
  const MissingApiKeyException({
    this.environmentVariable = deepSeekApiKeyEnvironmentVariable,
  });

  final String environmentVariable;
}

final class ApiKeyResolver implements CredentialResolver {
  const ApiKeyResolver({
    required this.overrideStore,
    required this.environment,
  });

  final ApiKeyOverrideStore overrideStore;
  final EnvironmentReader environment;

  @override
  Future<ResolvedApiKey> resolve() async {
    final override = _normalized(await overrideStore.read());
    if (override != null) {
      return ResolvedApiKey(
        value: override,
        source: ApiKeySource.applicationOverride,
      );
    }

    final environmentValue = _normalized(
      environment.read(deepSeekApiKeyEnvironmentVariable),
    );
    if (environmentValue != null) {
      return ResolvedApiKey(
        value: environmentValue,
        source: ApiKeySource.environment,
      );
    }

    throw const MissingApiKeyException();
  }

  @override
  Future<ApiKeyStatus> status() async {
    final hasOverride = _normalized(await overrideStore.read()) != null;
    if (hasOverride) {
      return const ApiKeyStatus(
        source: ApiKeySource.applicationOverride,
        hasApplicationOverride: true,
      );
    }

    final hasEnvironment =
        _normalized(environment.read(deepSeekApiKeyEnvironmentVariable)) !=
        null;
    return ApiKeyStatus(
      source: hasEnvironment ? ApiKeySource.environment : ApiKeySource.missing,
      hasApplicationOverride: false,
    );
  }

  static String? _normalized(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/environment/environment_reader.dart';
import '../../settings/domain/api_key_credentials.dart';
import '../domain/chat_model_profile.dart';
import '../domain/profile_validation.dart';

abstract interface class ProfileApiKeyOverrideStore {
  Future<String?> read(String profileId);

  Future<void> write(String profileId, String value);

  Future<void> delete(String profileId);
}

final class InMemoryProfileApiKeyOverrideStore
    implements ProfileApiKeyOverrideStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String profileId) async => values[profileId];

  @override
  Future<void> write(String profileId, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'value', 'API key must not be empty.');
    }
    ensureValidStorageProfileId(profileId);
    values[profileId] = normalized;
  }

  @override
  Future<void> delete(String profileId) async {
    values.remove(profileId);
  }
}

final class SecureProfileApiKeyOverrideStore
    implements ProfileApiKeyOverrideStore {
  SecureProfileApiKeyOverrideStore(this._storage);

  final FlutterSecureStorage _storage;

  static String storageKeyFor(String profileId) {
    ensureValidStorageProfileId(profileId);
    return 'day5_profile_api_key_$profileId';
  }

  @override
  Future<String?> read(String profileId) {
    return _storage.read(key: storageKeyFor(profileId));
  }

  @override
  Future<void> write(String profileId, String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'value', 'API key must not be empty.');
    }
    return _storage.write(key: storageKeyFor(profileId), value: normalized);
  }

  @override
  Future<void> delete(String profileId) {
    return _storage.delete(key: storageKeyFor(profileId));
  }
}

void ensureValidStorageProfileId(String profileId) {
  if (!isValidStableProfileId(profileId)) {
    throw const ProfileValidationException(
      'Идентификатор профиля должен состоять из латиницы, цифр, "_" или "-" и начинаться с буквы.',
    );
  }
}

final class UnauthenticatedCredentialResolver implements CredentialResolver {
  const UnauthenticatedCredentialResolver();

  @override
  Future<ResolvedApiKey> resolve() async {
    throw const MissingApiKeyException(environmentVariable: '');
  }

  @override
  Future<ApiKeyStatus> status() async {
    return const ApiKeyStatus(
      source: ApiKeySource.none,
      hasApplicationOverride: false,
    );
  }
}

final class ProfileBearerCredentialResolver implements CredentialResolver {
  const ProfileBearerCredentialResolver({
    required this.profileId,
    required this.environmentVariableName,
    required this.overrideStore,
    required this.environment,
  });

  final String profileId;
  final String environmentVariableName;
  final ProfileApiKeyOverrideStore overrideStore;
  final EnvironmentReader environment;

  @override
  Future<ResolvedApiKey> resolve() async {
    ensureValidStorageProfileId(profileId);
    final envError = validateEnvironmentVariableName(environmentVariableName);
    if (envError != null) {
      throw ProfileValidationException(envError);
    }
    final override = _normalized(await overrideStore.read(profileId));
    if (override != null) {
      return ResolvedApiKey(
        value: override,
        source: ApiKeySource.applicationOverride,
      );
    }
    final environmentValue = _normalized(
      environment.read(environmentVariableName),
    );
    if (environmentValue != null) {
      return ResolvedApiKey(
        value: environmentValue,
        source: ApiKeySource.environment,
      );
    }
    throw MissingApiKeyException(environmentVariable: environmentVariableName);
  }

  @override
  Future<ApiKeyStatus> status() async {
    ensureValidStorageProfileId(profileId);
    final hasOverride =
        _normalized(await overrideStore.read(profileId)) != null;
    if (hasOverride) {
      return const ApiKeyStatus(
        source: ApiKeySource.applicationOverride,
        hasApplicationOverride: true,
      );
    }
    final hasEnvironment =
        _normalized(environment.read(environmentVariableName)) != null;
    return ApiKeyStatus(
      source: hasEnvironment ? ApiKeySource.environment : ApiKeySource.missing,
      hasApplicationOverride: false,
    );
  }
}

CredentialResolver? credentialResolverForProfile({
  required ChatModelProfile profile,
  required ApiKeyResolver sharedDeepSeekResolver,
  required ProfileApiKeyOverrideStore profileOverrideStore,
  required EnvironmentReader environment,
}) {
  ensureValidChatModelProfile(profile);
  return switch (profile.authentication) {
    ProfileAuthenticationMode.none => null,
    ProfileAuthenticationMode.sharedDeepSeek => sharedDeepSeekResolver,
    ProfileAuthenticationMode.profileBearer => ProfileBearerCredentialResolver(
      profileId: profile.id,
      environmentVariableName: profile.environmentVariableName!.trim(),
      overrideStore: profileOverrideStore,
      environment: environment,
    ),
  };
}

Future<ApiKeyStatus> credentialStatusForProfile({
  required ChatModelProfile profile,
  required ApiKeyResolver sharedDeepSeekResolver,
  required ProfileApiKeyOverrideStore profileOverrideStore,
  required EnvironmentReader environment,
}) async {
  final resolver = credentialResolverForProfile(
    profile: profile,
    sharedDeepSeekResolver: sharedDeepSeekResolver,
    profileOverrideStore: profileOverrideStore,
    environment: environment,
  );
  if (resolver == null) {
    return const ApiKeyStatus(
      source: ApiKeySource.none,
      hasApplicationOverride: false,
    );
  }
  return resolver.status();
}

String? _normalized(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

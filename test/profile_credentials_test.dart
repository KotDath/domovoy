import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/comparison/data/profile_credential_resolver.dart';
import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('profile credential precedence', () {
    test('saved override wins over environment for bearer profiles', () async {
      final store = InMemoryProfileApiKeyOverrideStore();
      await store.write('custom-model', '  saved-key  ');
      final resolver = ProfileBearerCredentialResolver(
        profileId: 'custom-model',
        environmentVariableName: 'CUSTOM_API_KEY',
        overrideStore: store,
        environment: const MapEnvironmentReader({
          'CUSTOM_API_KEY': 'environment-key',
        }),
      );

      final resolved = await resolver.resolve();
      expect(resolved.value, 'saved-key');
      expect(resolved.source, ApiKeySource.applicationOverride);
      final status = await resolver.status();
      expect(status.source, ApiKeySource.applicationOverride);
      expect(status.hasApplicationOverride, isTrue);
    });

    test('falls back to the named environment variable', () async {
      final resolver = ProfileBearerCredentialResolver(
        profileId: 'custom-model',
        environmentVariableName: 'CUSTOM_API_KEY',
        overrideStore: InMemoryProfileApiKeyOverrideStore(),
        environment: const MapEnvironmentReader({
          'CUSTOM_API_KEY': '  environment-key  ',
        }),
      );

      final resolved = await resolver.resolve();
      expect(resolved.value, 'environment-key');
      expect(resolved.source, ApiKeySource.environment);
      expect((await resolver.status()).source, ApiKeySource.environment);
    });

    test('removing the override exposes the environment key', () async {
      final store = InMemoryProfileApiKeyOverrideStore();
      await store.write('custom-model', 'saved-key');
      final resolver = ProfileBearerCredentialResolver(
        profileId: 'custom-model',
        environmentVariableName: 'CUSTOM_API_KEY',
        overrideStore: store,
        environment: const MapEnvironmentReader({
          'CUSTOM_API_KEY': 'environment-key',
        }),
      );
      expect(
        (await resolver.resolve()).source,
        ApiKeySource.applicationOverride,
      );
      await store.delete('custom-model');
      expect((await resolver.resolve()).source, ApiKeySource.environment);
    });

    test('missing bearer credentials throw without exposing values', () async {
      final resolver = ProfileBearerCredentialResolver(
        profileId: 'custom-model',
        environmentVariableName: 'CUSTOM_API_KEY',
        overrideStore: InMemoryProfileApiKeyOverrideStore(),
        environment: const MapEnvironmentReader({}),
      );
      await expectLater(
        resolver.resolve(),
        throwsA(
          isA<MissingApiKeyException>().having(
            (error) => error.environmentVariable,
            'environmentVariable',
            'CUSTOM_API_KEY',
          ),
        ),
      );
    });

    test('unauthenticated profiles report none and need no key', () async {
      final status = await credentialStatusForProfile(
        profile: kOllamaQwen35Profile,
        sharedDeepSeekResolver: ApiKeyResolver(
          overrideStore: MemoryApiKeyOverrideStore(),
          environment: const MapEnvironmentReader({}),
        ),
        profileOverrideStore: InMemoryProfileApiKeyOverrideStore(),
        environment: const MapEnvironmentReader({}),
      );
      expect(status.source, ApiKeySource.none);
      expect(
        credentialResolverForProfile(
          profile: kOllamaQwen35Profile,
          sharedDeepSeekResolver: ApiKeyResolver(
            overrideStore: MemoryApiKeyOverrideStore(),
            environment: const MapEnvironmentReader({}),
          ),
          profileOverrideStore: InMemoryProfileApiKeyOverrideStore(),
          environment: const MapEnvironmentReader({}),
        ),
        isNull,
      );
    });

    test('shared DeepSeek still prefers the application override', () async {
      final resolver = ApiKeyResolver(
        overrideStore: MemoryApiKeyOverrideStore('app-secret'),
        environment: const MapEnvironmentReader({
          deepSeekApiKeyEnvironmentVariable: 'environment-secret',
        }),
      );
      final selected = credentialResolverForProfile(
        profile: kDeepSeekFlashProfile,
        sharedDeepSeekResolver: resolver,
        profileOverrideStore: InMemoryProfileApiKeyOverrideStore(),
        environment: const MapEnvironmentReader({}),
      );
      expect(selected, same(resolver));
      expect(
        (await selected!.resolve()).source,
        ApiKeySource.applicationOverride,
      );
    });
  });
}

import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('ApiKeyResolver', () {
    test('application override wins over environment and is trimmed', () async {
      final store = MemoryApiKeyOverrideStore('  app-secret  ');
      final resolver = ApiKeyResolver(
        overrideStore: store,
        environment: const MapEnvironmentReader({
          deepSeekApiKeyEnvironmentVariable: 'environment-secret',
        }),
      );

      final credential = await resolver.resolve();

      expect(credential.value, 'app-secret');
      expect(credential.source, ApiKeySource.applicationOverride);
      expect((await resolver.status()).hasApplicationOverride, isTrue);
    });

    test('blank override falls back to environment', () async {
      final resolver = ApiKeyResolver(
        overrideStore: MemoryApiKeyOverrideStore('   '),
        environment: const MapEnvironmentReader({
          deepSeekApiKeyEnvironmentVariable: '  environment-secret  ',
        }),
      );

      final credential = await resolver.resolve();

      expect(credential.value, 'environment-secret');
      expect(credential.source, ApiKeySource.environment);
    });

    test('deleting override exposes environment fallback', () async {
      final store = MemoryApiKeyOverrideStore('app-secret');
      final resolver = ApiKeyResolver(
        overrideStore: store,
        environment: const MapEnvironmentReader({
          deepSeekApiKeyEnvironmentVariable: 'environment-secret',
        }),
      );

      expect(
        (await resolver.resolve()).source,
        ApiKeySource.applicationOverride,
      );
      await store.delete();

      expect((await resolver.resolve()).source, ApiKeySource.environment);
    });

    test('missing values throw typed exception', () async {
      final resolver = ApiKeyResolver(
        overrideStore: MemoryApiKeyOverrideStore(),
        environment: const MapEnvironmentReader({}),
      );

      await expectLater(
        resolver.resolve(),
        throwsA(isA<MissingApiKeyException>()),
      );
      final status = await resolver.status();
      expect(status.source, ApiKeySource.missing);
      expect(status.hasApplicationOverride, isFalse);
    });
  });
}

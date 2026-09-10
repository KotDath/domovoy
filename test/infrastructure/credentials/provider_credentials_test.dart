import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/infrastructure/credentials/credentials.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  group('provider-scoped credentials', () {
    test('stored override wins over environment and stays isolated', () async {
      final store = NamespacedProviderCredentialStore(
        MemorySecureStringStore(),
      );
      await store.write(BuiltInLlmCatalog.deepSeek, '  deep-secret  ');
      await store.write(BuiltInLlmCatalog.openAi, 'openai-secret');
      final resolver = DefaultProviderCredentialResolver(
        store: store,
        readEnvironment: const MapEnvironmentReader({
          BuiltInLlmCatalog.deepSeekApiKeyEnvironmentVariable: 'deep-env',
          BuiltInLlmCatalog.openAiApiKeyEnvironmentVariable: 'openai-env',
        }).read,
      );

      final deepSeek = await resolver.resolve(
        providerId: BuiltInLlmCatalog.deepSeek,
        environmentVariable:
            BuiltInLlmCatalog.deepSeekApiKeyEnvironmentVariable,
      );
      final openAi = await resolver.resolve(
        providerId: BuiltInLlmCatalog.openAi,
        environmentVariable: BuiltInLlmCatalog.openAiApiKeyEnvironmentVariable,
      );

      expect(deepSeek.value, 'deep-secret');
      expect(deepSeek.source, LlmCredentialSource.storedOverride);
      expect(openAi.value, 'openai-secret');
      expect(openAi.value, isNot(deepSeek.value));
    });

    test('environment is used when a stored override is absent', () async {
      final resolver = DefaultProviderCredentialResolver(
        store: NamespacedProviderCredentialStore(MemorySecureStringStore()),
        readEnvironment: const MapEnvironmentReader({
          BuiltInLlmCatalog.moonshotApiKeyEnvironmentVariable: '  moon-env  ',
        }).read,
      );
      final credential = await resolver.resolve(
        providerId: BuiltInLlmCatalog.moonshotAi,
        environmentVariable:
            BuiltInLlmCatalog.moonshotApiKeyEnvironmentVariable,
      );
      expect(credential.value, 'moon-env');
      expect(credential.source, LlmCredentialSource.environment);
    });

    test(
      'legacy DeepSeek override is read through without namespaced shadow',
      () async {
        final strings = MemorySecureStringStore(<String, String>{
          NamespacedProviderCredentialStore.legacyDeepSeekKey: '  legacy-key  ',
        });
        final store = NamespacedProviderCredentialStore(strings);
        final value = await store.read(BuiltInLlmCatalog.deepSeek);
        expect(value, 'legacy-key');
        expect(
          strings.values[NamespacedProviderCredentialStore.namespacedKey(
            BuiltInLlmCatalog.deepSeek,
          )],
          isNull,
        );
        expect(
          strings.values[NamespacedProviderCredentialStore.legacyDeepSeekKey],
          '  legacy-key  ',
        );
      },
    );

    test('UI write after legacy read replaces the DeepSeek override', () async {
      final strings = MemorySecureStringStore(<String, String>{
        NamespacedProviderCredentialStore.legacyDeepSeekKey: 'legacy-key',
      });
      final store = NamespacedProviderCredentialStore(strings);
      final ui = _UiDeepSeekOverrideStore(strings);
      final resolver = DefaultProviderCredentialResolver(
        store: store,
        readEnvironment: const MapEnvironmentReader({
          BuiltInLlmCatalog.deepSeekApiKeyEnvironmentVariable: 'env-key',
        }).read,
      );

      expect(await store.read(BuiltInLlmCatalog.deepSeek), 'legacy-key');
      await ui.write('new-ui-key');

      final credential = await resolver.resolve(
        providerId: BuiltInLlmCatalog.deepSeek,
        environmentVariable:
            BuiltInLlmCatalog.deepSeekApiKeyEnvironmentVariable,
      );
      expect(credential.value, 'new-ui-key');
      expect(credential.source, LlmCredentialSource.storedOverride);
      expect(await ui.read(), 'new-ui-key');
    });

    test('UI delete after legacy read falls back to environment', () async {
      final strings = MemorySecureStringStore(<String, String>{
        NamespacedProviderCredentialStore.legacyDeepSeekKey: 'legacy-key',
      });
      final store = NamespacedProviderCredentialStore(strings);
      final ui = _UiDeepSeekOverrideStore(strings);
      final resolver = DefaultProviderCredentialResolver(
        store: store,
        readEnvironment: const MapEnvironmentReader({
          BuiltInLlmCatalog.deepSeekApiKeyEnvironmentVariable: 'env-key',
        }).read,
      );

      expect(await store.read(BuiltInLlmCatalog.deepSeek), 'legacy-key');
      await ui.delete();

      final credential = await resolver.resolve(
        providerId: BuiltInLlmCatalog.deepSeek,
        environmentVariable:
            BuiltInLlmCatalog.deepSeekApiKeyEnvironmentVariable,
      );
      expect(credential.value, 'env-key');
      expect(credential.source, LlmCredentialSource.environment);
      expect(await ui.read(), isNull);
    });

    test('missing keys throw a typed exception without secrets', () async {
      final resolver = DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(),
        readEnvironment: const MapEnvironmentReader({}).read,
      );
      expect(
        () => resolver.resolve(
          providerId: BuiltInLlmCatalog.openAi,
          environmentVariable:
              BuiltInLlmCatalog.openAiApiKeyEnvironmentVariable,
        ),
        throwsA(
          isA<LlmMissingCredentialException>().having(
            (error) => error.toString(),
            'text',
            allOf(contains('openai'), isNot(contains('sk-'))),
          ),
        ),
      );
    });

    test('existing DeepSeek settings resolver behavior is unchanged', () async {
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
  });
}

final class _UiDeepSeekOverrideStore implements ApiKeyOverrideStore {
  _UiDeepSeekOverrideStore(this._strings);

  final SecureStringStore _strings;

  @override
  Future<String?> read() =>
      NamespacedProviderCredentialStore.readDeepSeekOverride(_strings);

  @override
  Future<void> write(String value) {
    return NamespacedProviderCredentialStore.writeDeepSeekOverride(
      _strings,
      value,
    );
  }

  @override
  Future<void> delete() {
    return NamespacedProviderCredentialStore.deleteDeepSeekOverride(_strings);
  }
}

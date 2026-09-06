import 'dart:async';

import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/comparison/data/comparison_profile_store.dart';
import 'package:domovoy/features/comparison/data/profile_credential_resolver.dart';
import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/comparison/domain/profile_validation.dart';
import 'package:domovoy/features/comparison/presentation/comparison_profile_catalog.dart';
import 'package:domovoy/features/comparison/presentation/profile_settings_controller.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

ProfileSettingsController _controller({
  ComparisonProfileStore? store,
  MemoryApiKeyOverrideStore? shared,
  InMemoryProfileApiKeyOverrideStore? scoped,
  Map<String, String> environment = const {
    deepSeekApiKeyEnvironmentVariable: 'deep-env',
    'CUSTOM_API_KEY': 'custom-env',
  },
}) {
  final catalog = ComparisonProfileCatalog(
    repository: ComparisonProfileRepository(
      store ?? InMemoryComparisonProfileStore(),
    ),
  );
  return ProfileSettingsController(
    catalog: catalog,
    sharedDeepSeekResolver: ApiKeyResolver(
      overrideStore: shared ?? MemoryApiKeyOverrideStore(),
      environment: MapEnvironmentReader(environment),
    ),
    profileOverrideStore: scoped ?? InMemoryProfileApiKeyOverrideStore(),
    environment: MapEnvironmentReader(environment),
  );
}

void main() {
  group('ProfileSettingsState.copyWith', () {
    test('preserves busy flags unless they are set explicitly', () {
      final idle = ProfileSettingsState(
        profiles: kDay5PresetProfiles,
        drafts: const [],
        statuses: const [],
      );
      final saving = idle.copyWith(isSaving: true, message: 'saving');
      expect(saving.isSaving, isTrue);
      expect(saving.copyWith(message: 'still busy').isSaving, isTrue);
      expect(saving.copyWith(isSaving: false).isSaving, isFalse);
      expect(
        idle.copyWith(isLoading: true).copyWith(drafts: []).isLoading,
        isTrue,
      );
    });
  });

  group('ProfileSettingsController', () {
    test('rejects impossible dates when building a UI draft', () {
      final draft = ProfileDraft.fromProfile(
        kDeepSeekFlashProfile,
      ).copyWith(effectiveDate: '2026-02-31');
      expect(
        () => ProfileSettingsController.buildProfile(
          kDeepSeekFlashProfile,
          draft,
        ),
        throwsA(
          isA<ProfileValidationException>().having(
            (error) => error.message,
            'message',
            contains('ГГГГ-ММ-ДД'),
          ),
        ),
      );
    });

    test('keeps dismissal locked until persistence finishes', () async {
      final store = _GatedProfileStore();
      final controller = _controller(store: store);
      addTearDown(controller.dispose);
      await controller.load();

      final pending = controller.save(0);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.isSaving, isTrue);
      expect(controller.state.busy, isTrue);

      final originalModel = controller.state.drafts[0].modelId;
      controller.updateDraft(
        0,
        controller.state.drafts[0].copyWith(modelId: 'should-not-apply'),
      );
      expect(controller.state.drafts[0].modelId, originalModel);
      expect(controller.state.isSaving, isTrue);
      expect(await controller.save(1), isFalse);
      expect(await controller.reset(), isFalse);

      store.gate.complete();
      expect(await pending, isTrue);
      expect(controller.state.busy, isFalse);
    });

    test('unlocks editing after a failed save', () async {
      final controller = _controller(store: _ThrowingProfileStore());
      addTearDown(controller.dispose);
      await controller.load();

      expect(await controller.save(0), isFalse);
      expect(controller.state.busy, isFalse);
      expect(controller.state.isSaving, isFalse);
      expect(controller.state.message, contains('сохранить'));
    });

    test('saveKey follows the draft authentication mode', () async {
      final shared = MemoryApiKeyOverrideStore();
      final scoped = InMemoryProfileApiKeyOverrideStore();
      final controller = _controller(shared: shared, scoped: scoped);
      addTearDown(controller.dispose);
      await controller.load();

      controller.updateDraft(
        0,
        controller.state.drafts[0].copyWith(
          authentication: ProfileAuthenticationMode.profileBearer,
          environmentVariableName: 'CUSTOM_API_KEY',
          endpoint: 'https://example.com/v1/chat/completions',
        ),
      );
      expect(await controller.saveKey(0, '  scoped-secret  '), isTrue);
      expect(scoped.values[kOllamaQwen35ProfileId], 'scoped-secret');
      expect(shared.value, isNull);
    });

    test('removeKey falls back to the environment variable', () async {
      final shared = MemoryApiKeyOverrideStore('saved-deepseek');
      final controller = _controller(shared: shared);
      addTearDown(controller.dispose);
      await controller.load();

      expect(
        controller.state.statuses[1].source,
        ApiKeySource.applicationOverride,
      );
      expect(await controller.removeKey(1), isTrue);
      expect(shared.value, isNull);
      expect(controller.state.statuses[1].source, ApiKeySource.environment);
      expect(controller.state.statuses[1].hasApplicationOverride, isFalse);
    });

    test('saveKey rejects unauthenticated drafts', () async {
      final scoped = InMemoryProfileApiKeyOverrideStore();
      final controller = _controller(scoped: scoped);
      addTearDown(controller.dispose);
      await controller.load();

      expect(await controller.saveKey(0, 'secret'), isFalse);
      expect(scoped.values, isEmpty);
    });
  });
}

final class _GatedProfileStore implements ComparisonProfileStore {
  final Completer<void> gate = Completer<void>();
  String? value;

  @override
  Future<String?> readRaw() async => value;

  @override
  Future<void> writeRaw(String json) async {
    await gate.future;
    value = json;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

final class _ThrowingProfileStore implements ComparisonProfileStore {
  @override
  Future<String?> readRaw() async => null;

  @override
  Future<void> writeRaw(String json) async {
    throw StateError('disk full');
  }

  @override
  Future<void> clear() async {}
}

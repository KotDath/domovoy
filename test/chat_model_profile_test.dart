import 'package:domovoy/features/comparison/data/comparison_profile_store.dart';
import 'package:domovoy/features/comparison/domain/chat_model_profile.dart';
import 'package:domovoy/features/comparison/domain/profile_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Day 5 presets', () {
    test('ships weak/medium/strong identities in documented order', () {
      expect(kDay5PresetProfiles, hasLength(3));
      expect(kDay5PresetProfiles[0], kOllamaQwen35Profile);
      expect(kDay5PresetProfiles[1], kDeepSeekFlashProfile);
      expect(kDay5PresetProfiles[2], kDeepSeekProProfile);
      expect(kOllamaQwen35Profile.tier, ComparisonTier.weak);
      expect(kOllamaQwen35Profile.modelId, 'qwen3.5:2b');
      expect(
        kOllamaQwen35Profile.endpoint,
        Uri.parse('http://localhost:11434/v1/chat/completions'),
      );
      expect(
        kOllamaQwen35Profile.authentication,
        ProfileAuthenticationMode.none,
      );
      expect(kOllamaQwen35Profile.dialect, ChatRequestDialect.ollama);
      expect(kOllamaQwen35Profile.resourceNote, '2B / 2.7 GB');
      expect(kOllamaQwen35Profile.pricing?.zeroProviderFee, isTrue);
      expect(kDeepSeekFlashProfile.modelId, 'deepseek-v4-flash');
      expect(kDeepSeekProProfile.modelId, 'deepseek-v4-pro');
      expect(
        kDeepSeekFlashProfile.endpoint,
        Uri.parse('https://api.deepseek.com/chat/completions'),
      );
      expect(
        kDeepSeekProProfile.endpoint,
        Uri.parse('https://api.deepseek.com/chat/completions'),
      );
      expect(
        kDeepSeekFlashProfile.authentication,
        ProfileAuthenticationMode.sharedDeepSeek,
      );
      expect(kDeepSeekFlashPricing.cacheHitInputPerMillion, 0.0028);
      expect(kDeepSeekFlashPricing.cacheMissInputPerMillion, 0.14);
      expect(kDeepSeekFlashPricing.outputPerMillion, 0.28);
      expect(kDeepSeekProPricing.cacheHitInputPerMillion, 0.003625);
      expect(kDeepSeekProPricing.cacheMissInputPerMillion, 0.435);
      expect(kDeepSeekProPricing.outputPerMillion, 0.87);
      expect(
        formatPricingDate(kDeepSeekFlashPricing.effectiveDate),
        '2026-09-07',
      );
      for (final profile in kDay5PresetProfiles) {
        expect(validateChatModelProfile(profile), isNull);
      }
    });
  });

  group('profile validation', () {
    test('rejects empty labels and models', () {
      expect(
        validateChatModelProfile(kOllamaQwen35Profile.copyWith(label: '  ')),
        contains('Название'),
      );
      expect(
        validateChatModelProfile(kOllamaQwen35Profile.copyWith(modelId: '')),
        contains('модели'),
      );
    });

    test('rejects unstable ids', () {
      expect(
        validateChatModelProfile(kOllamaQwen35Profile.copyWith(id: 'Bad Id')),
        contains('Идентификатор'),
      );
      expect(isValidStableProfileId('ollama-qwen35-2b'), isTrue);
    });

    test('rejects embedded credentials, query, and fragment', () {
      expect(
        validateChatModelProfile(
          kDeepSeekFlashProfile.copyWith(
            endpoint: Uri.parse(
              'https://user:pass@api.deepseek.com/chat/completions',
            ),
          ),
        ),
        contains('учётные данные'),
      );
      expect(
        validateChatModelProfile(
          kDeepSeekFlashProfile.copyWith(
            endpoint: Uri.parse(
              'https://api.deepseek.com/chat/completions?x=1',
            ),
          ),
        ),
        contains('запрос'),
      );
      expect(
        validateChatModelProfile(
          kDeepSeekFlashProfile.copyWith(
            endpoint: Uri.parse(
              'https://api.deepseek.com/chat/completions#frag',
            ),
          ),
        ),
        contains('фрагмент'),
      );
    });

    test('rejects bearer HTTP before any secret lookup', () {
      expect(
        validateChatModelProfile(
          kDeepSeekFlashProfile.copyWith(
            endpoint: Uri.parse('http://api.deepseek.com/chat/completions'),
          ),
        ),
        contains('HTTPS'),
      );
    });

    test('accepts unauthenticated loopback HTTP', () {
      expect(
        validateChatModelProfile(
          kOllamaQwen35Profile.copyWith(
            endpoint: Uri.parse('http://127.0.0.9/v1/chat/completions'),
          ),
        ),
        isNull,
      );
      expect(
        validateChatModelProfile(
          kOllamaQwen35Profile.copyWith(
            endpoint: Uri.parse('http://[::1]/v1/chat/completions'),
          ),
        ),
        isNull,
      );
    });

    test('rejects non-loopback plain HTTP', () {
      expect(
        validateChatModelProfile(
          kOllamaQwen35Profile.copyWith(
            endpoint: Uri.parse('http://192.168.1.10/v1/chat/completions'),
          ),
        ),
        contains('HTTPS обязателен вне локальной машины'),
      );
    });

    test('rejects invalid source URLs and prices', () {
      expect(
        validateChatModelProfile(
          kDeepSeekFlashProfile.copyWith(sourceUrl: Uri.parse('not-a-url')),
        ),
        isNotNull,
      );
      expect(
        validateTokenPricing(
          kDeepSeekFlashPricing.copyWith(cacheHitInputPerMillion: double.nan),
        ),
        contains('неотрицательными'),
      );
      expect(
        validateTokenPricing(
          kDeepSeekFlashPricing.copyWith(outputPerMillion: -1),
        ),
        contains('неотрицательными'),
      );
    });

    test('validates environment variable names for bearer profiles', () {
      expect(
        validateChatModelProfile(
          kOllamaQwen35Profile.copyWith(
            authentication: ProfileAuthenticationMode.profileBearer,
            endpoint: Uri.parse('https://example.com/v1/chat/completions'),
            environmentVariableName: '123BAD',
          ),
        ),
        contains('переменной'),
      );
      expect(
        validateChatModelProfile(
          kOllamaQwen35Profile.copyWith(
            authentication: ProfileAuthenticationMode.profileBearer,
            endpoint: Uri.parse('https://example.com/v1/chat/completions'),
            environmentVariableName: 'CUSTOM_API_KEY',
          ),
        ),
        isNull,
      );
    });
  });

  group('profile serialization', () {
    test('round-trips presets without secret fields', () {
      final encoded = encodeComparisonProfiles(kDay5PresetProfiles);
      expect(encoded, isNot(contains('apiKey')));
      expect(encoded, isNot(contains('authorization')));
      expect(encoded, isNot(contains('Bearer')));
      final decoded = decodeComparisonProfiles(encoded);
      expect(decoded, kDay5PresetProfiles);
    });

    test('falls back from missing and corrupt storage', () async {
      final store = InMemoryComparisonProfileStore();
      final repository = ComparisonProfileRepository(store);
      final missing = await repository.load();
      expect(missing.profiles, kDay5PresetProfiles);
      expect(missing.warning, isNull);

      await store.writeRaw('{not-json');
      final corrupt = await repository.load();
      expect(corrupt.profiles, kDay5PresetProfiles);
      expect(corrupt.warning, contains('повреждены'));

      await store.writeRaw('{"version":1,"profiles":[],"apiKey":"secret"}');
      final secret = await repository.load();
      expect(secret.profiles, kDay5PresetProfiles);
      expect(secret.warning, isNotNull);
    });

    test('rejects documents with secret keys instead of partial parse', () {
      expect(
        () => decodeComparisonProfiles(
          '{"version":1,"api_key":"x","profiles":[]}',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects impossible calendar dates instead of normalizing', () {
      expect(DateTime.utc(2026, 2, 31), DateTime.utc(2026, 3, 3));
      expect(parsePricingDate('2026-02-31'), isNull);
      expect(parsePricingDate('2026-04-31'), isNull);
      expect(parsePricingDate('2026-13-01'), isNull);
      expect(parsePricingDate('2026-00-10'), isNull);
      expect(parsePricingDate('2026-09-00'), isNull);
      expect(parsePricingDate('2025-02-29'), isNull);
      expect(parsePricingDate('2024-02-29'), DateTime.utc(2024, 2, 29));
      expect(parsePricingDate('2026-09-07'), DateTime.utc(2026, 9, 7));
    });

    test('falls back when persisted pricing uses an impossible date', () async {
      final mutated = encodeComparisonProfiles(
        kDay5PresetProfiles,
      ).replaceAll('2026-09-07', '2026-02-31');
      expect(() => decodeComparisonProfiles(mutated), throwsA(anything));
      final loaded = await ComparisonProfileRepository(
        InMemoryComparisonProfileStore(mutated),
      ).load();
      expect(loaded.profiles, kDay5PresetProfiles);
      expect(loaded.warning, isNotNull);
    });
  });
}

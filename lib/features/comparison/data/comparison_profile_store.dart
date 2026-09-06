import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/chat_model_profile.dart';
import '../domain/profile_validation.dart';

final class ComparisonProfileLoadResult {
  const ComparisonProfileLoadResult({required this.profiles, this.warning});

  final List<ChatModelProfile> profiles;
  final String? warning;

  bool get usedFallback => warning != null;
}

abstract interface class ComparisonProfileStore {
  Future<String?> readRaw();

  Future<void> writeRaw(String json);

  Future<void> clear();
}

final class InMemoryComparisonProfileStore implements ComparisonProfileStore {
  InMemoryComparisonProfileStore([this.value]);

  String? value;

  @override
  Future<String?> readRaw() async => value;

  @override
  Future<void> writeRaw(String json) async {
    value = json;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

final class SecureComparisonProfileStore implements ComparisonProfileStore {
  SecureComparisonProfileStore(this._storage);

  static const storageKey = 'day5_comparison_profiles';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readRaw() => _storage.read(key: storageKey);

  @override
  Future<void> writeRaw(String json) =>
      _storage.write(key: storageKey, value: json);

  @override
  Future<void> clear() => _storage.delete(key: storageKey);
}

final class ComparisonProfileRepository {
  const ComparisonProfileRepository(this.store);

  final ComparisonProfileStore store;

  Future<ComparisonProfileLoadResult> load() async {
    try {
      final raw = await store.readRaw();
      if (raw == null || raw.trim().isEmpty) {
        return ComparisonProfileLoadResult(profiles: kDay5PresetProfiles);
      }
      final profiles = decodeComparisonProfiles(raw);
      return ComparisonProfileLoadResult(profiles: profiles);
    } on Object {
      return ComparisonProfileLoadResult(
        profiles: kDay5PresetProfiles,
        warning:
            'Сохранённые профили повреждены. Загружены стандартные настройки.',
      );
    }
  }

  Future<void> save(List<ChatModelProfile> profiles) async {
    if (profiles.length != kComparisonLaneCount) {
      throw const ProfileValidationException(
        'Нужно сохранить ровно три профиля.',
      );
    }
    for (final profile in profiles) {
      ensureValidChatModelProfile(profile);
    }
    await store.writeRaw(encodeComparisonProfiles(profiles));
  }

  Future<void> reset() async {
    await store.clear();
  }
}

String encodeComparisonProfiles(List<ChatModelProfile> profiles) {
  return jsonEncode(<String, Object?>{
    'version': kComparisonProfileDocumentVersion,
    'profiles': [for (final profile in profiles) profile.toJson()],
  });
}

List<ChatModelProfile> decodeComparisonProfiles(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected a profile document object.');
  }
  if (decoded.containsKey('apiKey') ||
      decoded.containsKey('api_key') ||
      decoded.containsKey('authorization')) {
    throw const FormatException(
      'Secret fields are not allowed in profile JSON.',
    );
  }
  final version = decoded['version'];
  if (version != kComparisonProfileDocumentVersion) {
    throw const FormatException('Unsupported profile document version.');
  }
  final items = decoded['profiles'];
  if (items is! List || items.length != kComparisonLaneCount) {
    throw const FormatException('Expected exactly three profiles.');
  }
  return [for (final item in items) parseChatModelProfile(item)];
}

ChatModelProfile parseChatModelProfile(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw const FormatException('Expected a profile object.');
  }
  if (raw.containsKey('apiKey') ||
      raw.containsKey('api_key') ||
      raw.containsKey('key') ||
      raw.containsKey('authorization')) {
    throw const FormatException(
      'Secret fields are not allowed in profile JSON.',
    );
  }
  final endpoint = Uri.tryParse(raw['endpoint'] as String? ?? '');
  final sourceUrl = Uri.tryParse(raw['sourceUrl'] as String? ?? '');
  if (endpoint == null || sourceUrl == null) {
    throw const FormatException('Profile URLs are invalid.');
  }
  final profile = ChatModelProfile(
    id: raw['id'] as String? ?? '',
    label: raw['label'] as String? ?? '',
    tier: requireTier(raw['tier'] as String?),
    endpoint: endpoint,
    modelId: raw['modelId'] as String? ?? '',
    dialect: requireDialect(raw['dialect'] as String?),
    authentication: requireAuthentication(raw['authentication'] as String?),
    environmentVariableName: raw['environmentVariableName'] as String?,
    sourceUrl: sourceUrl,
    resourceNote: raw['resourceNote'] as String? ?? '',
    pricing: parseTokenPricing(raw['pricing']),
  );
  ensureValidChatModelProfile(profile);
  return profile;
}

TokenPricing? parseTokenPricing(Object? raw) {
  if (raw == null) {
    return null;
  }
  if (raw is! Map<String, dynamic>) {
    throw const FormatException('Expected a pricing object.');
  }
  final sourceUrl = Uri.tryParse(raw['sourceUrl'] as String? ?? '');
  final date = parsePricingDate(raw['effectiveDate'] as String?);
  if (sourceUrl == null || date == null) {
    throw const FormatException('Pricing metadata is invalid.');
  }
  final pricing = TokenPricing(
    currency: raw['currency'] as String? ?? '',
    effectiveDate: date,
    sourceUrl: sourceUrl,
    cacheHitInputPerMillion: _doubleField(raw['cacheHitInputPerMillion']),
    cacheMissInputPerMillion: _doubleField(raw['cacheMissInputPerMillion']),
    outputPerMillion: _doubleField(raw['outputPerMillion']),
    zeroProviderFee: raw['zeroProviderFee'] == true,
  );
  final error = validateTokenPricing(pricing);
  if (error != null) {
    throw ProfileValidationException(error);
  }
  return pricing;
}

double? _doubleField(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  throw const FormatException('Expected a numeric price.');
}

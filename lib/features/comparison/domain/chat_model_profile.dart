import 'package:flutter/foundation.dart';

import '../../prompt/domain/chat_request_dialect.dart';

export '../../prompt/domain/chat_request_dialect.dart';

enum ComparisonTier { weak, medium, strong }

enum ProfileAuthenticationMode { none, sharedDeepSeek, profileBearer }

const int kComparisonLaneCount = 3;

const int kComparisonPlannedApiCalls = 3;

const int kComparisonProfileDocumentVersion = 1;

const String kOllamaQwen35ProfileId = 'ollama-qwen35-2b';

const String kDeepSeekFlashProfileId = 'deepseek-v4-flash';

const String kDeepSeekProProfileId = 'deepseek-v4-pro';

const String kOllamaChatCompletionsEndpoint =
    'http://localhost:11434/v1/chat/completions';

const String kDeepSeekChatCompletionsEndpoint =
    'https://api.deepseek.com/chat/completions';

const String kOllamaQwen35ModelId = 'qwen3.5:2b';

const String kDeepSeekFlashModelId = 'deepseek-v4-flash';

const String kDeepSeekProModelId = 'deepseek-v4-pro';

const String kOllamaQwen35SourceUrl = 'https://ollama.com/library/qwen3.5/tags';

const String kDeepSeekPricingSourceUrl =
    'https://api-docs.deepseek.com/quick_start/pricing';

const String kOllamaResourceNote = '2B / 2.7 GB';

final DateTime kComparisonPricingEffectiveDate = DateTime.utc(2026, 9, 7);

@immutable
final class TokenPricing {
  const TokenPricing({
    required this.currency,
    required this.effectiveDate,
    required this.sourceUrl,
    this.cacheHitInputPerMillion,
    this.cacheMissInputPerMillion,
    this.outputPerMillion,
    this.zeroProviderFee = false,
  });

  final String currency;
  final DateTime effectiveDate;
  final Uri sourceUrl;
  final double? cacheHitInputPerMillion;
  final double? cacheMissInputPerMillion;
  final double? outputPerMillion;
  final bool zeroProviderFee;

  bool get hasDistinctCacheRates {
    final hit = cacheHitInputPerMillion;
    final miss = cacheMissInputPerMillion;
    if (hit == null || miss == null) {
      return false;
    }
    return hit != miss;
  }

  TokenPricing copyWith({
    String? currency,
    DateTime? effectiveDate,
    Uri? sourceUrl,
    double? cacheHitInputPerMillion,
    bool clearCacheHitInputPerMillion = false,
    double? cacheMissInputPerMillion,
    bool clearCacheMissInputPerMillion = false,
    double? outputPerMillion,
    bool clearOutputPerMillion = false,
    bool? zeroProviderFee,
  }) {
    return TokenPricing(
      currency: currency ?? this.currency,
      effectiveDate: effectiveDate ?? this.effectiveDate,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      cacheHitInputPerMillion: clearCacheHitInputPerMillion
          ? null
          : cacheHitInputPerMillion ?? this.cacheHitInputPerMillion,
      cacheMissInputPerMillion: clearCacheMissInputPerMillion
          ? null
          : cacheMissInputPerMillion ?? this.cacheMissInputPerMillion,
      outputPerMillion: clearOutputPerMillion
          ? null
          : outputPerMillion ?? this.outputPerMillion,
      zeroProviderFee: zeroProviderFee ?? this.zeroProviderFee,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'currency': currency,
      'effectiveDate': formatPricingDate(effectiveDate),
      'sourceUrl': sourceUrl.toString(),
      'cacheHitInputPerMillion': cacheHitInputPerMillion,
      'cacheMissInputPerMillion': cacheMissInputPerMillion,
      'outputPerMillion': outputPerMillion,
      'zeroProviderFee': zeroProviderFee,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TokenPricing &&
          other.currency == currency &&
          other.effectiveDate == effectiveDate &&
          other.sourceUrl == sourceUrl &&
          other.cacheHitInputPerMillion == cacheHitInputPerMillion &&
          other.cacheMissInputPerMillion == cacheMissInputPerMillion &&
          other.outputPerMillion == outputPerMillion &&
          other.zeroProviderFee == zeroProviderFee;

  @override
  int get hashCode => Object.hash(
    currency,
    effectiveDate,
    sourceUrl,
    cacheHitInputPerMillion,
    cacheMissInputPerMillion,
    outputPerMillion,
    zeroProviderFee,
  );
}

@immutable
final class ChatModelProfile {
  const ChatModelProfile({
    required this.id,
    required this.label,
    required this.tier,
    required this.endpoint,
    required this.modelId,
    required this.dialect,
    required this.authentication,
    required this.sourceUrl,
    this.environmentVariableName,
    this.resourceNote = '',
    this.pricing,
  });

  final String id;
  final String label;
  final ComparisonTier tier;
  final Uri endpoint;
  final String modelId;
  final ChatRequestDialect dialect;
  final ProfileAuthenticationMode authentication;
  final String? environmentVariableName;
  final Uri sourceUrl;
  final String resourceNote;
  final TokenPricing? pricing;

  String get endpointHost =>
      endpoint.host.isEmpty ? endpoint.toString() : endpoint.host;

  ChatModelProfile copyWith({
    String? id,
    String? label,
    ComparisonTier? tier,
    Uri? endpoint,
    String? modelId,
    ChatRequestDialect? dialect,
    ProfileAuthenticationMode? authentication,
    String? environmentVariableName,
    bool clearEnvironmentVariableName = false,
    Uri? sourceUrl,
    String? resourceNote,
    TokenPricing? pricing,
    bool clearPricing = false,
  }) {
    return ChatModelProfile(
      id: id ?? this.id,
      label: label ?? this.label,
      tier: tier ?? this.tier,
      endpoint: endpoint ?? this.endpoint,
      modelId: modelId ?? this.modelId,
      dialect: dialect ?? this.dialect,
      authentication: authentication ?? this.authentication,
      environmentVariableName: clearEnvironmentVariableName
          ? null
          : environmentVariableName ?? this.environmentVariableName,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      resourceNote: resourceNote ?? this.resourceNote,
      pricing: clearPricing ? null : pricing ?? this.pricing,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'label': label,
      'tier': tier.name,
      'endpoint': endpoint.toString(),
      'modelId': modelId,
      'dialect': chatRequestDialectLabel(dialect),
      'authentication': authentication.name,
      'environmentVariableName': environmentVariableName,
      'sourceUrl': sourceUrl.toString(),
      'resourceNote': resourceNote,
      'pricing': pricing?.toJson(),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatModelProfile &&
          other.id == id &&
          other.label == label &&
          other.tier == tier &&
          other.endpoint == endpoint &&
          other.modelId == modelId &&
          other.dialect == dialect &&
          other.authentication == authentication &&
          other.environmentVariableName == environmentVariableName &&
          other.sourceUrl == sourceUrl &&
          other.resourceNote == resourceNote &&
          other.pricing == pricing;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    tier,
    endpoint,
    modelId,
    dialect,
    authentication,
    environmentVariableName,
    sourceUrl,
    resourceNote,
    pricing,
  );
}

final TokenPricing kOllamaZeroProviderPricing = TokenPricing(
  currency: 'USD',
  effectiveDate: kComparisonPricingEffectiveDate,
  sourceUrl: Uri.parse(kOllamaQwen35SourceUrl),
  zeroProviderFee: true,
);

final TokenPricing kDeepSeekFlashPricing = TokenPricing(
  currency: 'USD',
  cacheHitInputPerMillion: 0.0028,
  cacheMissInputPerMillion: 0.14,
  outputPerMillion: 0.28,
  effectiveDate: kComparisonPricingEffectiveDate,
  sourceUrl: Uri.parse(kDeepSeekPricingSourceUrl),
);

final TokenPricing kDeepSeekProPricing = TokenPricing(
  currency: 'USD',
  cacheHitInputPerMillion: 0.003625,
  cacheMissInputPerMillion: 0.435,
  outputPerMillion: 0.87,
  effectiveDate: kComparisonPricingEffectiveDate,
  sourceUrl: Uri.parse(kDeepSeekPricingSourceUrl),
);

final ChatModelProfile kOllamaQwen35Profile = ChatModelProfile(
  id: kOllamaQwen35ProfileId,
  label: 'Ollama qwen3.5:2b',
  tier: ComparisonTier.weak,
  endpoint: Uri.parse(kOllamaChatCompletionsEndpoint),
  modelId: kOllamaQwen35ModelId,
  dialect: ChatRequestDialect.ollama,
  authentication: ProfileAuthenticationMode.none,
  sourceUrl: Uri.parse(kOllamaQwen35SourceUrl),
  resourceNote: kOllamaResourceNote,
  pricing: kOllamaZeroProviderPricing,
);

final ChatModelProfile kDeepSeekFlashProfile = ChatModelProfile(
  id: kDeepSeekFlashProfileId,
  label: 'DeepSeek V4 Flash',
  tier: ComparisonTier.medium,
  endpoint: Uri.parse(kDeepSeekChatCompletionsEndpoint),
  modelId: kDeepSeekFlashModelId,
  dialect: ChatRequestDialect.deepSeek,
  authentication: ProfileAuthenticationMode.sharedDeepSeek,
  environmentVariableName: 'DEEPSEEK_API_KEY',
  sourceUrl: Uri.parse(kDeepSeekPricingSourceUrl),
  pricing: kDeepSeekFlashPricing,
);

final ChatModelProfile kDeepSeekProProfile = ChatModelProfile(
  id: kDeepSeekProProfileId,
  label: 'DeepSeek V4 Pro',
  tier: ComparisonTier.strong,
  endpoint: Uri.parse(kDeepSeekChatCompletionsEndpoint),
  modelId: kDeepSeekProModelId,
  dialect: ChatRequestDialect.deepSeek,
  authentication: ProfileAuthenticationMode.sharedDeepSeek,
  environmentVariableName: 'DEEPSEEK_API_KEY',
  sourceUrl: Uri.parse(kDeepSeekPricingSourceUrl),
  pricing: kDeepSeekProPricing,
);

final List<ChatModelProfile> kDay5PresetProfiles =
    List<ChatModelProfile>.unmodifiable(<ChatModelProfile>[
      kOllamaQwen35Profile,
      kDeepSeekFlashProfile,
      kDeepSeekProProfile,
    ]);

String comparisonTierLabel(ComparisonTier tier) => switch (tier) {
  ComparisonTier.weak => 'слабая',
  ComparisonTier.medium => 'средняя',
  ComparisonTier.strong => 'сильная',
};

String formatPricingDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

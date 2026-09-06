import 'package:flutter/foundation.dart';

import '../../../core/environment/environment_reader.dart';
import '../../settings/domain/api_key_credentials.dart';
import '../data/profile_credential_resolver.dart';
import '../domain/chat_model_profile.dart';
import '../domain/profile_validation.dart';
import 'comparison_profile_catalog.dart';

@immutable
final class ProfileDraft {
  const ProfileDraft({
    required this.endpoint,
    required this.modelId,
    required this.dialect,
    required this.authentication,
    required this.sourceUrl,
    this.environmentVariableName = '',
    this.resourceNote = '',
    this.currency = 'USD',
    this.effectiveDate = '',
    this.pricingSourceUrl = '',
    this.cacheHitInputPerMillion = '',
    this.cacheMissInputPerMillion = '',
    this.outputPerMillion = '',
    this.zeroProviderFee = false,
    this.hasPricing = false,
  });

  factory ProfileDraft.fromProfile(ChatModelProfile profile) {
    final pricing = profile.pricing;
    return ProfileDraft(
      endpoint: profile.endpoint.toString(),
      modelId: profile.modelId,
      dialect: profile.dialect,
      authentication: profile.authentication,
      environmentVariableName: profile.environmentVariableName ?? '',
      sourceUrl: profile.sourceUrl.toString(),
      resourceNote: profile.resourceNote,
      currency: pricing?.currency ?? 'USD',
      effectiveDate: pricing == null
          ? formatPricingDate(kComparisonPricingEffectiveDate)
          : formatPricingDate(pricing.effectiveDate),
      pricingSourceUrl: pricing?.sourceUrl.toString() ?? '',
      cacheHitInputPerMillion: _number(pricing?.cacheHitInputPerMillion),
      cacheMissInputPerMillion: _number(pricing?.cacheMissInputPerMillion),
      outputPerMillion: _number(pricing?.outputPerMillion),
      zeroProviderFee: pricing?.zeroProviderFee ?? false,
      hasPricing: pricing != null,
    );
  }

  final String endpoint;
  final String modelId;
  final ChatRequestDialect dialect;
  final ProfileAuthenticationMode authentication;
  final String environmentVariableName;
  final String sourceUrl;
  final String resourceNote;
  final String currency;
  final String effectiveDate;
  final String pricingSourceUrl;
  final String cacheHitInputPerMillion;
  final String cacheMissInputPerMillion;
  final String outputPerMillion;
  final bool zeroProviderFee;
  final bool hasPricing;

  ProfileDraft copyWith({
    String? endpoint,
    String? modelId,
    ChatRequestDialect? dialect,
    ProfileAuthenticationMode? authentication,
    String? environmentVariableName,
    String? sourceUrl,
    String? resourceNote,
    String? currency,
    String? effectiveDate,
    String? pricingSourceUrl,
    String? cacheHitInputPerMillion,
    String? cacheMissInputPerMillion,
    String? outputPerMillion,
    bool? zeroProviderFee,
    bool? hasPricing,
  }) {
    return ProfileDraft(
      endpoint: endpoint ?? this.endpoint,
      modelId: modelId ?? this.modelId,
      dialect: dialect ?? this.dialect,
      authentication: authentication ?? this.authentication,
      environmentVariableName:
          environmentVariableName ?? this.environmentVariableName,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      resourceNote: resourceNote ?? this.resourceNote,
      currency: currency ?? this.currency,
      effectiveDate: effectiveDate ?? this.effectiveDate,
      pricingSourceUrl: pricingSourceUrl ?? this.pricingSourceUrl,
      cacheHitInputPerMillion:
          cacheHitInputPerMillion ?? this.cacheHitInputPerMillion,
      cacheMissInputPerMillion:
          cacheMissInputPerMillion ?? this.cacheMissInputPerMillion,
      outputPerMillion: outputPerMillion ?? this.outputPerMillion,
      zeroProviderFee: zeroProviderFee ?? this.zeroProviderFee,
      hasPricing: hasPricing ?? this.hasPricing,
    );
  }

  static String _number(double? value) => value == null ? '' : value.toString();
}

@immutable
final class ProfileSettingsState {
  const ProfileSettingsState({
    required this.profiles,
    required this.drafts,
    required this.statuses,
    this.isLoading = false,
    this.isSaving = false,
    this.message,
    this.errors = const <int, String>{},
    this.formEpoch = 0,
  });

  final List<ChatModelProfile> profiles;
  final List<ProfileDraft> drafts;
  final List<ApiKeyStatus> statuses;
  final bool isLoading;
  final bool isSaving;
  final String? message;
  final Map<int, String> errors;
  final int formEpoch;

  bool get busy => isLoading || isSaving;

  ProfileSettingsState copyWith({
    List<ChatModelProfile>? profiles,
    List<ProfileDraft>? drafts,
    List<ApiKeyStatus>? statuses,
    bool? isLoading,
    bool? isSaving,
    String? message,
    bool clearMessage = false,
    Map<int, String>? errors,
    int? formEpoch,
  }) {
    return ProfileSettingsState(
      profiles: profiles ?? this.profiles,
      drafts: drafts ?? this.drafts,
      statuses: statuses ?? this.statuses,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      message: clearMessage ? null : message ?? this.message,
      errors: errors ?? this.errors,
      formEpoch: formEpoch ?? this.formEpoch,
    );
  }
}

final class ProfileSettingsController extends ChangeNotifier {
  ProfileSettingsController({
    required ComparisonProfileCatalog catalog,
    required ApiKeyResolver sharedDeepSeekResolver,
    required ProfileApiKeyOverrideStore profileOverrideStore,
    required EnvironmentReader environment,
  }) : _catalog = catalog,
       _sharedDeepSeekResolver = sharedDeepSeekResolver,
       _profileOverrideStore = profileOverrideStore,
       _environment = environment;

  final ComparisonProfileCatalog _catalog;
  final ApiKeyResolver _sharedDeepSeekResolver;
  final ProfileApiKeyOverrideStore _profileOverrideStore;
  final EnvironmentReader _environment;
  ProfileSettingsState _state = ProfileSettingsState(
    profiles: kDay5PresetProfiles,
    drafts: [
      for (final profile in kDay5PresetProfiles)
        ProfileDraft.fromProfile(profile),
    ],
    statuses: const [
      ApiKeyStatus(source: ApiKeySource.none, hasApplicationOverride: false),
      ApiKeyStatus(source: ApiKeySource.missing, hasApplicationOverride: false),
      ApiKeyStatus(source: ApiKeySource.missing, hasApplicationOverride: false),
    ],
    isLoading: true,
  );
  bool _disposed = false;

  ProfileSettingsState get state => _state;

  Future<void> load() async {
    if (_disposed || _state.isSaving) {
      return;
    }
    _state = _state.copyWith(isLoading: true);
    _notify();
    try {
      await _catalog.load();
      await _refresh(message: null);
    } on Object {
      _state = _state.copyWith(
        isLoading: false,
        message: 'Не удалось загрузить профили.',
      );
      _notify();
    }
  }

  void updateDraft(int index, ProfileDraft draft) {
    if (_disposed || _state.busy) {
      return;
    }
    final drafts = [..._state.drafts];
    drafts[index] = draft;
    final errors = Map<int, String>.from(_state.errors)..remove(index);
    _state = _state.copyWith(drafts: drafts, errors: errors);
    _notify();
  }

  Future<bool> save(int index) async {
    if (_disposed || _state.busy) {
      return false;
    }
    ChatModelProfile profile;
    try {
      profile = buildProfile(_state.profiles[index], _state.drafts[index]);
      ensureValidChatModelProfile(profile);
    } on ProfileValidationException catch (error) {
      _setError(index, error.message);
      return false;
    } on FormatException catch (error) {
      _setError(index, error.message);
      return false;
    }
    _setSaving();
    try {
      await _catalog.saveOne(index, profile);
      await _refresh(message: 'Профиль сохранён.');
      return true;
    } on Object catch (error) {
      _setError(
        index,
        error is ProfileValidationException
            ? error.message
            : 'Не удалось сохранить профиль.',
      );
      return false;
    }
  }

  Future<bool> saveKey(int index, String rawValue) async {
    if (_disposed || _state.busy) {
      return false;
    }
    final value = rawValue.trim();
    if (value.isEmpty) {
      _setError(index, 'Введите непустой API-ключ.');
      return false;
    }
    final draft = _state.drafts[index];
    final profile = _state.profiles[index];
    if (draft.authentication == ProfileAuthenticationMode.none) {
      _setError(index, 'Этот профиль выполняется без ключа.');
      return false;
    }
    _setSaving();
    try {
      if (draft.authentication == ProfileAuthenticationMode.sharedDeepSeek) {
        await _sharedDeepSeekResolver.overrideStore.write(value);
      } else {
        await _profileOverrideStore.write(profile.id, value);
      }
      await _refresh(message: 'Ключ сохранён. Значение скрыто.');
      return true;
    } on Object {
      _setError(index, 'Не удалось сохранить ключ.');
      return false;
    }
  }

  Future<bool> removeKey(int index) async {
    if (_disposed || _state.busy) {
      return false;
    }
    final saved = _state.profiles[index];
    if (saved.authentication == ProfileAuthenticationMode.none) {
      return false;
    }
    _setSaving();
    try {
      if (saved.authentication == ProfileAuthenticationMode.sharedDeepSeek) {
        await _sharedDeepSeekResolver.overrideStore.delete();
      } else {
        await _profileOverrideStore.delete(saved.id);
      }
      await _refresh(message: 'Ключ профиля удалён.');
      return true;
    } on Object {
      _setError(index, 'Не удалось удалить ключ.');
      return false;
    }
  }

  Future<bool> reset() async {
    if (_disposed || _state.busy) {
      return false;
    }
    _setSaving();
    try {
      await _catalog.reset();
      await _refresh(
        message: 'Восстановлены стандартные профили. Ключи не удалялись.',
      );
      return true;
    } on Object {
      _state = _state.copyWith(
        isSaving: false,
        message: 'Не удалось сбросить профили.',
      );
      _notify();
      return false;
    }
  }

  static ChatModelProfile buildProfile(
    ChatModelProfile base,
    ProfileDraft draft,
  ) {
    final endpoint = Uri.tryParse(draft.endpoint.trim());
    final sourceUrl = Uri.tryParse(draft.sourceUrl.trim());
    if (endpoint == null || draft.endpoint.trim().isEmpty) {
      throw const ProfileValidationException('Укажите абсолютный адрес API.');
    }
    if (sourceUrl == null || draft.sourceUrl.trim().isEmpty) {
      throw const ProfileValidationException('Укажите ссылку на источник.');
    }
    final env = draft.environmentVariableName.trim();
    return base.copyWith(
      endpoint: endpoint,
      modelId: draft.modelId.trim(),
      dialect: draft.dialect,
      authentication: draft.authentication,
      environmentVariableName: env.isEmpty ? null : env,
      clearEnvironmentVariableName: env.isEmpty,
      sourceUrl: sourceUrl,
      resourceNote: draft.resourceNote.trim(),
      pricing: draft.hasPricing ? _pricingFrom(draft) : null,
      clearPricing: !draft.hasPricing,
    );
  }

  static TokenPricing _pricingFrom(ProfileDraft draft) {
    final sourceUrl = Uri.tryParse(draft.pricingSourceUrl.trim());
    final date = _parseDate(draft.effectiveDate);
    if (sourceUrl == null || draft.pricingSourceUrl.trim().isEmpty) {
      throw const ProfileValidationException('Укажите ссылку на тариф.');
    }
    if (date == null) {
      throw const ProfileValidationException(
        'Дата тарифа должна быть в формате ГГГГ-ММ-ДД.',
      );
    }
    return TokenPricing(
      currency: draft.currency.trim().isEmpty ? 'USD' : draft.currency.trim(),
      effectiveDate: date,
      sourceUrl: sourceUrl,
      cacheHitInputPerMillion: _parseRate(draft.cacheHitInputPerMillion),
      cacheMissInputPerMillion: _parseRate(draft.cacheMissInputPerMillion),
      outputPerMillion: _parseRate(draft.outputPerMillion),
      zeroProviderFee: draft.zeroProviderFee,
    );
  }

  static DateTime? _parseDate(String raw) => parsePricingDate(raw);

  static double? _parseRate(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final value = double.tryParse(trimmed);
    if (value == null) {
      throw const ProfileValidationException(
        'Цены за миллион токенов должны быть числами.',
      );
    }
    return value;
  }

  Future<void> _refresh({required String? message}) async {
    try {
      final profiles = _catalog.profiles;
      final statuses = <ApiKeyStatus>[];
      for (final profile in profiles) {
        statuses.add(
          await credentialStatusForProfile(
            profile: profile,
            sharedDeepSeekResolver: _sharedDeepSeekResolver,
            profileOverrideStore: _profileOverrideStore,
            environment: _environment,
          ),
        );
      }
      _state = ProfileSettingsState(
        profiles: profiles,
        drafts: [
          for (final profile in profiles) ProfileDraft.fromProfile(profile),
        ],
        statuses: statuses,
        message: message ?? _catalog.warning,
        formEpoch: _state.formEpoch + 1,
        errors: const <int, String>{},
      );
      _notify();
    } on Object {
      _state = _state.copyWith(
        isLoading: false,
        isSaving: false,
        message: 'Не удалось обновить статусы профилей.',
      );
      _notify();
      rethrow;
    }
  }

  void _setSaving() {
    _state = _state.copyWith(isSaving: true);
    _notify();
  }

  void _setError(int index, String message) {
    final errors = Map<int, String>.from(_state.errors);
    errors[index] = message;
    _state = _state.copyWith(
      errors: errors,
      message: message,
      isSaving: false,
      isLoading: false,
    );
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

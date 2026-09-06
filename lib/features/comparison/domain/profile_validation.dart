import 'chat_model_profile.dart';

final RegExp _stableIdPattern = RegExp(r'^[a-z][a-z0-9_-]{1,63}$');

final RegExp _environmentVariablePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

class ProfileValidationException implements Exception {
  const ProfileValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool isValidStableProfileId(String id) => _stableIdPattern.hasMatch(id);

String? validateChatModelProfile(ChatModelProfile profile) {
  if (!isValidStableProfileId(profile.id)) {
    return 'Идентификатор профиля должен состоять из латиницы, цифр, "_" или "-" и начинаться с буквы.';
  }
  if (profile.label.trim().isEmpty) {
    return 'Название профиля не должно быть пустым.';
  }
  if (profile.modelId.trim().isEmpty) {
    return 'Идентификатор модели не должен быть пустым.';
  }
  final endpointError = validateEndpoint(
    profile.endpoint,
    profile.authentication,
  );
  if (endpointError != null) {
    return endpointError;
  }
  final sourceError = validateAbsoluteHttpUrl(
    profile.sourceUrl,
    'ссылка на источник',
  );
  if (sourceError != null) {
    return sourceError;
  }
  switch (profile.authentication) {
    case ProfileAuthenticationMode.none:
      if (profile.environmentVariableName != null &&
          profile.environmentVariableName!.trim().isNotEmpty) {
        return 'Для профиля без аутентификации переменная окружения не задаётся.';
      }
    case ProfileAuthenticationMode.sharedDeepSeek:
      final name = profile.environmentVariableName?.trim();
      if (name != null && name.isNotEmpty && name != 'DEEPSEEK_API_KEY') {
        return 'Общий ключ DeepSeek использует переменную DEEPSEEK_API_KEY.';
      }
    case ProfileAuthenticationMode.profileBearer:
      final name = profile.environmentVariableName?.trim();
      if (name == null || name.isEmpty) {
        return 'Для профиля с ключом укажите имя переменной окружения.';
      }
      if (!_environmentVariablePattern.hasMatch(name)) {
        return 'Имя переменной окружения может содержать только латиницу, цифры и "_".';
      }
  }
  final pricing = profile.pricing;
  if (pricing != null) {
    final pricingError = validateTokenPricing(pricing);
    if (pricingError != null) {
      return pricingError;
    }
  }
  return null;
}

void ensureValidChatModelProfile(ChatModelProfile profile) {
  final error = validateChatModelProfile(profile);
  if (error != null) {
    throw ProfileValidationException(error);
  }
}

String? validateEndpoint(
  Uri endpoint,
  ProfileAuthenticationMode authentication,
) {
  if (!endpoint.hasScheme || !endpoint.hasAuthority) {
    return 'Адрес API должен быть абсолютным HTTP(S) URI.';
  }
  if (endpoint.userInfo.isNotEmpty) {
    return 'Адрес API не должен содержать учётные данные.';
  }
  if (endpoint.hasQuery || endpoint.query.isNotEmpty) {
    return 'Адрес API не должен содержать строку запроса.';
  }
  if (endpoint.hasFragment || (endpoint.fragment.isNotEmpty)) {
    return 'Адрес API не должен содержать фрагмент.';
  }
  if (endpoint.host.trim().isEmpty) {
    return 'Адрес API должен содержать хост.';
  }
  if (endpoint.scheme != 'http' && endpoint.scheme != 'https') {
    return 'Адрес API должен использовать HTTP или HTTPS.';
  }
  if (authentication != ProfileAuthenticationMode.none &&
      endpoint.scheme != 'https') {
    return 'Для профилей с ключом нужен HTTPS. Запрос с секретом не выполняется.';
  }
  if (endpoint.scheme == 'http' && !isLoopbackHost(endpoint.host)) {
    return 'HTTPS обязателен вне локальной машины.';
  }
  return null;
}

String? validateAbsoluteHttpUrl(Uri url, String fieldName) {
  if (!url.hasScheme || !url.hasAuthority) {
    return 'Поле «$fieldName» должно быть абсолютным HTTP(S) URL.';
  }
  if (url.userInfo.isNotEmpty) {
    return 'Поле «$fieldName» не должно содержать учётные данные.';
  }
  if (url.host.trim().isEmpty) {
    return 'Поле «$fieldName» должно содержать хост.';
  }
  if (url.scheme != 'http' && url.scheme != 'https') {
    return 'Поле «$fieldName» должно использовать HTTP или HTTPS.';
  }
  return null;
}

String? validateTokenPricing(TokenPricing pricing) {
  if (pricing.currency.trim().isEmpty) {
    return 'Укажите валюту тарифа.';
  }
  final sourceError = validateAbsoluteHttpUrl(
    pricing.sourceUrl,
    'ссылка на тариф',
  );
  if (sourceError != null) {
    return sourceError;
  }
  for (final entry in <MapEntry<String, double?>>[
    MapEntry('cache-hit', pricing.cacheHitInputPerMillion),
    MapEntry('cache-miss', pricing.cacheMissInputPerMillion),
    MapEntry('output', pricing.outputPerMillion),
  ]) {
    final value = entry.value;
    if (value == null) {
      continue;
    }
    if (!value.isFinite || value < 0) {
      return 'Цены за миллион токенов должны быть конечными и неотрицательными.';
    }
  }
  return null;
}

String? validateEnvironmentVariableName(String? name) {
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty) {
    return 'Укажите имя переменной окружения.';
  }
  if (!_environmentVariablePattern.hasMatch(trimmed)) {
    return 'Имя переменной окружения может содержать только латиницу, цифры и "_".';
  }
  return null;
}

bool isLoopbackHost(String host) {
  var normalized = host.trim().toLowerCase();
  if (normalized.startsWith('[') && normalized.endsWith(']')) {
    normalized = normalized.substring(1, normalized.length - 1);
  }
  if (normalized == 'localhost' ||
      normalized == '::1' ||
      normalized == '0:0:0:0:0:0:0:1') {
    return true;
  }
  final parts = normalized.split('.');
  if (parts.length != 4) {
    return false;
  }
  final octets = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) {
      return false;
    }
    octets.add(value);
  }
  return octets[0] == 127;
}

ChatRequestDialect requireDialect(String? name) {
  final dialect = chatRequestDialectFromName(name);
  if (dialect == null) {
    throw const ProfileValidationException('Неизвестный диалект запроса.');
  }
  return dialect;
}

ComparisonTier requireTier(String? name) {
  return switch (name) {
    'weak' => ComparisonTier.weak,
    'medium' => ComparisonTier.medium,
    'strong' => ComparisonTier.strong,
    _ => throw const ProfileValidationException('Неизвестный уровень профиля.'),
  };
}

ProfileAuthenticationMode requireAuthentication(String? name) {
  return switch (name) {
    'none' => ProfileAuthenticationMode.none,
    'sharedDeepSeek' => ProfileAuthenticationMode.sharedDeepSeek,
    'profileBearer' => ProfileAuthenticationMode.profileBearer,
    _ => throw const ProfileValidationException(
      'Неизвестный режим аутентификации.',
    ),
  };
}

DateTime? parsePricingDate(String? raw) {
  final value = raw?.trim() ?? '';
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (match == null) {
    return null;
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) {
    return null;
  }
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    return null;
  }
  return date;
}

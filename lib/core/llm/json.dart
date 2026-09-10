import 'errors.dart';

const llmJsonVersion = 1;

const llmJsonTypeKey = 'type';
const llmJsonVersionKey = 'version';

Map<String, Object?> decodeTypedJson(
  Object? json, {
  required String type,
  int version = llmJsonVersion,
}) {
  if (json is! Map<Object?, Object?> && json is! Map) {
    throwLlm(LlmErrorKind.protocol, 'Expected a JSON object for $type.');
  }
  final raw = Map<Object?, Object?>.from(json as Map);
  final map = <String, Object?>{};
  raw.forEach((key, value) {
    if (key is! String) {
      throwLlm(LlmErrorKind.protocol, 'JSON object keys must be strings.');
    }
    map[key] = value;
  });
  if (map[llmJsonTypeKey] != type) {
    throwLlm(LlmErrorKind.protocol, 'Expected type "$type".');
  }
  final versionValue = map[llmJsonVersionKey];
  if (versionValue is! int || versionValue != version) {
    throwLlm(LlmErrorKind.protocol, 'Unsupported version for "$type".');
  }
  return map;
}

Map<String, Object?> typedJson({
  required String type,
  required Map<String, Object?> fields,
  int version = llmJsonVersion,
}) {
  return freezeJsonMap(<String, Object?>{
    llmJsonTypeKey: type,
    llmJsonVersionKey: version,
    ...fields,
  });
}

String requireString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) {
    throwLlm(LlmErrorKind.protocol, 'Expected string field "$key".');
  }
  return value;
}

String requireNonBlankString(Map<String, Object?> json, String key) {
  final value = requireString(json, key).trim();
  if (value.isEmpty) {
    throwLlm(LlmErrorKind.protocol, 'Expected non-blank field "$key".');
  }
  return value;
}

String? optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throwLlm(LlmErrorKind.protocol, 'Expected string field "$key".');
  }
  return value;
}

int requireInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) {
    throwLlm(LlmErrorKind.protocol, 'Expected integer field "$key".');
  }
  return value;
}

int requirePositiveInt(Map<String, Object?> json, String key) {
  final value = requireInt(json, key);
  if (value <= 0) {
    throwLlm(LlmErrorKind.protocol, 'Expected positive integer field "$key".');
  }
  return value;
}

int? optionalNonNegativeInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throwLlm(LlmErrorKind.protocol, 'Expected integer field "$key".');
  }
  if (value < 0) {
    throwLlm(
      LlmErrorKind.protocol,
      'Expected non-negative integer field "$key".',
    );
  }
  return value;
}

double? optionalFiniteDouble(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! num) {
    throwLlm(LlmErrorKind.protocol, 'Expected number field "$key".');
  }
  final asDouble = value.toDouble();
  if (asDouble.isNaN || asDouble.isInfinite) {
    throwLlm(LlmErrorKind.protocol, 'Expected finite number field "$key".');
  }
  return asDouble;
}

bool requireBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throwLlm(LlmErrorKind.protocol, 'Expected boolean field "$key".');
  }
  return value;
}

List<Object?> requireList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List) {
    throwLlm(LlmErrorKind.protocol, 'Expected list field "$key".');
  }
  return List<Object?>.from(value);
}

Map<String, Object?>? asJsonObject(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! Map) {
    return null;
  }
  final map = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      return null;
    }
    map[entry.key as String] = entry.value;
  }
  return map;
}

Map<String, Object?>? optionalJsonMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! Map) {
    throwLlm(LlmErrorKind.protocol, 'Expected object field "$key".');
  }
  final map = <String, Object?>{};
  value.forEach((mapKey, mapValue) {
    if (mapKey is! String) {
      throwLlm(LlmErrorKind.protocol, 'JSON object keys must be strings.');
    }
    map[mapKey] = mapValue;
  });
  return map;
}

Object? deepCopyJson(Object? value) {
  if (value == null || value is bool || value is String) {
    return value;
  }
  if (value is num) {
    if (value is double && (value.isNaN || value.isInfinite)) {
      throwLlm(LlmErrorKind.protocol, 'JSON numbers must be finite.');
    }
    return value;
  }
  if (value is List) {
    return value.map(deepCopyJson).toList(growable: true);
  }
  if (value is Map) {
    final copy = <String, Object?>{};
    value.forEach((key, nested) {
      if (key is! String) {
        throwLlm(LlmErrorKind.protocol, 'JSON object keys must be strings.');
      }
      copy[key] = deepCopyJson(nested);
    });
    return copy;
  }
  throwLlm(LlmErrorKind.protocol, 'Unsupported JSON value.');
}

Object? deepFreezeJson(Object? value) => _freeze(deepCopyJson(value));

Map<String, Object?> freezeJsonMap(Map<String, Object?> source) {
  return Map<String, Object?>.unmodifiable(
    source.map((key, value) => MapEntry(key, deepFreezeJson(value))),
  );
}

List<Object?> freezeJsonList(Iterable<Object?> source) {
  return List<Object?>.unmodifiable(source.map(deepFreezeJson));
}

Map<String, Object?> copyJsonMap(Map<String, Object?> source) {
  final copy = <String, Object?>{};
  source.forEach((key, value) {
    copy[key] = deepCopyJson(value);
  });
  return copy;
}

bool jsonEquals(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var i = 0; i < left.length; i++) {
      if (!jsonEquals(left[i], right[i])) {
        return false;
      }
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final key in left.keys) {
      if (!right.containsKey(key) || !jsonEquals(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

int jsonHash(Object? value) {
  if (value is List) {
    return Object.hashAll(value.map(jsonHash));
  }
  if (value is Map) {
    final entryHashes =
        value.entries
            .map((entry) => Object.hash(entry.key, jsonHash(entry.value)))
            .toList()
          ..sort();
    return Object.hashAll(entryHashes);
  }
  return value.hashCode;
}

bool listEquals<T>(List<T> left, List<T> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

Object? _freeze(Object? value) {
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freeze));
  }
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, nested) => MapEntry(key as String, _freeze(nested))),
    );
  }
  return value;
}

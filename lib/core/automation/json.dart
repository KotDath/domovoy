import 'errors.dart';

/// Immutable copy of a JSON object.
Map<String, Object?> freezeJsonMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(value);

/// Requires a JSON object and returns a shallow copy.
Map<String, Object?> requireJsonObject(Object? json, String label) {
  if (json is! Map) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      '$label должен быть JSON-объектом.',
    );
  }
  final result = <String, Object?>{};
  for (final entry in json.entries) {
    if (entry.key is! String) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        '$label содержит нестроковый ключ.',
      );
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String requireJsonText(
  Map<String, Object?> json,
  String key, {
  required String label,
  int? maxLength,
}) {
  final value = json[key];
  if (value is! String) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      '$label: поле "$key" должно быть строкой.',
    );
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      '$label: поле "$key" не должно быть пустым.',
    );
  }
  if (maxLength != null && trimmed.length > maxLength) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      '$label: поле "$key" длиннее $maxLength символов.',
    );
  }
  return trimmed;
}

int requireJsonInt(
  Map<String, Object?> json,
  String key, {
  required String label,
  int? minimum,
}) {
  final value = json[key];
  if (value is! int) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      '$label: поле "$key" должно быть целым числом.',
    );
  }
  if (minimum != null && value < minimum) {
    throwAutomation(
      AutomationErrorKind.invalidInput,
      '$label: поле "$key" должно быть не меньше $minimum.',
    );
  }
  return value;
}

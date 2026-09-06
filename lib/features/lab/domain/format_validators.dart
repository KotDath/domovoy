import 'dart:convert';

import 'format_contracts.dart';

final class FormatValidationResult {
  const FormatValidationResult({
    required this.valid,
    required this.diagnostics,
  });

  final bool valid;
  final List<String> diagnostics;
}

FormatValidationResult validateJsonAnswer(
  String answer,
  JsonFormatContract contract,
) {
  final trimmed = answer.trim();
  if (trimmed.isEmpty) {
    return const FormatValidationResult(
      valid: false,
      diagnostics: <String>['Ответ пуст.'],
    );
  }
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return const FormatValidationResult(
      valid: false,
      diagnostics: <String>['Ответ не является корректным JSON-объектом.'],
    );
  }
  if (decoded is! Map<String, dynamic>) {
    return const FormatValidationResult(
      valid: false,
      diagnostics: <String>['Ответ должен быть одним JSON-объектом.'],
    );
  }
  final diagnostics = <String>[];
  for (final field in contract.fields) {
    final name = field.name.trim();
    if (!decoded.containsKey(name)) {
      diagnostics.add('Отсутствует ключ "$name".');
      continue;
    }
    final value = decoded[name];
    if (!_matchesType(value, field.type)) {
      diagnostics.add(
        'Поле "$name" должно быть типа '
        '${jsonFieldTypeLabel(field.type)}.',
      );
      continue;
    }
    final expected = field.expectedCount;
    if (expected != null) {
      final actual = _collectionCount(value);
      if (actual == null) {
        diagnostics.add(
          'Поле "$name" не является коллекцией для проверки количества.',
        );
      } else if (actual != expected) {
        diagnostics.add(
          'Поле "$name" должно содержать $expected элементов, '
          'найдено $actual.',
        );
      }
    }
  }
  return FormatValidationResult(
    valid: diagnostics.isEmpty,
    diagnostics: diagnostics,
  );
}

bool _matchesType(Object? value, JsonFieldType type) {
  return switch (type) {
    JsonFieldType.string => value is String,
    JsonFieldType.integer => value is int,
    JsonFieldType.number => value is num,
    JsonFieldType.boolean => value is bool,
    JsonFieldType.array => value is List,
    JsonFieldType.object => value is Map,
  };
}

int? _collectionCount(Object? value) {
  if (value is List) {
    return value.length;
  }
  if (value is Map) {
    return value.length;
  }
  return null;
}

final _headingPattern = RegExp(r'^#{1,6}\s+(.+?)\s*$', multiLine: true);
final _unorderedPattern = RegExp(r'^\s*[-*+]\s+\S', multiLine: true);
final _orderedPattern = RegExp(r'^\s*\d+[.)]\s+\S', multiLine: true);

FormatValidationResult validateMarkdownAnswer(
  String answer,
  MarkdownFormatContract contract,
) {
  final trimmed = answer.trim();
  if (trimmed.isEmpty) {
    return const FormatValidationResult(
      valid: false,
      diagnostics: <String>['Ответ пуст.'],
    );
  }
  final diagnostics = <String>[];
  final actualHeadings = _headingPattern
      .allMatches(answer)
      .map((match) => match.group(1)!.trim())
      .toList();
  var cursor = 0;
  for (final required in contract.headings) {
    final wanted = required.trim();
    var found = -1;
    for (var i = cursor; i < actualHeadings.length; i++) {
      if (actualHeadings[i] == wanted) {
        found = i;
        break;
      }
    }
    if (found < 0) {
      diagnostics.add('Отсутствует заголовок "$wanted" в требуемом порядке.');
    } else {
      cursor = found + 1;
    }
  }

  final pattern = contract.listKind == MarkdownListKind.unordered
      ? _unorderedPattern
      : _orderedPattern;
  final count = pattern.allMatches(answer).length;
  if (count != contract.expectedItems) {
    diagnostics.add(
      'Список должен содержать ${contract.expectedItems} пунктов '
      '(${markdownListKindLabel(contract.listKind)}), найдено $count.',
    );
  }
  return FormatValidationResult(
    valid: diagnostics.isEmpty,
    diagnostics: diagnostics,
  );
}

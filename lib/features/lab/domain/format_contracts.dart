import 'dart:convert';

/// Maximum supported collection size for contract counts (array items,
/// object properties, Markdown list items). Counts above this are rejected
/// during contract validation so examples and validators always agree on
/// exact numbers.
const int maxSupportedCollectionCount = 10;

enum JsonFieldType { string, integer, number, boolean, array, object }

String jsonFieldTypeLabel(JsonFieldType type) => switch (type) {
  JsonFieldType.string => 'string',
  JsonFieldType.integer => 'integer',
  JsonFieldType.number => 'number',
  JsonFieldType.boolean => 'boolean',
  JsonFieldType.array => 'array',
  JsonFieldType.object => 'object',
};

JsonFieldType? parseJsonFieldType(String raw) {
  final normalized = raw.trim().toLowerCase();
  for (final type in JsonFieldType.values) {
    if (jsonFieldTypeLabel(type) == normalized) {
      return type;
    }
  }
  return null;
}

final class JsonFieldSpec {
  const JsonFieldSpec({
    required this.name,
    required this.type,
    this.expectedCount,
  });

  final String name;
  final JsonFieldType type;
  final int? expectedCount;
}

final class JsonFormatContract {
  const JsonFormatContract({required this.fields});

  factory JsonFormatContract.demo() {
    return const JsonFormatContract(
      fields: <JsonFieldSpec>[
        JsonFieldSpec(name: 'title', type: JsonFieldType.string),
        JsonFieldSpec(name: 'summary', type: JsonFieldType.string),
        JsonFieldSpec(
          name: 'items',
          type: JsonFieldType.array,
          expectedCount: 3,
        ),
      ],
    );
  }

  final List<JsonFieldSpec> fields;

  String? validateContract() {
    if (fields.isEmpty) {
      return 'Добавьте хотя бы одно обязательное поле.';
    }
    final seen = <String>{};
    for (final field in fields) {
      final name = field.name.trim();
      if (name.isEmpty) {
        return 'Имя поля не должно быть пустым.';
      }
      if (!seen.add(name)) {
        return 'Поле "$name" указано дважды.';
      }
      if (field.expectedCount != null) {
        if (field.expectedCount! <= 0) {
          return 'Поле "$name": ожидаемое количество должно быть положительным.';
        }
        if (field.expectedCount! > maxSupportedCollectionCount) {
          return 'Поле "$name": количество не должно превышать '
              '$maxSupportedCollectionCount.';
        }
        if (field.type != JsonFieldType.array &&
            field.type != JsonFieldType.object) {
          return 'Поле "$name": количество проверяется только для array/object.';
        }
      }
    }
    return null;
  }

  String describe() {
    final parts = fields
        .map((field) {
          final base =
              '${field.name.trim()} (${jsonFieldTypeLabel(field.type)})';
          if (field.expectedCount != null) {
            return '$base, элементов: ${field.expectedCount}';
          }
          return base;
        })
        .join(', ');
    return 'JSON-объект с полями: $parts.';
  }

  /// Example matching the contract exactly: arrays carry exactly the
  /// required number of items and objects carry exactly the required
  /// number of properties. Counts above [maxSupportedCollectionCount] are
  /// rejected by [validateContract]; the defensive clamp below only guards
  /// direct calls with unvalidated contracts.
  String example() {
    final entries = <String, Object?>{};
    for (final field in fields) {
      entries[field.name.trim()] = _exampleDartValue(field);
    }
    return const JsonEncoder().convert(entries);
  }

  static Object? _exampleDartValue(JsonFieldSpec field) {
    final count = (field.expectedCount ?? 3).clamp(
      1,
      maxSupportedCollectionCount,
    );
    return switch (field.type) {
      JsonFieldType.string => 'пример',
      JsonFieldType.integer => 42,
      JsonFieldType.number => 4.2,
      JsonFieldType.boolean => true,
      JsonFieldType.array => List<String>.generate(
        count,
        (index) => 'элемент ${index + 1}',
      ),
      JsonFieldType.object => <String, String>{
        for (var i = 0; i < count; i++) 'ключ ${i + 1}': 'значение ${i + 1}',
      },
    };
  }
}

enum MarkdownListKind { unordered, ordered }

String markdownListKindLabel(MarkdownListKind kind) => switch (kind) {
  MarkdownListKind.unordered => 'маркированный',
  MarkdownListKind.ordered => 'нумерованный',
};

final class MarkdownFormatContract {
  const MarkdownFormatContract({
    required this.headings,
    required this.listKind,
    required this.expectedItems,
  });

  factory MarkdownFormatContract.demo() {
    return const MarkdownFormatContract(
      headings: <String>['Обзор', 'Выводы'],
      listKind: MarkdownListKind.unordered,
      expectedItems: 3,
    );
  }

  final List<String> headings;
  final MarkdownListKind listKind;
  final int expectedItems;

  String? validateContract() {
    if (headings.isEmpty) {
      return 'Добавьте хотя бы один заголовок.';
    }
    final seen = <String>{};
    for (final heading in headings) {
      final normalized = heading.trim();
      if (normalized.isEmpty) {
        return 'Заголовок не должен быть пустым.';
      }
      if (!seen.add(normalized)) {
        return 'Заголовок "$normalized" указан дважды.';
      }
    }
    if (expectedItems <= 0) {
      return 'Количество пунктов списка должно быть положительным.';
    }
    if (expectedItems > maxSupportedCollectionCount) {
      return 'Количество пунктов не должно превышать '
          '$maxSupportedCollectionCount.';
    }
    return null;
  }

  String describe() {
    final order = headings.map((h) => '"${h.trim()}"').join(' → ');
    return 'Заголовки по порядку: $order. '
        'Требуется ${markdownListKindLabel(listKind)} список '
        'из $expectedItems пунктов.';
  }
}

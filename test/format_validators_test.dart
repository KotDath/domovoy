import 'dart:convert';

import 'package:domovoy/features/lab/domain/format_contracts.dart';
import 'package:domovoy/features/lab/domain/format_validators.dart';
import 'package:domovoy/features/lab/domain/repair_input.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('format contracts', () {
    test('demo contracts are valid', () {
      expect(JsonFormatContract.demo().validateContract(), isNull);
      expect(MarkdownFormatContract.demo().validateContract(), isNull);
    });

    test('rejects empty and duplicated JSON contracts', () {
      expect(
        const JsonFormatContract(fields: []).validateContract(),
        isNotNull,
      );
      expect(
        const JsonFormatContract(
          fields: [
            JsonFieldSpec(name: 'a', type: JsonFieldType.string),
            JsonFieldSpec(name: 'a', type: JsonFieldType.string),
          ],
        ).validateContract(),
        isNotNull,
      );
    });

    test('rejects empty markdown contracts', () {
      expect(
        const MarkdownFormatContract(
          headings: [],
          listKind: MarkdownListKind.unordered,
          expectedItems: 3,
        ).validateContract(),
        isNotNull,
      );
    });

    test('rejects collection counts on scalar fields', () {
      expect(
        const JsonFormatContract(
          fields: [
            JsonFieldSpec(
              name: 'title',
              type: JsonFieldType.string,
              expectedCount: 2,
            ),
          ],
        ).validateContract(),
        isNotNull,
      );
      expect(
        const JsonFormatContract(
          fields: [
            JsonFieldSpec(
              name: 'tags',
              type: JsonFieldType.array,
              expectedCount: 2,
            ),
          ],
        ).validateContract(),
        isNull,
      );
    });

    test('generates parseable examples with escaped names', () {
      const contract = JsonFormatContract(
        fields: [
          JsonFieldSpec(name: 'ti"tle', type: JsonFieldType.string),
          JsonFieldSpec(
            name: 'items',
            type: JsonFieldType.array,
            expectedCount: 2,
          ),
        ],
      );
      expect(contract.validateContract(), isNull);
      final example = contract.example();
      final decoded = jsonDecode(example) as Map<String, dynamic>;
      expect(decoded['ti"tle'], 'пример');
      expect((decoded['items'] as List), hasLength(2));
      expect(validateJsonAnswer(example, contract).valid, isTrue);
    });

    test('rejects collection counts above the supported maximum', () {
      expect(
        const JsonFormatContract(
          fields: [
            JsonFieldSpec(
              name: 'items',
              type: JsonFieldType.array,
              expectedCount: maxSupportedCollectionCount + 1,
            ),
          ],
        ).validateContract(),
        isNotNull,
      );
      expect(
        const JsonFormatContract(
          fields: [
            JsonFieldSpec(
              name: 'items',
              type: JsonFieldType.array,
              expectedCount: maxSupportedCollectionCount,
            ),
          ],
        ).validateContract(),
        isNull,
      );
      expect(
        const MarkdownFormatContract(
          headings: ['Обзор'],
          listKind: MarkdownListKind.unordered,
          expectedItems: maxSupportedCollectionCount + 1,
        ).validateContract(),
        isNotNull,
      );
    });

    test('generates exactly the required number of object properties', () {
      const contract = JsonFormatContract(
        fields: [
          JsonFieldSpec(
            name: 'meta',
            type: JsonFieldType.object,
            expectedCount: 3,
          ),
          JsonFieldSpec(
            name: 'tags',
            type: JsonFieldType.array,
            expectedCount: 4,
          ),
        ],
      );
      expect(contract.validateContract(), isNull);
      final example = contract.example();
      final decoded = jsonDecode(example) as Map<String, dynamic>;
      expect((decoded['meta'] as Map), hasLength(3));
      expect((decoded['tags'] as List), hasLength(4));
      expect(validateJsonAnswer(example, contract).valid, isTrue);
    });
  });

  group('JSON validation', () {
    final contract = JsonFormatContract.demo();

    test('accepts a valid object', () {
      const answer =
          '{"title": "Дом", "summary": "Уют", "items": ["a", "b", "c"]}';
      final result = validateJsonAnswer(answer, contract);
      expect(result.valid, isTrue);
      expect(result.diagnostics, isEmpty);
    });

    test('rejects malformed, empty, and non-object answers', () {
      expect(validateJsonAnswer('', contract).valid, isFalse);
      expect(validateJsonAnswer('   ', contract).valid, isFalse);
      expect(validateJsonAnswer('{oops', contract).valid, isFalse);
      expect(validateJsonAnswer('["a"]', contract).valid, isFalse);
      expect(
        validateJsonAnswer('{"title": "x"} {"a": 1}', contract).valid,
        isFalse,
      );
    });

    test('reports missing keys, wrong types, and wrong counts', () {
      final missing = validateJsonAnswer('{"title": "x"}', contract);
      expect(missing.valid, isFalse);
      expect(missing.diagnostics.any((d) => d.contains('summary')), isTrue);

      const wrongType =
          '{"title": "x", "summary": "y", "items": ["a", "b", "c"], "extra": 1}';
      // Wrong type for an integer field.
      const typedContract = JsonFormatContract(
        fields: [JsonFieldSpec(name: 'count', type: JsonFieldType.integer)],
      );
      final badType = validateJsonAnswer('{"count": "many"}', typedContract);
      expect(badType.valid, isFalse);

      expect(wrongType, isNotNull);
      final wrongCount = validateJsonAnswer(
        '{"title": "x", "summary": "y", "items": ["a"]}',
        contract,
      );
      expect(wrongCount.valid, isFalse);
      expect(wrongCount.diagnostics.any((d) => d.contains('items')), isTrue);
    });

    test('rejects truncated output', () {
      final result = validateJsonAnswer(
        '{"title": "Дом", "summary": "Уют", "items": ["a", "b"',
        contract,
      );
      expect(result.valid, isFalse);
    });
  });

  group('Markdown validation', () {
    const contract = MarkdownFormatContract(
      headings: ['Обзор', 'Выводы'],
      listKind: MarkdownListKind.unordered,
      expectedItems: 2,
    );

    test('accepts headings in order with the right list', () {
      const answer = '# Обзор\n\n- один\n- два\n\n## Выводы\n\nТекст.';
      expect(validateMarkdownAnswer(answer, contract).valid, isTrue);
    });

    test('rejects wrong order and wrong counts', () {
      const swapped = '# Выводы\n\n- один\n- два\n\n# Обзор\n';
      final order = validateMarkdownAnswer(swapped, contract);
      expect(order.valid, isFalse);

      const short = '# Обзор\n\n- один\n\n## Выводы\n';
      final count = validateMarkdownAnswer(short, contract);
      expect(count.valid, isFalse);
      expect(count.diagnostics.any((d) => d.contains('Список')), isTrue);
    });

    test('does not treat arbitrary text as valid Markdown', () {
      expect(validateMarkdownAnswer('просто текст', contract).valid, isFalse);
      expect(validateMarkdownAnswer('', contract).valid, isFalse);
    });
  });

  group('repair input', () {
    test('contains task, contract, invalid answer, and diagnostics', () {
      final control = FormatControl(
        kind: ResponseFormatKind.json,
        contractText: 'JSON-объект с полями: title (string).',
        exampleText: '{"title": "пример"}',
      );
      final input = buildFormatRepairInput(
        originalTask: 'base task',
        control: control,
        invalidAnswer: '{"wrong": 1}',
        diagnostics: ['Отсутствует ключ "title".'],
      );

      expect(input.text, contains('base task'));
      expect(input.text, contains('title (string)'));
      expect(input.text, contains('{"wrong": 1}'));
      expect(input.text, contains('Отсутствует ключ'));
      expect(input.control, isA<FormatControl>());
      expect(input.thinking, ThinkingMode.enabled);
    });

    test('rejects empty original tasks', () {
      final control = FormatControl(
        kind: ResponseFormatKind.json,
        contractText: 'contract',
      );
      expect(
        () => buildFormatRepairInput(
          originalTask: '   ',
          control: control,
          invalidAnswer: 'x',
          diagnostics: const ['bad'],
        ),
        throwsArgumentError,
      );
    });
  });
}

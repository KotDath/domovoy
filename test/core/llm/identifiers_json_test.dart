import 'dart:io';

import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('identifiers', () {
    test('round-trip provider, model, call, wire family, and model ref', () {
      final provider = ProviderId('deepseek');
      final model = ModelId('deepseek-v4-flash');
      final call = ToolCallId('call_1');
      final ref = ModelRef(providerId: provider, modelId: model);
      const family = LlmWireFamily.openaiChatCompletions;

      expect(ProviderId.fromJson(provider.toJson()), provider);
      expect(ModelId.fromJson(model.toJson()), model);
      expect(ToolCallId.fromJson(call.toJson()), call);
      expect(ModelRef.fromJson(ref.toJson()), ref);
      expect(LlmWireFamily.fromJson(family.toJson()), family);
      expect(ref.toString(), 'deepseek/deepseek-v4-flash');
    });

    test('rejects blank identifiers', () {
      expect(
        () => ProviderId('  '),
        throwsA(
          isA<LlmException>().having(
            (error) => error.error.kind,
            'kind',
            LlmErrorKind.configuration,
          ),
        ),
      );
      expect(() => ModelId(''), throwsA(isA<LlmException>()));
      expect(() => ToolCallId('\n'), throwsA(isA<LlmException>()));
    });

    test('rejects non-integer JSON versions including 1.0', () {
      expect(
        () => ProviderId.fromJson(<String, Object?>{
          'type': ProviderId.jsonType,
          'version': 1.0,
          'value': 'deepseek',
        }),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => ProviderId.fromJson(<String, Object?>{
          'type': ProviderId.jsonType,
          'version': '1',
          'value': 'deepseek',
        }),
        throwsA(isA<LlmException>()),
      );
    });

    test('rejects malformed JSON values', () {
      expect(
        () => ProviderId.fromJson(<String, Object?>{'value': 'x'}),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => LlmWireFamily.fromJson(<String, Object?>{
          'type': LlmWireFamily.jsonType,
          'version': 1,
          'value': 'anthropic_messages',
        }),
        throwsA(isA<LlmException>()),
      );
      expect(() => deepFreezeJson(Object()), throwsA(isA<LlmException>()));
    });

    test('rejects NaN and infinity recursively', () {
      expect(
        () => deepCopyJson(<String, Object?>{'n': double.nan}),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => deepFreezeJson(<Object?>[double.infinity]),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => deepCopyJson(<String, Object?>{
          'nested': <String, Object?>{'x': double.negativeInfinity},
        }),
        throwsA(isA<LlmException>()),
      );
    });

    test('JSON object hash is insertion-order independent', () {
      final left = <String, Object?>{
        'a': 1,
        'b': <String, Object?>{'c': 2},
      };
      final right = <String, Object?>{
        'b': <String, Object?>{'c': 2},
        'a': 1,
      };
      expect(jsonEquals(left, right), isTrue);
      expect(jsonHash(left), jsonHash(right));
    });

    test('deep-frozen JSON copies nested maps and lists', () {
      final original = <String, Object?>{
        'nested': <String, Object?>{
          'list': <Object?>[
            1,
            <String, Object?>{'k': 'v'},
          ],
        },
      };
      final frozen = deepFreezeJson(original) as Map<String, Object?>;
      original['nested'] = 'mutated';
      expect(frozen['nested'], isA<Map<String, Object?>>());
      expect(() => frozen['x'] = 1, throwsUnsupportedError);
      final nested = frozen['nested'] as Map<String, Object?>;
      expect(() => nested['list'] = <Object?>[], throwsUnsupportedError);
      expect((nested['list'] as List<Object?>).first, 1);
    });
  });

  test(
    'core/llm does not import Flutter, http, dart:io, or secure storage',
    () {
      final directory = Directory('lib/core/llm');
      expect(directory.existsSync(), isTrue);
      for (final entity in directory.listSync()) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        for (final line in source.split('\n')) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('import ')) {
            continue;
          }
          expect(
            trimmed.contains('dart:io') ||
                trimmed.contains('package:flutter') ||
                trimmed.contains('package:http') ||
                trimmed.contains('flutter_secure_storage'),
            isFalse,
            reason: '${entity.path} imports $trimmed',
          );
        }
      }
    },
  );
}

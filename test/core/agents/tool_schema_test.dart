import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final complexSchema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'query': <String, Object?>{
        'type': 'string',
        'minLength': 2,
        'pattern': r'^[a-z]+$',
      },
      'mode': <String, Object?>{
        'type': 'string',
        'enum': <String>['fast', 'deep'],
      },
      'limit': <String, Object?>{
        'type': 'integer',
        'minimum': 1,
        'maximum': 30,
      },
      'tags': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{'type': 'string', 'format': 'uuid'},
        'minItems': 1,
        'maxItems': 3,
        'uniqueItems': true,
      },
      'when': <String, Object?>{'type': 'string', 'format': 'date-time'},
      'payload': <String, Object?>{
        'anyOf': <Object?>[
          <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'kind': <String, Object?>{'const': 'a'},
            },
            'required': <String>['kind'],
            'additionalProperties': false,
          },
          <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'kind': <String, Object?>{'const': 'b'},
            },
            'required': <String>['kind'],
            'additionalProperties': false,
          },
        ],
      },
    },
    'required': <String>['query', 'mode'],
    'additionalProperties': false,
  };

  group('tool schema representation', () {
    test('represents a complex schema without dropping constraints', () {
      final representation = representToolSchema(
        complexSchema,
        profile: ToolSchemaProfile.openaiChatCompletions,
      );
      expect(representation.isRepresented, isTrue);
      expect(representation.reason, isNull);
      expect(jsonEquals(representation.schema, complexSchema), isTrue);
    });

    test('projection is per provider profile', () {
      final narrow = ToolSchemaProfile(
        id: 'narrow-provider',
        keywords: const <String>{'type', 'properties', 'required'},
      );
      final representation = representToolSchema(
        complexSchema,
        profile: narrow,
      );
      expect(representation.isRepresented, isFalse);
      expect(representation.schema, isNull);
      expect(
        representation.reason,
        contains('unsupported JSON Schema keyword'),
      );
      expect(representation.reason, contains('narrow-provider'));

      final responses = representToolSchema(
        complexSchema,
        profile: ToolSchemaProfile.openaiResponses,
      );
      expect(responses.isRepresented, isTrue);
      expect(
        ToolSchemaProfile.forWireFamily(LlmWireFamily.openaiResponses).id,
        'openai.responses',
      );
    });

    test('fails closed on keywords this core cannot enforce', () {
      final unrepresentable = <Map<String, Object?>>[
        <String, Object?>{
          'type': 'object',
          r'$ref': r'#/$defs/x',
          r'$defs': <String, Object?>{},
        },
        <String, Object?>{
          'type': 'object',
          'items': <Object?>[
            <String, Object?>{'type': 'string'},
            <String, Object?>{'type': 'string'},
          ],
        },
        <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'when': <String, Object?>{'type': 'string', 'format': 'binary'},
          },
        },
        <String, Object?>{
          'type': 'object',
          'if': <String, Object?>{'type': 'object'},
          'then': <String, Object?>{'type': 'object'},
        },
        <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'name': <String, Object?>{'type': 'string', 'unknown': true},
          },
        },
      ];
      for (final schema in unrepresentable) {
        final representation = representToolSchema(
          schema,
          profile: ToolSchemaProfile.openaiChatCompletions,
        );
        expect(
          representation.isRepresented,
          isFalse,
          reason: schema.toString(),
        );
        expect(representation.reason, isNotEmpty);
      }
    });

    test('validates values against the full supported keyword set', () {
      expect(
        firstToolSchemaValueProblem(complexSchema, <String, Object?>{
          'query': 'papers',
          'mode': 'fast',
          'limit': 5,
          'tags': <String>['2f3c1d5e-6a7b-4c8d-9e0f-1a2b3c4d5e6f'],
          'when': '2025-01-03T12:00:00Z',
          'payload': <String, Object?>{'kind': 'a'},
        }),
        isNull,
      );

      final invalid = <Object?, String>{
        <String, Object?>{'query': 'xY', 'mode': 'fast'}: 'pattern',
        <String, Object?>{'query': 'papers', 'mode': 'slow'}: 'enum',
        <String, Object?>{'query': 'papers', 'mode': 'fast', 'limit': 99}:
            'maximum',
        <String, Object?>{
          'query': 'papers',
          'mode': 'fast',
          'tags': <String>[],
        }: 'fewer than 1 items',
        <String, Object?>{'query': 'papers', 'mode': 'fast', 'surprise': true}:
            'unexpected property',
        <String, Object?>{'mode': 'fast'}: 'required',
        <String, Object?>{
          'query': 'papers',
          'mode': 'fast',
          'payload': <String, Object?>{'kind': 'c'},
        }: 'any allowed variant',
        <String, Object?>{
          'query': 'papers',
          'mode': 'fast',
          'when': 'yesterday',
        }: 'date-time',
      };
      invalid.forEach((value, expected) {
        final problems = toolSchemaValueProblems(complexSchema, value);
        expect(
          problems.join(' | '),
          contains(expected),
          reason: value.toString(),
        );
      });
    });

    test('enforces oneOf, not, const, and type arrays', () {
      final schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'choice': <String, Object?>{
            'oneOf': <Object?>[
              <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'a': <String, Object?>{'const': 1},
                },
                'additionalProperties': false,
              },
              <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'b': <String, Object?>{'const': 2},
                },
                'additionalProperties': false,
              },
            ],
          },
          'optional': <String, Object?>{
            'type': <String>['string', 'null'],
          },
          'forbidden': <String, Object?>{
            'not': <String, Object?>{'type': 'string'},
          },
        },
      };
      expect(
        firstToolSchemaValueProblem(schema, <String, Object?>{
          'choice': <String, Object?>{'a': 1},
          'optional': null,
          'forbidden': 3,
        }),
        isNull,
      );
      expect(
        firstToolSchemaValueProblem(schema, <String, Object?>{
          'choice': <String, Object?>{'a': 1, 'b': 2},
        }),
        contains('exactly one'),
      );
      expect(
        firstToolSchemaValueProblem(schema, <String, Object?>{
          'forbidden': 'text',
        }),
        contains('forbidden'),
      );
      expect(
        firstToolSchemaValueProblem(schema, <String, Object?>{'optional': 5}),
        contains('string or null'),
      );
    });

    test('fails closed when an untrusted schema exceeds the work budget', () {
      final candidates = <Object?>[
        for (var variant = 0; variant < 999; variant += 1)
          <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'v$variant': <String, Object?>{'type': 'string'},
            },
            'required': <String>['v$variant'],
          },
        // The last variant matches, so each item is valid but expensive to
        // verify: the budget, not correctness, is what stops the work.
        <String, Object?>{'type': 'object'},
      ];
      final schema = <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{'anyOf': candidates},
      };
      final value = <Object?>[
        for (var item = 0; item < 400; item += 1) <String, Object?>{},
      ];
      final representation = representToolSchema(
        schema,
        profile: ToolSchemaProfile.openaiChatCompletions,
      );
      expect(representation.isRepresented, isTrue);
      // The bounded validator refuses once its budget is spent instead of
      // spinning on an untrusted catalog entry.
      expect(firstToolSchemaValueProblem(schema, value), contains('budget'));
    });

    test('unavailable patterns are reported instead of matched', () {
      final representation = representToolSchema(<String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'query': <String, Object?>{'type': 'string', 'pattern': r'(a+)+$'},
        },
      }, profile: ToolSchemaProfile.openaiChatCompletions);
      expect(representation.isRepresented, isFalse);
      expect(representation.reason, contains('bounded work'));
      expect(representation.reason, contains('grouping and alternation'));

      final patternProperties = representToolSchema(<String, Object?>{
        'type': 'object',
        'patternProperties': <String, Object?>{
          r'(a+)+$': <String, Object?>{'type': 'string'},
        },
      }, profile: ToolSchemaProfile.openaiChatCompletions);
      expect(patternProperties.isRepresented, isFalse);
      expect(patternProperties.reason, contains('bounded work'));

      // Defence in depth: even if an unsafe schema reaches validation, the
      // pattern is never executed.
      final problem = firstToolSchemaValueProblem(<String, Object?>{
        'type': 'string',
        'pattern': r'(a+)+$',
      }, 'aaaa');
      expect(problem, contains('safely'));
    });

    test('safe patterns still validate normally', () {
      expect(
        firstToolSchemaValueProblem(<String, Object?>{
          'type': 'string',
          'pattern': r'^[a-z]+$',
        }, 'papers'),
        isNull,
      );
      expect(
        firstToolSchemaValueProblem(<String, Object?>{
          'type': 'string',
          'pattern': r'^[a-z]+$',
        }, 'Papers1'),
        contains('pattern'),
      );
      expect(
        firstToolSchemaValueProblem(
          <String, Object?>{
            'type': 'object',
            'patternProperties': <String, Object?>{
              r'^[a-z]+$': <String, Object?>{'type': 'string'},
            },
          },
          <String, Object?>{'alpha': 'one'},
        ),
        isNull,
      );
    });

    test('uniqueItems is exact, fast and bounded', () {
      final schema = <String, Object?>{'type': 'array', 'uniqueItems': true};
      final unique = List<Object?>.generate(50000, (index) => index);
      final stopwatch = Stopwatch()..start();
      expect(firstToolSchemaValueProblem(schema, unique), isNull);
      stopwatch.stop();
      // The check must not be quadratic in the number of items: the pre-fix
      // pairwise comparison needs tens of seconds for this input.
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));

      expect(
        firstToolSchemaValueProblem(schema, <Object?>[1, 2, 1]),
        contains('repeat'),
      );
      expect(
        firstToolSchemaValueProblem(schema, <Object?>[1, 1.0]),
        contains('repeat'),
      );
      expect(
        firstToolSchemaValueProblem(schema, <Object?>[
          <String, Object?>{'a': 1},
          <String, Object?>{'a': 1},
        ]),
        contains('repeat'),
      );
      expect(
        firstToolSchemaValueProblem(schema, <Object?>['a', 'b', 'c']),
        isNull,
      );
      expect(
        firstToolSchemaValueProblem(
          schema,
          List<Object?>.generate(50001, (index) => index),
        ),
        contains('cannot be verified safely'),
      );
    });

    test('uniqueItems distinguishes 64-bit integers exactly', () {
      final schema = <String, Object?>{'type': 'array', 'uniqueItems': true};
      // Distinct VM JSON ints beyond 2^53 must not collapse through a double.
      expect(
        firstToolSchemaValueProblem(schema, <Object?>[
          9007199254740992,
          9007199254740993,
        ]),
        isNull,
      );
      expect(
        firstToolSchemaValueProblem(schema, <Object?>[
          -9007199254740993,
          -9007199254740992,
        ]),
        isNull,
      );
      // An integral double still equals the integer it represents.
      expect(
        firstToolSchemaValueProblem(schema, <Object?>[
          9007199254740992,
          9007199254740992.0,
        ]),
        contains('repeat'),
      );
      // The double literal rounds to 2^53, so it is genuinely distinct from
      // the odd integer; the keys must reflect Dart numeric equality.
      expect(
        firstToolSchemaValueProblem(schema, <Object?>[
          9007199254740993,
          9007199254740993.0,
        ]),
        isNull,
      );
    });

    test('uniqueItems fails visibly on deep or huge nested items', () {
      final schema = <String, Object?>{'type': 'array', 'uniqueItems': true};
      Object? nested(int levels) {
        Object? value = 'leaf';
        for (var level = 0; level < levels; level += 1) {
          value = <Object?>[value];
        }
        return value;
      }

      // Depth beyond the supported nesting budget fails visibly instead of
      // recursing into a stack overflow.
      expect(
        firstToolSchemaValueProblem(schema, <Object?>[nested(2000)]),
        contains('nested deeper'),
      );
      expect(
        firstToolSchemaValueProblem(schema, <Object?>[nested(2), nested(2)]),
        contains('repeat'),
      );

      // Work inside one item is charged to the shared budget: a huge nested
      // list cannot be serialized silently.
      final huge = <Object?>[
        <Object?>[for (var index = 0; index < 250000; index += 1) index],
      ];
      expect(
        firstToolSchemaValueProblem(schema, huge),
        contains('budget exceeded while serializing'),
      );
    });
  });
}

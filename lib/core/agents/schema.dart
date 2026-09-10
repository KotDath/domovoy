import 'dart:convert';

import '../llm/json.dart';
import 'errors.dart';

const supportedSchemaKeywords = <String>{
  'type',
  'properties',
  'required',
  'additionalProperties',
  'items',
  'enum',
  'description',
};

/// Validates the supported JSON-Schema subset used by agent tools.
///
/// Supported: object roots, `type`, `properties`, `required`, nested objects,
/// arrays/`items`, primitives, `enum`, and `additionalProperties`.
void validateToolSchema(Map<String, Object?> schema) {
  _validateSchema(schema, atRoot: true);
}

void validateArguments(Map<String, Object?> schema, Object? arguments) {
  _validateValue(schema, arguments, path: r'$');
}

Object? canonicalizeJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: canonicalizeJson(value[key]),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) canonicalizeJson(item)];
  }
  return value;
}

String canonicalJsonEncode(Object? value) =>
    jsonEncode(canonicalizeJson(value));

void _validateSchema(Map<String, Object?> schema, {required bool atRoot}) {
  for (final key in schema.keys) {
    if (!supportedSchemaKeywords.contains(key)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Unsupported JSON Schema keyword "$key".',
      );
    }
  }
  final type = schema['type'];
  if (type is! String) {
    throwAgent(
      AgentErrorKind.configuration,
      'Tool schema must declare a string type.',
    );
  }
  if (atRoot && type != 'object') {
    throwAgent(
      AgentErrorKind.configuration,
      'Tool schema root must be an object.',
    );
  }
  switch (type) {
    case 'object':
      final properties = schema['properties'];
      if (properties != null) {
        final map = asJsonObject(properties);
        if (map == null) {
          throwAgent(
            AgentErrorKind.configuration,
            'Schema properties must be an object.',
          );
        }
        for (final entry in map.entries) {
          final nested = asJsonObject(entry.value);
          if (nested == null) {
            throwAgent(
              AgentErrorKind.configuration,
              'Schema property "${entry.key}" must be an object.',
            );
          }
          _validateSchema(nested, atRoot: false);
        }
      }
      final required = schema['required'];
      if (required != null) {
        if (required is! List) {
          throwAgent(
            AgentErrorKind.configuration,
            'Schema required must be an array.',
          );
        }
        for (final item in required) {
          if (item is! String || item.isEmpty) {
            throwAgent(
              AgentErrorKind.configuration,
              'Schema required entries must be non-empty strings.',
            );
          }
        }
      }
      final additional = schema['additionalProperties'];
      if (additional != null &&
          additional is! bool &&
          asJsonObject(additional) == null) {
        throwAgent(
          AgentErrorKind.configuration,
          'additionalProperties must be a boolean or schema object.',
        );
      }
      if (asJsonObject(additional) != null) {
        _validateSchema(asJsonObject(additional)!, atRoot: false);
      }
      _validateEnum(schema['enum']);
    case 'array':
      final items = schema['items'];
      if (items != null) {
        final nested = asJsonObject(items);
        if (nested == null) {
          throwAgent(
            AgentErrorKind.configuration,
            'Schema items must be an object.',
          );
        }
        _validateSchema(nested, atRoot: false);
      }
      _validateEnum(schema['enum']);
    case 'string' || 'number' || 'integer' || 'boolean' || 'null':
      _validateEnum(schema['enum']);
    default:
      throwAgent(
        AgentErrorKind.configuration,
        'Unsupported schema type "$type".',
      );
  }
}

void _validateEnum(Object? enums) {
  if (enums == null) {
    return;
  }
  if (enums is! List) {
    throwAgent(AgentErrorKind.configuration, 'Schema enum must be an array.');
  }
  if (enums.isEmpty) {
    throwAgent(AgentErrorKind.configuration, 'Schema enum must not be empty.');
  }
  for (final value in enums) {
    if (value != null && value is! bool && value is! num && value is! String) {
      throwAgent(
        AgentErrorKind.configuration,
        'Schema enum values must be JSON primitives.',
      );
    }
  }
}

void _validateValue(
  Map<String, Object?> schema,
  Object? value, {
  required String path,
}) {
  final type = schema['type'];
  if (type is! String) {
    throwAgent(AgentErrorKind.configuration, 'Schema type missing at $path.');
  }
  final enums = schema['enum'];
  if (enums is List &&
      !enums.any((candidate) => jsonEquals(candidate, value))) {
    throwAgent(
      AgentErrorKind.configuration,
      'Value at $path is not one of the allowed enum values.',
    );
  }
  switch (type) {
    case 'object':
      final object = asJsonObject(value);
      if (object == null) {
        throwAgent(
          AgentErrorKind.configuration,
          'Expected an object at $path.',
        );
      }
      final properties =
          asJsonObject(schema['properties']) ?? const <String, Object?>{};
      final required = <String>[
        for (final item in (schema['required'] as List? ?? const <Object?>[]))
          item as String,
      ];
      for (final key in required) {
        if (!object.containsKey(key)) {
          throwAgent(
            AgentErrorKind.configuration,
            'Missing required property "$key" at $path.',
          );
        }
      }
      for (final entry in object.entries) {
        final propertySchema = asJsonObject(properties[entry.key]);
        if (propertySchema != null) {
          _validateValue(
            propertySchema,
            entry.value,
            path: '$path.${entry.key}',
          );
          continue;
        }
        final additional = schema['additionalProperties'];
        if (additional == false) {
          throwAgent(
            AgentErrorKind.configuration,
            'Unexpected property "${entry.key}" at $path.',
          );
        }
        final additionalSchema = asJsonObject(additional);
        if (additionalSchema != null) {
          _validateValue(
            additionalSchema,
            entry.value,
            path: '$path.${entry.key}',
          );
        }
      }
    case 'array':
      if (value is! List) {
        throwAgent(AgentErrorKind.configuration, 'Expected an array at $path.');
      }
      final items = asJsonObject(schema['items']);
      if (items != null) {
        for (var i = 0; i < value.length; i++) {
          _validateValue(items, value[i], path: '$path[$i]');
        }
      }
    case 'string':
      if (value is! String) {
        throwAgent(AgentErrorKind.configuration, 'Expected a string at $path.');
      }
    case 'number':
      if (value is! num) {
        throwAgent(AgentErrorKind.configuration, 'Expected a number at $path.');
      }
    case 'integer':
      if (value is! int) {
        throwAgent(
          AgentErrorKind.configuration,
          'Expected an integer at $path.',
        );
      }
    case 'boolean':
      if (value is! bool) {
        throwAgent(
          AgentErrorKind.configuration,
          'Expected a boolean at $path.',
        );
      }
    case 'null':
      if (value != null) {
        throwAgent(AgentErrorKind.configuration, 'Expected null at $path.');
      }
  }
}

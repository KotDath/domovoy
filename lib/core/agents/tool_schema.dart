import '../llm/identifiers.dart';
import '../llm/json.dart';

/// JSON Schema keywords this core can enforce when validating MCP arguments
/// and results.
///
/// A tool is only advertised to a provider when every keyword in its schema is
/// in the profile of that provider, so the adapter never has to drop, weaken
/// or silently ignore a constraint. Anything outside this set fails closed:
/// the tool stays visible with an explicit reason and its calls are rejected.
const toolSchemaKeywords = <String>{
  // Annotations: carried to the provider unchanged, never a constraint.
  r'$comment',
  'title',
  'description',
  'default',
  'deprecated',
  'examples',
  'readOnly',
  'writeOnly',
  // Structure.
  'type',
  'properties',
  'required',
  'additionalProperties',
  'patternProperties',
  'minProperties',
  'maxProperties',
  'items',
  'minItems',
  'maxItems',
  'uniqueItems',
  'enum',
  'const',
  'anyOf',
  'oneOf',
  'allOf',
  'not',
  // Numbers.
  'minimum',
  'maximum',
  'exclusiveMinimum',
  'exclusiveMaximum',
  'multipleOf',
  // Strings.
  'minLength',
  'maxLength',
  'pattern',
  'format',
};

/// `format` values this core validates instead of forwarding blindly.
///
/// Unknown formats make a schema unrepresentable: a format is a declared
/// constraint, and accepting it without enforcing it would broaden the tool.
const toolSchemaFormats = <String>{
  'date-time',
  'date',
  'time',
  'email',
  'hostname',
  'ipv4',
  'ipv6',
  'uri',
  'uri-reference',
  'uuid',
  'regex',
};

const _maximumSchemaDepth = 32;

/// Capability boundary of one LLM wire family.
///
/// [keywords] is exactly the set of JSON Schema keywords whose constraints are
/// preserved end to end: they are sent to the provider unchanged *and* enforced
/// locally during argument validation. A profile never extends what the local
/// validator understands, so a represented schema is always enforceable.
final class ToolSchemaProfile {
  ToolSchemaProfile({
    required String id,
    required Set<String> keywords,
    Set<String> formats = toolSchemaFormats,
    this.maxToolNameLength = 64,
  }) : id = id.trim(),
       keywords = Set<String>.unmodifiable(keywords),
       formats = Set<String>.unmodifiable(formats) {
    if (this.id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'Profile id must not be blank.');
    }
    if (maxToolNameLength <= 0) {
      throw ArgumentError.value(
        maxToolNameLength,
        'maxToolNameLength',
        'Name budget must be positive.',
      );
    }
  }

  /// Stable, human-readable identity used in unavailability reasons.
  final String id;

  /// JSON Schema keywords the provider can carry without losing meaning.
  final Set<String> keywords;

  /// `format` values the provider and the local validator both enforce.
  final Set<String> formats;

  /// Maximum model-facing tool name length accepted by the wire protocol.
  final int maxToolNameLength;

  /// OpenAI-compatible `/chat/completions` function tools.
  ///
  /// The wire format carries a raw JSON Schema in `function.parameters`; the
  /// profile therefore accepts every keyword the local validator enforces.
  static final ToolSchemaProfile openaiChatCompletions = ToolSchemaProfile(
    id: 'openai.chat_completions',
    keywords: toolSchemaKeywords,
  );

  /// OpenAI Responses API function tools.
  ///
  /// Responses also carry a raw JSON Schema in the `parameters` field, so the
  /// accepted set matches chat completions. The profile exists separately so a
  /// future provider restriction (for example strict structured outputs) is
  /// declared here instead of being hidden in the adapter.
  static final ToolSchemaProfile openaiResponses = ToolSchemaProfile(
    id: 'openai.responses',
    keywords: toolSchemaKeywords,
  );

  /// Least surprised profile for unknown wire families.
  static final ToolSchemaProfile portable = ToolSchemaProfile(
    id: 'portable',
    keywords: toolSchemaKeywords,
  );

  static ToolSchemaProfile forWireFamily(LlmWireFamily family) {
    return switch (family) {
      LlmWireFamily.openaiChatCompletions => openaiChatCompletions,
      LlmWireFamily.openaiResponses => openaiResponses,
      LlmWireFamily.anthropicMessages ||
      LlmWireFamily.geminiGenerateContent => portable,
    };
  }
}

/// Outcome of projecting one tool schema for a specific provider.
sealed class ToolSchemaRepresentation {
  const ToolSchemaRepresentation();

  bool get isRepresented;

  /// The exact schema to advertise; only set when represented.
  Map<String, Object?>? get schema;

  /// Provider-facing explanation; only set when not represented.
  String? get reason;
}

final class RepresentedToolSchema extends ToolSchemaRepresentation {
  RepresentedToolSchema(Object? schema)
    : schema = freezeJsonMap(asJsonObject(schema)!);

  @override
  final Map<String, Object?> schema;

  @override
  bool get isRepresented => true;

  @override
  String? get reason => null;
}

final class UnrepresentedToolSchema extends ToolSchemaRepresentation {
  const UnrepresentedToolSchema(this.reason);

  @override
  bool get isRepresented => false;

  @override
  Map<String, Object?>? get schema => null;

  @override
  final String reason;
}

/// Projects [schema] for [profile] without changing a single constraint.
///
/// Returns [RepresentedToolSchema] carrying a deep copy of the original schema
/// when the profile can express it and the local validator can enforce it;
/// otherwise returns [UnrepresentedToolSchema] with a reason fit for a trace.
ToolSchemaRepresentation representToolSchema(
  Map<String, Object?> schema, {
  required ToolSchemaProfile profile,
}) {
  final problem = toolSchemaProblem(schema, profile: profile);
  if (problem != null) {
    return UnrepresentedToolSchema(
      'JSON Schema for this tool cannot be represented faithfully for '
      'provider "${profile.id}": $problem',
    );
  }
  return RepresentedToolSchema(schema);
}

/// Structural check: why [schema] cannot be represented for [profile].
///
/// `null` means every keyword is understood, every nested value has a valid
/// shape, and the local validator can enforce all declared constraints.
String? toolSchemaProblem(
  Map<String, Object?> schema, {
  required ToolSchemaProfile profile,
}) => _schemaProblem(schema, profile, depth: 0, path: r'$');

/// Validates [value] against [schema] with the full supported keyword set.
///
/// The schema must have passed [toolSchemaProblem] for a profile first; an
/// unexpected keyword is reported as a problem instead of being ignored, so a
/// value can never be accepted by a broadened contract.
List<String> toolSchemaValueProblems(
  Map<String, Object?> schema,
  Object? value, {
  int maxProblems = 16,
}) {
  final problems = <String>[];
  _collectValueProblems(
    schema,
    value,
    path: r'$',
    problems: problems,
    maxProblems: maxProblems,
    depth: 0,
    budget: _ValidationBudget(),
  );
  return List<String>.unmodifiable(problems);
}

/// First problem [value] has against [schema], or `null` when it fits.
String? firstToolSchemaValueProblem(
  Map<String, Object?> schema,
  Object? value,
) {
  final problems = toolSchemaValueProblems(schema, value, maxProblems: 1);
  return problems.isEmpty ? null : problems.first;
}

String? _schemaProblem(
  Map<String, Object?> schema,
  ToolSchemaProfile profile, {
  required int depth,
  required String path,
}) {
  if (depth > _maximumSchemaDepth) {
    return 'schema at $path exceeds the supported nesting depth.';
  }
  for (final key in schema.keys) {
    if (!profile.keywords.contains(key)) {
      return 'unsupported JSON Schema keyword "$key" at $path.';
    }
  }
  final type = schema['type'];
  if (type != null) {
    final typeProblem = _typeProblem(type, path);
    if (typeProblem != null) {
      return typeProblem;
    }
  }
  final properties = schema['properties'];
  if (properties != null) {
    final map = asJsonObject(properties);
    if (map == null) {
      return 'properties at $path must be an object.';
    }
    for (final entry in map.entries) {
      final nested = asJsonObject(entry.value);
      if (nested == null) {
        return 'property "${entry.key}" at $path must be a schema object.';
      }
      final problem = _schemaProblem(
        nested,
        profile,
        depth: depth + 1,
        path: '$path.${entry.key}',
      );
      if (problem != null) {
        return problem;
      }
    }
  }
  final patternProperties = schema['patternProperties'];
  if (patternProperties != null) {
    final map = asJsonObject(patternProperties);
    if (map == null) {
      return 'patternProperties at $path must be an object.';
    }
    for (final entry in map.entries) {
      if (!_isValidPattern(entry.key)) {
        return 'patternProperties key "${entry.key}" is not a valid regex.';
      }
      final nested = asJsonObject(entry.value);
      if (nested == null) {
        return 'patternProperties value must be a schema object.';
      }
      final problem = _schemaProblem(
        nested,
        profile,
        depth: depth + 1,
        path: '$path.${entry.key}',
      );
      if (problem != null) {
        return problem;
      }
    }
  }
  final required = schema['required'];
  if (required != null) {
    if (required is! List) {
      return 'required at $path must be an array.';
    }
    for (final item in required) {
      if (item is! String || item.isEmpty) {
        return 'required entries at $path must be non-empty strings.';
      }
    }
  }
  final additional = schema['additionalProperties'];
  if (additional != null) {
    if (additional is! bool) {
      final nested = asJsonObject(additional);
      if (nested == null) {
        return 'additionalProperties at $path must be a boolean or schema.';
      }
      final problem = _schemaProblem(
        nested,
        profile,
        depth: depth + 1,
        path: '$path.additionalProperties',
      );
      if (problem != null) {
        return problem;
      }
    }
  }
  final items = schema['items'];
  if (items != null) {
    final nested = asJsonObject(items);
    if (nested == null) {
      return 'items at $path must be a single schema, not a tuple array.';
    }
    final problem = _schemaProblem(
      nested,
      profile,
      depth: depth + 1,
      path: '$path.items',
    );
    if (problem != null) {
      return problem;
    }
  }
  for (final key in const <String>['anyOf', 'oneOf', 'allOf']) {
    final combinations = schema[key];
    if (combinations == null) {
      continue;
    }
    if (combinations is! List || combinations.isEmpty) {
      return '$key at $path must be a non-empty array of schemas.';
    }
    for (var index = 0; index < combinations.length; index++) {
      final nested = asJsonObject(combinations[index]);
      if (nested == null) {
        return '$key[$index] at $path must be a schema object.';
      }
      final problem = _schemaProblem(
        nested,
        profile,
        depth: depth + 1,
        path: '$path.$key[$index]',
      );
      if (problem != null) {
        return problem;
      }
    }
  }
  final negated = schema['not'];
  if (negated != null) {
    final nested = asJsonObject(negated);
    if (nested == null) {
      return 'not at $path must be a schema object.';
    }
    final problem = _schemaProblem(
      nested,
      profile,
      depth: depth + 1,
      path: '$path.not',
    );
    if (problem != null) {
      return problem;
    }
  }
  final enumValues = schema['enum'];
  if (enumValues != null) {
    if (enumValues is! List || enumValues.isEmpty) {
      return 'enum at $path must be a non-empty array.';
    }
  }
  for (final key in const <String>[
    'minimum',
    'maximum',
    'exclusiveMinimum',
    'exclusiveMaximum',
    'multipleOf',
  ]) {
    final value = schema[key];
    if (value == null) {
      continue;
    }
    if (value is! num || !_isFinite(value)) {
      return '$key at $path must be a finite number.';
    }
    if (key == 'multipleOf' && value <= 0) {
      return 'multipleOf at $path must be positive.';
    }
  }
  for (final key in const <String>[
    'minLength',
    'maxLength',
    'minItems',
    'maxItems',
    'minProperties',
    'maxProperties',
  ]) {
    final value = schema[key];
    if (value == null) {
      continue;
    }
    if (value is! int || value < 0) {
      return '$key at $path must be a non-negative integer.';
    }
  }
  final unique = schema['uniqueItems'];
  if (unique != null && unique is! bool) {
    return 'uniqueItems at $path must be a boolean.';
  }
  final pattern = schema['pattern'];
  if (pattern != null) {
    if (pattern is! String || !_isValidPattern(pattern)) {
      return 'pattern at $path is not a valid regex.';
    }
  }
  final format = schema['format'];
  if (format != null) {
    if (format is! String || !profile.formats.contains(format)) {
      return 'format "$format" at $path is not enforced by the provider '
          'profile.';
    }
  }
  return null;
}

String? _typeProblem(Object? type, String path) {
  if (type is String) {
    return _isPrimitiveType(type)
        ? null
        : 'type "$type" at $path is not a JSON Schema primitive.';
  }
  if (type is List) {
    if (type.isEmpty) {
      return 'type array at $path must not be empty.';
    }
    for (final item in type) {
      if (item is! String || !_isPrimitiveType(item)) {
        return 'type array at $path must contain JSON Schema primitives.';
      }
    }
    return null;
  }
  return 'type at $path must be a string or an array of strings.';
}

bool _isPrimitiveType(String value) => const <String>{
  'object',
  'array',
  'string',
  'number',
  'integer',
  'boolean',
  'null',
}.contains(value);

void _collectValueProblems(
  Map<String, Object?> schema,
  Object? value, {
  required String path,
  required List<String> problems,
  required int maxProblems,
  required int depth,
  required _ValidationBudget budget,
}) {
  if (problems.length >= maxProblems) {
    return;
  }
  budget.step();
  if (budget.exhausted) {
    problems.add('schema validation budget exceeded at $path.');
    return;
  }
  if (depth > _maximumSchemaDepth) {
    problems.add('value at $path exceeds the supported nesting depth.');
    return;
  }
  for (final key in schema.keys) {
    if (!toolSchemaKeywords.contains(key)) {
      problems.add('schema keyword "$key" at $path is not supported.');
      return;
    }
  }
  final constValue = schema['const'];
  if (schema.containsKey('const') && !jsonEquals(constValue, value)) {
    problems.add('value at $path does not match the declared constant.');
    return;
  }
  final enumValues = schema['enum'];
  if (enumValues is List &&
      !enumValues.any((candidate) => jsonEquals(candidate, value))) {
    problems.add('value at $path is not one of the allowed enum values.');
    return;
  }
  final type = schema['type'];
  if (type != null && !_matchesType(type, value)) {
    problems.add('expected ${_describeType(type)} at $path.');
    return;
  }
  if (value is Map) {
    _collectObjectProblems(
      schema,
      value,
      path: path,
      problems: problems,
      maxProblems: maxProblems,
      depth: depth,
      budget: budget,
    );
  } else if (value is List) {
    _collectArrayProblems(
      schema,
      value,
      path: path,
      problems: problems,
      maxProblems: maxProblems,
      depth: depth,
      budget: budget,
    );
  } else if (value is String) {
    _collectStringProblems(schema, value, path: path, problems: problems);
  } else if (value is num) {
    _collectNumberProblems(schema, value, path: path, problems: problems);
  }
  _collectCombinationProblems(
    schema,
    value,
    path: path,
    problems: problems,
    maxProblems: maxProblems,
    depth: depth,
    budget: budget,
  );
}

void _collectObjectProblems(
  Map<String, Object?> schema,
  Map<Object?, Object?> value, {
  required String path,
  required List<String> problems,
  required int maxProblems,
  required int depth,
  required _ValidationBudget budget,
}) {
  final required = schema['required'];
  if (required is List) {
    for (final key in required) {
      if (key is String && !value.containsKey(key)) {
        problems.add('missing required property "$key" at $path.');
        if (problems.length >= maxProblems) {
          return;
        }
      }
    }
  }
  final minimum = schema['minProperties'];
  if (minimum is int && value.length < minimum) {
    problems.add('object at $path has fewer than $minimum properties.');
    return;
  }
  final maximum = schema['maxProperties'];
  if (maximum is int && value.length > maximum) {
    problems.add('object at $path has more than $maximum properties.');
    return;
  }
  final properties = asJsonObject(schema['properties']);
  final patternProperties = asJsonObject(schema['patternProperties']);
  final additional = schema['additionalProperties'];
  for (final entry in value.entries) {
    if (problems.length >= maxProblems) {
      return;
    }
    final name = entry.key.toString();
    var matched = false;
    final declared = properties?[name];
    if (declared != null) {
      matched = true;
      final nested = asJsonObject(declared);
      if (nested != null) {
        _collectValueProblems(
          nested,
          entry.value,
          path: '$path.$name',
          problems: problems,
          maxProblems: maxProblems,
          depth: depth + 1,
          budget: budget,
        );
      }
    }
    if (patternProperties != null) {
      for (final pattern in patternProperties.entries) {
        if (RegExp(pattern.key).hasMatch(name)) {
          matched = true;
          final nested = asJsonObject(pattern.value);
          if (nested != null) {
            _collectValueProblems(
              nested,
              entry.value,
              path: '$path.$name',
              problems: problems,
              maxProblems: maxProblems,
              depth: depth + 1,
              budget: budget,
            );
          }
        }
      }
    }
    if (matched || additional == null) {
      continue;
    }
    if (additional == false) {
      problems.add('unexpected property "$name" at $path.');
      continue;
    }
    final nested = asJsonObject(additional);
    if (nested != null) {
      _collectValueProblems(
        nested,
        entry.value,
        path: '$path.$name',
        problems: problems,
        maxProblems: maxProblems,
        depth: depth + 1,
        budget: budget,
      );
    }
  }
}

void _collectArrayProblems(
  Map<String, Object?> schema,
  List<Object?> value, {
  required String path,
  required List<String> problems,
  required int maxProblems,
  required int depth,
  required _ValidationBudget budget,
}) {
  final minimum = schema['minItems'];
  if (minimum is int && value.length < minimum) {
    problems.add('array at $path has fewer than $minimum items.');
    return;
  }
  final maximum = schema['maxItems'];
  if (maximum is int && value.length > maximum) {
    problems.add('array at $path has more than $maximum items.');
    return;
  }
  if (schema['uniqueItems'] == true) {
    for (var i = 0; i < value.length; i++) {
      for (var j = i + 1; j < value.length; j++) {
        if (jsonEquals(value[i], value[j])) {
          problems.add('array at $path must not repeat items.');
          return;
        }
      }
    }
  }
  final items = asJsonObject(schema['items']);
  if (items != null) {
    for (var index = 0; index < value.length; index++) {
      if (problems.length >= maxProblems) {
        return;
      }
      _collectValueProblems(
        items,
        value[index],
        path: '$path[$index]',
        problems: problems,
        maxProblems: maxProblems,
        depth: depth + 1,
        budget: budget,
      );
    }
  }
}

void _collectStringProblems(
  Map<String, Object?> schema,
  String value, {
  required String path,
  required List<String> problems,
}) {
  final minimum = schema['minLength'];
  if (minimum is int && value.length < minimum) {
    problems.add('string at $path is shorter than $minimum characters.');
    return;
  }
  final maximum = schema['maxLength'];
  if (maximum is int && value.length > maximum) {
    problems.add('string at $path is longer than $maximum characters.');
    return;
  }
  final pattern = schema['pattern'];
  if (pattern is String && !RegExp(pattern).hasMatch(value)) {
    problems.add('string at $path does not match the required pattern.');
    return;
  }
  final format = schema['format'];
  if (format is String && !_matchesFormat(format, value)) {
    problems.add('string at $path is not a valid "$format".');
  }
}

void _collectNumberProblems(
  Map<String, Object?> schema,
  num value, {
  required String path,
  required List<String> problems,
}) {
  final minimum = schema['minimum'];
  if (minimum is num && value < minimum) {
    problems.add('number at $path is below the allowed minimum.');
    return;
  }
  final maximum = schema['maximum'];
  if (maximum is num && value > maximum) {
    problems.add('number at $path is above the allowed maximum.');
    return;
  }
  final exclusiveMinimum = schema['exclusiveMinimum'];
  if (exclusiveMinimum is num && value <= exclusiveMinimum) {
    problems.add('number at $path must be greater than $exclusiveMinimum.');
    return;
  }
  final exclusiveMaximum = schema['exclusiveMaximum'];
  if (exclusiveMaximum is num && value >= exclusiveMaximum) {
    problems.add('number at $path must be less than $exclusiveMaximum.');
    return;
  }
  final multipleOf = schema['multipleOf'];
  if (multipleOf is num && multipleOf > 0) {
    final quotient = value / multipleOf;
    if ((quotient - quotient.roundToDouble()).abs() > 1e-9) {
      problems.add('number at $path must be a multiple of $multipleOf.');
    }
  }
}

void _collectCombinationProblems(
  Map<String, Object?> schema,
  Object? value, {
  required String path,
  required List<String> problems,
  required int maxProblems,
  required int depth,
  required _ValidationBudget budget,
}) {
  final allOf = schema['allOf'];
  if (allOf is List) {
    for (final candidate in allOf) {
      final nested = asJsonObject(candidate);
      if (nested != null) {
        _collectValueProblems(
          nested,
          value,
          path: path,
          problems: problems,
          maxProblems: maxProblems,
          depth: depth + 1,
          budget: budget,
        );
        if (problems.length >= maxProblems || budget.exhausted) {
          return;
        }
      }
    }
  }
  final anyOf = schema['anyOf'];
  if (anyOf is List) {
    var matched = false;
    for (final candidate in anyOf) {
      if (_accepts(
        candidate,
        value,
        path: path,
        depth: depth,
        budget: budget,
        problems: problems,
      )) {
        matched = true;
        break;
      }
      if (budget.exhausted || problems.isNotEmpty) {
        return;
      }
    }
    if (!matched) {
      problems.add('value at $path does not match any allowed variant.');
      return;
    }
  }
  final oneOf = schema['oneOf'];
  if (oneOf is List) {
    var matches = 0;
    for (final candidate in oneOf) {
      if (_accepts(
        candidate,
        value,
        path: path,
        depth: depth,
        budget: budget,
        problems: problems,
      )) {
        matches += 1;
      }
      if (budget.exhausted || problems.isNotEmpty) {
        return;
      }
    }
    if (matches != 1) {
      problems.add('value at $path must match exactly one allowed variant.');
      return;
    }
  }
  final negated = asJsonObject(schema['not']);
  if (negated != null &&
      _accepts(
        negated,
        value,
        path: path,
        depth: depth,
        budget: budget,
        problems: problems,
      )) {
    problems.add('value at $path matches a forbidden variant.');
  }
}

bool _accepts(
  Object? candidate,
  Object? value, {
  required String path,
  required int depth,
  required _ValidationBudget budget,
  required List<String> problems,
}) {
  if (depth > _maximumSchemaDepth || budget.exhausted) {
    if (budget.exhausted) {
      problems.add('schema validation budget exceeded at $path.');
    }
    return false;
  }
  final schema = asJsonObject(candidate);
  if (schema == null) {
    return false;
  }
  final nested = <String>[];
  _collectValueProblems(
    schema,
    value,
    path: path,
    problems: nested,
    maxProblems: 1,
    depth: depth + 1,
    budget: budget,
  );
  if (budget.exhausted) {
    // The variant work was cut short, so the result cannot be trusted as a
    // clean match: surface it and fail the whole validation closed.
    problems.add('schema validation budget exceeded at $path.');
    return false;
  }
  return nested.isEmpty;
}

/// Bounds the total work one value validation may perform.
///
/// MCP schemas are untrusted input: without a budget a server could publish a
/// combinator-heavy schema whose validation costs exponential time. Exceeding
/// the budget is reported as a problem, so the call fails closed.
final class _ValidationBudget {
  _ValidationBudget();

  static const _maxSteps = 200000;
  var _steps = 0;

  bool get exhausted => _steps > _maxSteps;

  void step() => _steps += 1;
}

bool _matchesType(Object? type, Object? value) {
  if (type is String) {
    return _matchesSingleType(type, value);
  }
  if (type is List) {
    return type.any(
      (candidate) =>
          candidate is String && _matchesSingleType(candidate, value),
    );
  }
  return true;
}

bool _matchesSingleType(String type, Object? value) {
  switch (type) {
    case 'object':
      return value is Map;
    case 'array':
      return value is List;
    case 'string':
      return value is String;
    case 'number':
      return value is num;
    case 'integer':
      return value is int ||
          (value is double && value == value.truncateToDouble());
    case 'boolean':
      return value is bool;
    case 'null':
      return value == null;
    default:
      return false;
  }
}

String _describeType(Object? type) {
  if (type is String) {
    return type;
  }
  if (type is List) {
    return type.map((item) => item.toString()).join(' or ');
  }
  return 'a supported value';
}

bool _isValidPattern(String pattern) {
  try {
    RegExp(pattern);
    return true;
  } on FormatException {
    return false;
  }
}

bool _isFinite(num value) =>
    value is int || (!value.isNaN && !value.isInfinite);

bool _matchesFormat(String format, String value) => switch (format) {
  'date-time' =>
    _dateTimePattern.hasMatch(value) && DateTime.tryParse(value) != null,
  'date' => _datePattern.hasMatch(value) && DateTime.tryParse(value) != null,
  'time' => _timePattern.hasMatch(value),
  'email' => _emailPattern.hasMatch(value),
  'hostname' =>
    value.isNotEmpty && value.length <= 253 && _hostnamePattern.hasMatch(value),
  'ipv4' =>
    _ipv4Pattern.hasMatch(value) &&
        value.split('.').every((octet) => int.parse(octet) <= 255),
  'ipv6' => _ipv6Pattern.hasMatch(value),
  'uri' => _isUri(value),
  'uri-reference' => Uri.tryParse(value) != null,
  'uuid' => _uuidPattern.hasMatch(value),
  'regex' => _isValidPattern(value),
  _ => false,
};

bool _isUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme.isEmpty) {
    return false;
  }
  return RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*$').hasMatch(uri.scheme);
}

final _dateTimePattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
);
final _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _timePattern = RegExp(r'^\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$');
final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _hostnamePattern = RegExp(
  r'^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*'
  r'[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
);
final _ipv4Pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final _ipv6Pattern = RegExp(
  r'^('
  r'([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|'
  r'([0-9A-Fa-f]{1,4}:){1,7}:|'
  r'([0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|'
  r'([0-9A-Fa-f]{1,4}:){1,5}(:[0-9A-Fa-f]{1,4}){1,2}|'
  r'([0-9A-Fa-f]{1,4}:){1,4}(:[0-9A-Fa-f]{1,4}){1,3}|'
  r'([0-9A-Fa-f]{1,4}:){1,3}(:[0-9A-Fa-f]{1,4}){1,4}|'
  r'([0-9A-Fa-f]{1,4}:){1,2}(:[0-9A-Fa-f]{1,4}){1,5}|'
  r'[0-9A-Fa-f]{1,4}:((:[0-9A-Fa-f]{1,4}){1,6})|'
  r':((:[0-9A-Fa-f]{1,4}){1,7}|:)|'
  r'fe80:(:[0-9A-Fa-f]{0,4}){0,4}%[0-9A-Za-z]+|'
  r'::(ffff(:0{1,4}){0,1}:){0,1}'
  r'((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3}'
  r'(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|'
  r'([0-9A-Fa-f]{1,4}:){1,4}:'
  r'((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3}'
  r'(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])'
  r')$',
);
final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

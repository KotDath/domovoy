import 'errors.dart';
import 'json.dart';

final class LlmToolDescriptor {
  LlmToolDescriptor({
    required String name,
    String? description,
    Map<String, Object?>? parameters,
  }) : name = name.trim(),
       description = description?.trim(),
       parameters = freezeJsonMap(
         parameters == null
             ? const <String, Object?>{
                 'type': 'object',
                 'properties': <String, Object?>{},
               }
             : copyJsonMap(parameters),
       ) {
    if (this.name.isEmpty) {
      throwLlm(LlmErrorKind.configuration, 'Tool name must not be blank.');
    }
    if (this.description != null && this.description!.isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Tool description must not be blank when provided.',
      );
    }
  }

  factory LlmToolDescriptor.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmToolDescriptor(
      name: requireString(map, 'name'),
      description: optionalString(map, 'description'),
      parameters: optionalJsonMap(map, 'parameters'),
    );
  }

  static const jsonType = 'llm.tool_descriptor';

  final String name;
  final String? description;
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{
      'name': name,
      'parameters': deepCopyJson(parameters),
    };
    if (description != null) {
      fields['description'] = description;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmToolDescriptor &&
          other.name == name &&
          other.description == description &&
          jsonEquals(other.parameters, parameters);

  @override
  int get hashCode => Object.hash(name, description, jsonHash(parameters));
}

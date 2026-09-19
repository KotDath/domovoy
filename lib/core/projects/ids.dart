import '../llm/errors.dart';
import '../llm/json.dart';

final class ProjectId {
  ProjectId(String value) : value = _validate(value, 'Project id');

  factory ProjectId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ProjectId(requireString(map, 'value'));
  }

  static const jsonType = 'project.id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProjectId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ProjectRootId {
  ProjectRootId(String value) : value = _validate(value, 'Project root id');

  factory ProjectRootId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ProjectRootId(requireString(map, 'value'));
  }

  static const jsonType = 'project.root_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProjectRootId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class DirectoryGrantId {
  DirectoryGrantId(String value)
    : value = _validate(value, 'Directory grant id');

  factory DirectoryGrantId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return DirectoryGrantId(requireString(map, 'value'));
  }

  static const jsonType = 'project.directory_grant_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DirectoryGrantId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class ProjectDeletionOperationId {
  ProjectDeletionOperationId(String value)
    : value = _validate(value, 'Project deletion operation id');

  factory ProjectDeletionOperationId.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return ProjectDeletionOperationId(requireString(map, 'value'));
  }

  static const jsonType = 'project.deletion_operation_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectDeletionOperationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

String _validate(String value, String label) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throwLlm(LlmErrorKind.configuration, '$label must not be blank.');
  }
  return normalized;
}

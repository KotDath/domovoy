import '../llm/errors.dart';
import '../llm/json.dart';

enum ProjectErrorKind {
  configuration,
  persistence,
  conflict,
  cancelled,
  unsupported,
  collision,
  accessUnavailable,
  unverifiable,
  denied,
}

final class ProjectError implements Exception {
  ProjectError({required this.kind, required String message})
    : message = message.trim() {
    if (this.message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'Error message must not be blank.',
      );
    }
  }

  factory ProjectError.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final kindName = requireNonBlankString(map, 'kind');
    final kind = ProjectErrorKind.values
        .where((value) => value.name == kindName)
        .firstOrNull;
    if (kind == null) {
      throwLlm(
        LlmErrorKind.protocol,
        'Unknown project error kind "$kindName".',
      );
    }
    return ProjectError(
      kind: kind,
      message: requireNonBlankString(map, 'message'),
    );
  }

  static const jsonType = 'project.error';

  final ProjectErrorKind kind;
  final String message;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{'kind': kind.name, 'message': message},
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectError && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'ProjectError($kind: $message)';
}

final class ProjectException implements Exception {
  ProjectException(this.error);

  final ProjectError error;

  @override
  String toString() => error.toString();
}

Never throwProject(ProjectErrorKind kind, String message) {
  throw ProjectException(ProjectError(kind: kind, message: message));
}

ProjectError sanitizedProjectPersistenceError() {
  return ProjectError(
    kind: ProjectErrorKind.persistence,
    message: 'Не удалось сохранить состояние проекта.',
  );
}

ProjectError sanitizedProjectAccessError() {
  return ProjectError(
    kind: ProjectErrorKind.accessUnavailable,
    message: 'Каталог проекта недоступен.',
  );
}

ProjectError sanitizedProjectUnsupportedError() {
  return ProjectError(
    kind: ProjectErrorKind.unsupported,
    message: 'Создание проектов на этой платформе недоступно.',
  );
}

ProjectError sanitizedProjectCollisionError() {
  return ProjectError(
    kind: ProjectErrorKind.collision,
    message: 'Проект с таким именем или каталогом уже существует.',
  );
}

ProjectError sanitizedProjectCleanupWarning() {
  return ProjectError(
    kind: ProjectErrorKind.persistence,
    message:
        'Каталог проекта не был удалён при отмене, потому что его нельзя '
        'безопасно очистить.',
  );
}

ProjectError sanitizedProjectDeniedError() {
  return ProjectError(
    kind: ProjectErrorKind.denied,
    message: 'Доступ к каталогу проекта запрещён.',
  );
}

ProjectError sanitizedProjectProtectedError() {
  return ProjectError(
    kind: ProjectErrorKind.denied,
    message: 'Защищённый проект нельзя удалить.',
  );
}

ProjectException wrapProjectCodecFailure(Object error) {
  if (error is ProjectException) {
    return error;
  }
  return ProjectException(
    ProjectError(
      kind: ProjectErrorKind.configuration,
      message: 'Некорректная запись проекта.',
    ),
  );
}

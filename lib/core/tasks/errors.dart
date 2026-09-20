enum TaskRepositoryErrorKind { conflict, corrupt, unavailable }

final class TaskRepositoryException implements Exception {
  const TaskRepositoryException(this.kind, this.message);

  final TaskRepositoryErrorKind kind;
  final String message;

  @override
  String toString() => 'TaskRepositoryException(${kind.name}): $message';
}

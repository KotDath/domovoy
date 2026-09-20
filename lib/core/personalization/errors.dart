enum PersonalizationErrorKind {
  configuration,
  conflict,
  notFound,
  persistence,
  secretDetected,
}

final class PersonalizationError {
  const PersonalizationError({required this.kind, required this.message});

  final PersonalizationErrorKind kind;
  final String message;
}

final class PersonalizationException implements Exception {
  const PersonalizationException(this.error);

  final PersonalizationError error;

  @override
  String toString() => error.message;
}

Never throwPersonalization(PersonalizationErrorKind kind, String message) {
  throw PersonalizationException(
    PersonalizationError(kind: kind, message: message),
  );
}

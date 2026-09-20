import '../llm/json.dart';
import 'errors.dart';

final class MemoryEntryId {
  MemoryEntryId(String value) : value = _validate(value, 'Memory entry id');

  factory MemoryEntryId.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      return MemoryEntryId(requireString(map, 'value'));
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.entry_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MemoryEntryId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class MemoryCandidateId {
  MemoryCandidateId(String value) : value = _validate(value, 'Candidate id');

  factory MemoryCandidateId.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      return MemoryCandidateId(requireString(map, 'value'));
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.candidate_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryCandidateId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Identity of a source transcript message used for provenance.
final class MemorySourceId {
  MemorySourceId(String value) : value = _validate(value, 'Memory source id');

  factory MemorySourceId.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      return MemorySourceId(requireString(map, 'value'));
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.source_id';

  final String value;

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MemorySourceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

String _validate(String value, String label) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throwMemory(MemoryErrorKind.configuration, '$label must not be blank.');
  }
  return normalized;
}

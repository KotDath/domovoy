import 'dart:convert';

import '../../../../core/llm/json.dart';

/// Operation of one append-only entry on a library record stream.
///
/// Version 1 stores immutable records, so every stream is a single `upsert`
/// at sequence 0; the enum keeps the framing explicit and versionable.
enum JsonlLibraryOperation { upsert }

/// One append-only operation on the JSONL stream of a library record.
final class JsonlLibraryEnvelope {
  JsonlLibraryEnvelope({
    required this.libraryId,
    required this.sequence,
    required this.operation,
    required this.expectedRevision,
    required this.recordRevision,
    this.record,
  }) {
    if (sequence < 0 || expectedRevision < 0 || recordRevision < 0) {
      throw const FormatException('Invalid JSONL envelope metadata.');
    }
    if ((operation == JsonlLibraryOperation.upsert) != (record != null)) {
      throw const FormatException('Invalid JSONL envelope payload.');
    }
  }

  static const type = 'domovoy.library_record_operation';
  static const version = 1;

  final String libraryId;
  final int sequence;
  final JsonlLibraryOperation operation;
  final int expectedRevision;
  final int recordRevision;
  final Map<String, Object?>? record;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'type': type,
    'version': version,
    'libraryId': libraryId,
    'sequence': sequence,
    'operation': operation.name,
    'expectedRevision': expectedRevision,
    'recordRevision': recordRevision,
    if (record != null) 'record': record,
  });
}

final class JsonlLibraryEnvelopeCodec {
  const JsonlLibraryEnvelopeCodec();

  String encodeLine(JsonlLibraryEnvelope envelope) =>
      '${jsonEncode(envelope.toJson())}\n';

  JsonlLibraryEnvelope decodeLine(String line) {
    try {
      final value = jsonDecode(line);
      if (value is! Map) {
        throw const FormatException('Envelope must be an object.');
      }
      final map = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const FormatException('Envelope keys must be strings.');
        }
        map[entry.key as String] = entry.value;
      }
      if (map['type'] != JsonlLibraryEnvelope.type ||
          map['version'] != JsonlLibraryEnvelope.version) {
        throw const FormatException('Unsupported JSONL envelope.');
      }
      final operationName = map['operation'];
      final operation = JsonlLibraryOperation.values
          .where((candidate) => candidate.name == operationName)
          .firstOrNull;
      if (operation == null) {
        throw const FormatException('Unsupported JSONL operation.');
      }
      final expectedKeys = <String>{
        'type',
        'version',
        'libraryId',
        'sequence',
        'operation',
        'expectedRevision',
        'recordRevision',
        if (operation == JsonlLibraryOperation.upsert) 'record',
      };
      if (map.keys.length != expectedKeys.length ||
          !map.keys.every(expectedKeys.contains)) {
        throw const FormatException('Unexpected JSONL envelope fields.');
      }
      final libraryId = map['libraryId'];
      final sequence = map['sequence'];
      final expectedRevision = map['expectedRevision'];
      final recordRevision = map['recordRevision'];
      if (libraryId is! String ||
          sequence is! int ||
          expectedRevision is! int ||
          recordRevision is! int) {
        throw const FormatException('Invalid JSONL envelope fields.');
      }
      Map<String, Object?>? record;
      if (operation == JsonlLibraryOperation.upsert) {
        final rawRecord = map['record'];
        if (rawRecord is! Map) {
          throw const FormatException('Invalid JSONL record payload.');
        }
        record = <String, Object?>{};
        for (final entry in rawRecord.entries) {
          if (entry.key is! String) {
            throw const FormatException('Record keys must be strings.');
          }
          record[entry.key as String] = entry.value;
        }
        record = freezeJsonMap(record);
      }
      return JsonlLibraryEnvelope(
        libraryId: libraryId,
        sequence: sequence,
        operation: operation,
        expectedRevision: expectedRevision,
        recordRevision: recordRevision,
        record: record,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Invalid JSONL envelope.');
    }
  }
}

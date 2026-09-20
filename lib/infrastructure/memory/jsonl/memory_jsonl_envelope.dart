import 'dart:convert';

import '../../../core/llm/json.dart';

/// Independent memory persistence namespaces.
enum MemoryJsonlStream { working, longTerm, candidate, extractionState }

extension MemoryJsonlStreamTag on MemoryJsonlStream {
  /// A single base64-url-safe character that namespaces stream keys.
  String get tag => switch (this) {
    MemoryJsonlStream.working => 'w',
    MemoryJsonlStream.longTerm => 'l',
    MemoryJsonlStream.candidate => 'c',
    MemoryJsonlStream.extractionState => 'e',
  };
}

MemoryJsonlStream? memoryJsonlStreamForTag(String tag) {
  for (final stream in MemoryJsonlStream.values) {
    if (stream.tag == tag) return stream;
  }
  return null;
}

enum MemoryJsonlOperation { upsert, delete }

final class MemoryJsonlEnvelope {
  MemoryJsonlEnvelope({
    required this.stream,
    required this.recordId,
    required this.sequence,
    required this.operation,
    required this.expectedRevision,
    required this.recordRevision,
    this.record,
  }) {
    if (recordId.trim().isEmpty) {
      throw const FormatException('Invalid JSONL envelope record id.');
    }
    if (sequence < 0 || expectedRevision < 0 || recordRevision < 0) {
      throw const FormatException('Invalid JSONL envelope metadata.');
    }
    if ((operation == MemoryJsonlOperation.upsert) != (record != null)) {
      throw const FormatException('Invalid JSONL envelope payload.');
    }
  }

  static const type = 'domovoy.memory_operation';
  static const version = 1;

  final MemoryJsonlStream stream;
  final String recordId;
  final int sequence;
  final MemoryJsonlOperation operation;
  final int expectedRevision;
  final int recordRevision;
  final Map<String, Object?>? record;

  Map<String, Object?> toJson() {
    return freezeJsonMap(<String, Object?>{
      'type': type,
      'version': version,
      'stream': stream.name,
      'recordId': recordId,
      'sequence': sequence,
      'operation': operation.name,
      'expectedRevision': expectedRevision,
      'recordRevision': recordRevision,
      if (record != null) 'record': record,
    });
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryJsonlEnvelope &&
          other.stream == stream &&
          other.recordId == recordId &&
          other.sequence == sequence &&
          other.operation == operation &&
          other.expectedRevision == expectedRevision &&
          other.recordRevision == recordRevision &&
          jsonEquals(other.record, record);

  @override
  int get hashCode => Object.hash(
    stream,
    recordId,
    sequence,
    operation,
    expectedRevision,
    recordRevision,
    record == null ? null : jsonHash(record),
  );
}

final class MemoryJsonlEnvelopeCodec {
  const MemoryJsonlEnvelopeCodec();

  String encodeLine(MemoryJsonlEnvelope envelope) {
    return '${jsonEncode(envelope.toJson())}\n';
  }

  MemoryJsonlEnvelope decodeLine(String line) {
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
      if (map['type'] != MemoryJsonlEnvelope.type ||
          map['version'] != MemoryJsonlEnvelope.version) {
        throw const FormatException('Unsupported JSONL envelope.');
      }
      final streamName = map['stream'];
      final stream = streamName is String
          ? MemoryJsonlStream.values
                .where((candidate) => candidate.name == streamName)
                .firstOrNull
          : null;
      if (stream == null) {
        throw const FormatException('Unsupported JSONL stream.');
      }
      final operationName = map['operation'];
      final operation = MemoryJsonlOperation.values
          .where((candidate) => candidate.name == operationName)
          .firstOrNull;
      if (operation == null) {
        throw const FormatException('Unsupported JSONL operation.');
      }
      final expectedKeys = <String>{
        'type',
        'version',
        'stream',
        'recordId',
        'sequence',
        'operation',
        'expectedRevision',
        'recordRevision',
        if (operation == MemoryJsonlOperation.upsert) 'record',
      };
      if (map.keys.length != expectedKeys.length ||
          !map.keys.every(expectedKeys.contains)) {
        throw const FormatException('Unexpected JSONL envelope fields.');
      }
      final recordId = map['recordId'];
      final sequence = map['sequence'];
      final expectedRevision = map['expectedRevision'];
      final recordRevision = map['recordRevision'];
      if (recordId is! String ||
          sequence is! int ||
          expectedRevision is! int ||
          recordRevision is! int) {
        throw const FormatException('Invalid JSONL envelope fields.');
      }
      Map<String, Object?>? record;
      if (operation == MemoryJsonlOperation.upsert) {
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
      return MemoryJsonlEnvelope(
        stream: stream,
        recordId: recordId,
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

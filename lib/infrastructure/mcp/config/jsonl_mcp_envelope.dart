import 'dart:convert';

import '../../../core/llm/json.dart';

enum JsonlMcpConnectionOperation { upsert, delete }

/// One append-only operation on the MCP connections stream.
final class JsonlMcpConnectionEnvelope {
  JsonlMcpConnectionEnvelope({
    required this.connectionId,
    required this.sequence,
    required this.operation,
    required this.expectedRevision,
    required this.recordRevision,
    this.record,
  }) {
    if (sequence < 0 || expectedRevision < 0 || recordRevision < 0) {
      throw const FormatException('Invalid JSONL envelope metadata.');
    }
    if ((operation == JsonlMcpConnectionOperation.upsert) != (record != null)) {
      throw const FormatException('Invalid JSONL envelope payload.');
    }
  }

  static const type = 'domovoy.mcp_connection_operation';
  static const version = 1;

  final String connectionId;
  final int sequence;
  final JsonlMcpConnectionOperation operation;
  final int expectedRevision;
  final int recordRevision;
  final Map<String, Object?>? record;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'type': type,
    'version': version,
    'connectionId': connectionId,
    'sequence': sequence,
    'operation': operation.name,
    'expectedRevision': expectedRevision,
    'recordRevision': recordRevision,
    if (record != null) 'record': record,
  });
}

final class JsonlMcpConnectionEnvelopeCodec {
  const JsonlMcpConnectionEnvelopeCodec();

  String encodeLine(JsonlMcpConnectionEnvelope envelope) =>
      '${jsonEncode(envelope.toJson())}\n';

  JsonlMcpConnectionEnvelope decodeLine(String line) {
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
      if (map['type'] != JsonlMcpConnectionEnvelope.type ||
          map['version'] != JsonlMcpConnectionEnvelope.version) {
        throw const FormatException('Unsupported JSONL envelope.');
      }
      final operationName = map['operation'];
      final operation = JsonlMcpConnectionOperation.values
          .where((candidate) => candidate.name == operationName)
          .firstOrNull;
      if (operation == null) {
        throw const FormatException('Unsupported JSONL operation.');
      }
      final expectedKeys = <String>{
        'type',
        'version',
        'connectionId',
        'sequence',
        'operation',
        'expectedRevision',
        'recordRevision',
        if (operation == JsonlMcpConnectionOperation.upsert) 'record',
      };
      if (map.keys.length != expectedKeys.length ||
          !map.keys.every(expectedKeys.contains)) {
        throw const FormatException('Unexpected JSONL envelope fields.');
      }
      final connectionId = map['connectionId'];
      final sequence = map['sequence'];
      final expectedRevision = map['expectedRevision'];
      final recordRevision = map['recordRevision'];
      if (connectionId is! String ||
          sequence is! int ||
          expectedRevision is! int ||
          recordRevision is! int) {
        throw const FormatException('Invalid JSONL envelope fields.');
      }
      Map<String, Object?>? record;
      if (operation == JsonlMcpConnectionOperation.upsert) {
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
      return JsonlMcpConnectionEnvelope(
        connectionId: connectionId,
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

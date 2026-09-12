import 'dart:convert';

import '../../../core/agents/ids.dart';
import '../../../core/agents/record.dart';
import '../../../core/llm/json.dart';

enum JsonlSessionOperation { upsert, delete }

final class JsonlSessionEnvelope {
  JsonlSessionEnvelope({
    required this.sessionId,
    required this.sequence,
    required this.operation,
    required this.expectedRevision,
    required this.recordRevision,
    this.record,
  }) {
    if (sequence < 0 || expectedRevision < 0 || recordRevision < 0) {
      throw const FormatException('Invalid JSONL envelope metadata.');
    }
    if ((operation == JsonlSessionOperation.upsert) != (record != null)) {
      throw const FormatException('Invalid JSONL envelope payload.');
    }
  }

  static const type = 'domovoy.agent_session_operation';
  static const version = 1;

  final AgentSessionId sessionId;
  final int sequence;
  final JsonlSessionOperation operation;
  final int expectedRevision;
  final int recordRevision;
  final Map<String, Object?>? record;

  Map<String, Object?> toJson() {
    return freezeJsonMap(<String, Object?>{
      'type': type,
      'version': version,
      'sessionId': sessionId.value,
      'sequence': sequence,
      'operation': operation.name,
      'expectedRevision': expectedRevision,
      'recordRevision': recordRevision,
      if (record != null) 'record': record,
    });
  }
}

final class JsonlSessionEnvelopeCodec {
  const JsonlSessionEnvelopeCodec();

  JsonlSessionEnvelope initial(AgentSessionRecord record) {
    return JsonlSessionEnvelope(
      sessionId: record.id,
      sequence: 0,
      operation: JsonlSessionOperation.upsert,
      expectedRevision: 0,
      recordRevision: record.revision,
      record: const AgentSessionCodec().encode(record),
    );
  }

  String encodeLine(JsonlSessionEnvelope envelope) {
    return '${jsonEncode(envelope.toJson())}\n';
  }

  JsonlSessionEnvelope decodeLine(String line) {
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
      if (map['type'] != JsonlSessionEnvelope.type ||
          map['version'] != JsonlSessionEnvelope.version) {
        throw const FormatException('Unsupported JSONL envelope.');
      }
      final operationName = map['operation'];
      final operation = JsonlSessionOperation.values
          .where((candidate) => candidate.name == operationName)
          .firstOrNull;
      if (operation == null) {
        throw const FormatException('Unsupported JSONL operation.');
      }
      final expectedKeys = <String>{
        'type',
        'version',
        'sessionId',
        'sequence',
        'operation',
        'expectedRevision',
        'recordRevision',
        if (operation == JsonlSessionOperation.upsert) 'record',
      };
      if (map.keys.length != expectedKeys.length ||
          !map.keys.every(expectedKeys.contains)) {
        throw const FormatException('Unexpected JSONL envelope fields.');
      }
      final sessionId = map['sessionId'];
      final sequence = map['sequence'];
      final expectedRevision = map['expectedRevision'];
      final recordRevision = map['recordRevision'];
      if (sessionId is! String ||
          sequence is! int ||
          expectedRevision is! int ||
          recordRevision is! int) {
        throw const FormatException('Invalid JSONL envelope fields.');
      }
      Map<String, Object?>? record;
      if (operation == JsonlSessionOperation.upsert) {
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
      return JsonlSessionEnvelope(
        sessionId: AgentSessionId(sessionId),
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

final class JsonlSessionKeyCodec {
  const JsonlSessionKeyCodec();

  static const prefix = 'session-v1_';

  String encode(AgentSessionId id) {
    final encoded = base64Url.encode(utf8.encode(id.value)).replaceAll('=', '');
    return '$prefix$encoded';
  }

  AgentSessionId decode(String key) {
    try {
      if (!key.startsWith(prefix)) {
        throw const FormatException('Unknown stream key.');
      }
      final encoded = key.substring(prefix.length);
      if (encoded.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(encoded)) {
        throw const FormatException('Invalid stream key.');
      }
      final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      final id = AgentSessionId(utf8.decode(base64Url.decode(padded)));
      if (encode(id) != key) {
        throw const FormatException('Non-canonical stream key.');
      }
      return id;
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Invalid stream key.');
    }
  }
}

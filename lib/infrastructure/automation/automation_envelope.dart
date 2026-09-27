import 'dart:convert';

/// Kind of automation stream stored under one JSONL key.
enum JsonlAutomationStreamKind {
  task,
  run;

  static JsonlAutomationStreamKind fromWire(Object? raw) {
    for (final kind in values) {
      if (kind.name == raw) {
        return kind;
      }
    }
    throw const FormatException('Unsupported automation stream kind.');
  }
}

/// Operation of one append-only entry.
///
/// `taskUpsert` writes a task revision (create, update, pause/resume,
/// tombstone); `runRecord` writes one revision of a run stream (start, terminal
/// state, delivery update).
enum JsonlAutomationOperation { taskUpsert, runRecord }

/// One versioned JSONL envelope of the automation store.
final class JsonlAutomationEnvelope {
  JsonlAutomationEnvelope({
    required this.streamKind,
    required this.streamId,
    required this.sequence,
    required this.operation,
    required this.expectedRevision,
    required this.entryRevision,
    required this.payload,
  }) {
    if (sequence < 0 || expectedRevision < 0 || entryRevision < 0) {
      throw const FormatException('Invalid JSONL envelope metadata.');
    }
    final expectedKind = switch (operation) {
      JsonlAutomationOperation.taskUpsert => JsonlAutomationStreamKind.task,
      JsonlAutomationOperation.runRecord => JsonlAutomationStreamKind.run,
    };
    if (streamKind != expectedKind) {
      throw const FormatException('Operation does not match the stream kind.');
    }
  }

  static const type = 'domovoy.automation_operation';
  static const version = 1;

  final JsonlAutomationStreamKind streamKind;
  final String streamId;
  final int sequence;
  final JsonlAutomationOperation operation;
  final int expectedRevision;
  final int entryRevision;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'version': version,
    'streamKind': streamKind.name,
    'streamId': streamId,
    'sequence': sequence,
    'operation': operation.name,
    'expectedRevision': expectedRevision,
    'entryRevision': entryRevision,
    'payload': payload,
  };
}

final class JsonlAutomationEnvelopeCodec {
  const JsonlAutomationEnvelopeCodec();

  String encodeLine(JsonlAutomationEnvelope envelope) =>
      '${jsonEncode(envelope.toJson())}\n';

  JsonlAutomationEnvelope decodeLine(String line) {
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
      const expectedKeys = <String>{
        'type',
        'version',
        'streamKind',
        'streamId',
        'sequence',
        'operation',
        'expectedRevision',
        'entryRevision',
        'payload',
      };
      if (map['type'] != JsonlAutomationEnvelope.type ||
          map['version'] != JsonlAutomationEnvelope.version) {
        throw const FormatException('Unsupported JSONL envelope.');
      }
      if (map.keys.length != expectedKeys.length ||
          !map.keys.every(expectedKeys.contains)) {
        throw const FormatException('Unexpected JSONL envelope fields.');
      }
      final operationName = map['operation'];
      final operation = JsonlAutomationOperation.values
          .where((candidate) => candidate.name == operationName)
          .firstOrNull;
      if (operation == null) {
        throw const FormatException('Unsupported JSONL operation.');
      }
      final streamId = map['streamId'];
      final sequence = map['sequence'];
      final expectedRevision = map['expectedRevision'];
      final entryRevision = map['entryRevision'];
      final payload = map['payload'];
      if (streamId is! String ||
          sequence is! int ||
          expectedRevision is! int ||
          entryRevision is! int ||
          payload is! Map) {
        throw const FormatException('Invalid JSONL envelope fields.');
      }
      final payloadMap = <String, Object?>{};
      for (final entry in payload.entries) {
        if (entry.key is! String) {
          throw const FormatException('Payload keys must be strings.');
        }
        payloadMap[entry.key as String] = entry.value;
      }
      return JsonlAutomationEnvelope(
        streamKind: JsonlAutomationStreamKind.fromWire(map['streamKind']),
        streamId: streamId,
        sequence: sequence,
        operation: operation,
        expectedRevision: expectedRevision,
        entryRevision: entryRevision,
        payload: Map<String, Object?>.unmodifiable(payloadMap),
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Invalid JSONL envelope.');
    }
  }
}

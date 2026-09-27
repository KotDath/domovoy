import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../core/llm/cancellation.dart';
import '../../../core/llm/json.dart';
import '../../../core/mcp/mcp.dart';
import '../../agents/jsonl/jsonl_replay.dart';
import '../../agents/jsonl/jsonl_stream_storage.dart';

/// Append/replay JSONL storage for durable per-chat/project MCP tool grants.
///
/// One logical stream holds every scope; each line is a self-describing
/// operation for exactly one target. Secrets never appear here: the payload is
/// a list of model-facing tool names only.
final class JsonlMcpToolSelectionStore implements McpToolSelectionStore {
  JsonlMcpToolSelectionStore({
    required this.storage,
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits(),
       _coordinator = _JsonlSelectionStoreCoordinator(),
       _codec = const McpToolSelectionCodec(),
       _envelopes = const JsonlMcpToolSelectionEnvelopeCodec() {
    _replay = JsonlMcpToolSelectionReplay(codec: _codec, limits: this.limits);
  }

  static const streamKey = 'mcp-tool-selections-v1';

  final JsonlStreamStorage storage;
  final JsonlStorageLimits limits;
  final McpToolSelectionCodec _codec;
  final JsonlMcpToolSelectionEnvelopeCodec _envelopes;
  final _JsonlSelectionStoreCoordinator _coordinator;
  late final JsonlMcpToolSelectionReplay _replay;

  @override
  Future<McpToolSelectionRecord?> load(McpToolAccessTarget target) {
    return _coordinator.run(() async {
      final state = await _read();
      return state.records[target.storeKey];
    });
  }

  @override
  Future<List<McpToolSelectionRecord>> loadAll() {
    return _coordinator.run(() async {
      final state = await _read();
      final records = state.records.values.toList()
        ..sort((a, b) => a.target.storeKey.compareTo(b.target.storeKey));
      return List<McpToolSelectionRecord>.unmodifiable(records);
    });
  }

  @override
  Future<void> save(
    McpToolSelectionRecord record, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final state = await _read();
      final key = record.target.storeKey;
      final existing = state.records[key];
      final tombstoneRevision = state.tombstoneRevisions[key];
      if (existing != null) {
        if (existing.revision != expectedRevision ||
            record.revision != expectedRevision + 1) {
          _throwConflict(record.target);
        }
      } else if (tombstoneRevision != null) {
        if (expectedRevision != tombstoneRevision ||
            record.revision != tombstoneRevision + 1) {
          _throwConflict(record.target);
        }
      } else if (expectedRevision != 0 || record.revision != 0) {
        _throwConflict(record.target);
      }
      final envelope = JsonlMcpToolSelectionEnvelope(
        targetKind: record.target.kind,
        targetId: record.target.id,
        sequence: (state.sequences[key] ?? -1) + 1,
        operation: JsonlMcpToolSelectionOperation.upsert,
        expectedRevision: expectedRevision,
        recordRevision: record.revision,
        record: _codec.encode(record),
      );
      _throwIfCancelled(cancellation);
      await _publish(_append(state.validPrefix, envelope));
    });
  }

  @override
  Future<void> delete(
    McpToolAccessTarget target, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<void>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final state = await _read();
      final existing = state.records[target.storeKey];
      if (existing == null || existing.revision != expectedRevision) {
        _throwConflict(target);
      }
      final envelope = JsonlMcpToolSelectionEnvelope(
        targetKind: target.kind,
        targetId: target.id,
        sequence: (state.sequences[target.storeKey] ?? -1) + 1,
        operation: JsonlMcpToolSelectionOperation.delete,
        expectedRevision: expectedRevision,
        recordRevision: expectedRevision,
      );
      _throwIfCancelled(cancellation);
      await _publish(_append(state.validPrefix, envelope));
    });
  }

  Future<JsonlMcpToolSelectionReplayResult> _read() async {
    final Stream<List<int>>? chunks;
    try {
      chunks = await storage.read(streamKey);
    } on Object {
      throw _persistenceException();
    }
    if (chunks == null) {
      return JsonlMcpToolSelectionReplayResult.empty();
    }
    try {
      return await _replay.replay(chunks);
    } on Object {
      throw _persistenceException();
    }
  }

  Uint8List _append(List<int> prefix, JsonlMcpToolSelectionEnvelope envelope) {
    final line = _envelopes.encodeLine(envelope);
    final bytes = Uint8List.fromList(utf8.encode(line));
    if (bytes.length - 1 > limits.maxEntryBytes) {
      throw _persistenceException();
    }
    final builder = BytesBuilder(copy: false)
      ..add(prefix)
      ..add(bytes);
    final value = builder.takeBytes();
    if (value.length > limits.maxStreamBytes) {
      throw _persistenceException();
    }
    return value;
  }

  Future<void> _publish(List<int> contents) async {
    try {
      await storage.publish(streamKey, contents);
    } on Object {
      throw _persistenceException();
    }
    try {
      await storage.cleanup(streamKey);
    } on Object {
      // Cleanup is best effort after the active generation is selected.
    }
  }
}

enum JsonlMcpToolSelectionOperation { upsert, delete }

/// One append-only operation on the MCP tool selection stream.
final class JsonlMcpToolSelectionEnvelope {
  JsonlMcpToolSelectionEnvelope({
    required this.targetKind,
    required this.targetId,
    required this.sequence,
    required this.operation,
    required this.expectedRevision,
    required this.recordRevision,
    this.record,
  }) {
    if (targetId.trim().isEmpty ||
        sequence < 0 ||
        expectedRevision < 0 ||
        recordRevision < 0) {
      throw const FormatException('Invalid JSONL envelope metadata.');
    }
    if ((operation == JsonlMcpToolSelectionOperation.upsert) !=
        (record != null)) {
      throw const FormatException('Invalid JSONL envelope payload.');
    }
  }

  static const type = 'domovoy.mcp_tool_selection_operation';
  static const version = 1;

  final McpToolAccessTargetKind targetKind;
  final String targetId;
  final int sequence;
  final JsonlMcpToolSelectionOperation operation;
  final int expectedRevision;
  final int recordRevision;
  final Map<String, Object?>? record;

  McpToolAccessTarget get target => switch (targetKind) {
    McpToolAccessTargetKind.chat => McpToolAccessTarget.chat(targetId),
    McpToolAccessTargetKind.project => McpToolAccessTarget.project(targetId),
  };

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'type': type,
    'version': version,
    'targetKind': targetKind.name,
    'targetId': targetId,
    'sequence': sequence,
    'operation': operation.name,
    'expectedRevision': expectedRevision,
    'recordRevision': recordRevision,
    if (record != null) 'record': record,
  });
}

final class JsonlMcpToolSelectionEnvelopeCodec {
  const JsonlMcpToolSelectionEnvelopeCodec();

  String encodeLine(JsonlMcpToolSelectionEnvelope envelope) =>
      '${jsonEncode(envelope.toJson())}\n';

  JsonlMcpToolSelectionEnvelope decodeLine(String line) {
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
      if (map['type'] != JsonlMcpToolSelectionEnvelope.type ||
          map['version'] != JsonlMcpToolSelectionEnvelope.version) {
        throw const FormatException('Unsupported JSONL envelope.');
      }
      final operationName = map['operation'];
      final operation = JsonlMcpToolSelectionOperation.values
          .where((candidate) => candidate.name == operationName)
          .firstOrNull;
      if (operation == null) {
        throw const FormatException('Unsupported JSONL operation.');
      }
      final targetKindName = map['targetKind'];
      final targetKind = McpToolAccessTargetKind.values
          .where((candidate) => candidate.name == targetKindName)
          .firstOrNull;
      if (targetKind == null) {
        throw const FormatException('Unsupported JSONL target kind.');
      }
      final expectedKeys = <String>{
        'type',
        'version',
        'targetKind',
        'targetId',
        'sequence',
        'operation',
        'expectedRevision',
        'recordRevision',
        if (operation == JsonlMcpToolSelectionOperation.upsert) 'record',
      };
      if (map.keys.length != expectedKeys.length ||
          !map.keys.every(expectedKeys.contains)) {
        throw const FormatException('Unexpected JSONL envelope fields.');
      }
      final targetId = map['targetId'];
      final sequence = map['sequence'];
      final expectedRevision = map['expectedRevision'];
      final recordRevision = map['recordRevision'];
      if (targetId is! String ||
          sequence is! int ||
          expectedRevision is! int ||
          recordRevision is! int) {
        throw const FormatException('Invalid JSONL envelope fields.');
      }
      Map<String, Object?>? record;
      if (operation == JsonlMcpToolSelectionOperation.upsert) {
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
      return JsonlMcpToolSelectionEnvelope(
        targetKind: targetKind,
        targetId: targetId,
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

final class JsonlMcpToolSelectionReplayResult {
  JsonlMcpToolSelectionReplayResult({
    required Map<String, McpToolSelectionRecord> records,
    required Map<String, int> tombstoneRevisions,
    required Map<String, int> sequences,
    required List<int> validPrefix,
    required this.needsRepair,
  }) : records = Map<String, McpToolSelectionRecord>.unmodifiable(records),
       tombstoneRevisions = Map<String, int>.unmodifiable(tombstoneRevisions),
       sequences = Map<String, int>.unmodifiable(sequences),
       validPrefix = Uint8List.fromList(validPrefix);

  factory JsonlMcpToolSelectionReplayResult.empty() =>
      JsonlMcpToolSelectionReplayResult(
        records: const <String, McpToolSelectionRecord>{},
        tombstoneRevisions: const <String, int>{},
        sequences: const <String, int>{},
        validPrefix: const <int>[],
        needsRepair: false,
      );

  final Map<String, McpToolSelectionRecord> records;
  final Map<String, int> tombstoneRevisions;
  final Map<String, int> sequences;
  final Uint8List validPrefix;
  final bool needsRepair;
}

final class JsonlMcpToolSelectionReplayException implements Exception {
  const JsonlMcpToolSelectionReplayException(this.reason);

  final String reason;

  @override
  String toString() => 'JsonlMcpToolSelectionReplayException($reason)';
}

/// Replays the append-only MCP tool selection stream.
///
/// Per-target sequences and revisions must be strictly increasing; a truncated
/// trailing line is tolerated and reported through `needsRepair`.
final class JsonlMcpToolSelectionReplay {
  JsonlMcpToolSelectionReplay({required this.codec, JsonlStorageLimits? limits})
    : limits = limits ?? JsonlStorageLimits();

  final McpToolSelectionCodec codec;
  final JsonlStorageLimits limits;
  final JsonlMcpToolSelectionEnvelopeCodec envelopeCodec =
      const JsonlMcpToolSelectionEnvelopeCodec();

  Future<JsonlMcpToolSelectionReplayResult> replay(
    Stream<List<int>> chunks,
  ) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    try {
      await for (final chunk in chunks) {
        length += chunk.length;
        if (length > limits.maxStreamBytes) {
          throw const JsonlMcpToolSelectionReplayException(
            'stream limit exceeded',
          );
        }
        builder.add(chunk);
      }
    } on JsonlMcpToolSelectionReplayException {
      rethrow;
    } on Object {
      throw const JsonlMcpToolSelectionReplayException('stream read failed');
    }
    final bytes = builder.takeBytes();
    final states = <String, _McpToolSelectionState>{};
    var lineStart = 0;
    var completePrefixLength = 0;
    for (var index = 0; index < bytes.length; index += 1) {
      if (bytes[index] != 0x0a) {
        continue;
      }
      final lineLength = index - lineStart;
      if (lineLength <= 0 || lineLength > limits.maxEntryBytes) {
        throw const JsonlMcpToolSelectionReplayException(
          'entry limit or framing violation',
        );
      }
      final String line;
      try {
        line = utf8.decode(
          bytes.sublist(lineStart, index),
          allowMalformed: false,
        );
      } on Object {
        throw const JsonlMcpToolSelectionReplayException(
          'entry is not valid UTF-8',
        );
      }
      final JsonlMcpToolSelectionEnvelope envelope;
      try {
        envelope = envelopeCodec.decodeLine(line);
      } on Object {
        throw const JsonlMcpToolSelectionReplayException('invalid envelope');
      }
      _apply(states, envelope);
      completePrefixLength = index + 1;
      lineStart = index + 1;
    }
    final fragmentLength = bytes.length - completePrefixLength;
    if (fragmentLength > limits.maxEntryBytes) {
      throw const JsonlMcpToolSelectionReplayException('entry limit exceeded');
    }
    final records = <String, McpToolSelectionRecord>{};
    final tombstoneRevisions = <String, int>{};
    final sequences = <String, int>{};
    for (final entry in states.entries) {
      sequences[entry.key] = entry.value.sequence;
      final record = entry.value.record;
      if (record == null) {
        tombstoneRevisions[entry.key] = entry.value.revision;
      } else {
        records[entry.key] = record;
      }
    }
    return JsonlMcpToolSelectionReplayResult(
      records: records,
      tombstoneRevisions: tombstoneRevisions,
      sequences: sequences,
      validPrefix: bytes.sublist(0, completePrefixLength),
      needsRepair: fragmentLength > 0,
    );
  }

  void _apply(
    Map<String, _McpToolSelectionState> states,
    JsonlMcpToolSelectionEnvelope envelope,
  ) {
    final key = envelope.target.storeKey;
    final state = states.putIfAbsent(key, () => _McpToolSelectionState());
    if (state.sequence < 0) {
      if (envelope.sequence != 0) {
        throw const JsonlMcpToolSelectionReplayException(
          'stream sequence mismatch',
        );
      }
    } else if (envelope.sequence != state.sequence + 1) {
      throw const JsonlMcpToolSelectionReplayException(
        'stream sequence mismatch',
      );
    }
    switch (envelope.operation) {
      case JsonlMcpToolSelectionOperation.upsert:
        final McpToolSelectionRecord record;
        try {
          record = codec.decode(envelope.record);
        } on Object {
          throw const JsonlMcpToolSelectionReplayException(
            'record payload rejected',
          );
        }
        if (record.target != envelope.target ||
            record.revision != envelope.recordRevision) {
          throw const JsonlMcpToolSelectionReplayException(
            'record identity mismatch',
          );
        }
        if (state.sequence < 0) {
          if (envelope.expectedRevision != 0 || envelope.recordRevision != 0) {
            throw const JsonlMcpToolSelectionReplayException(
              'invalid initial revision',
            );
          }
        } else if (envelope.expectedRevision != state.revision ||
            envelope.recordRevision != state.revision + 1) {
          throw const JsonlMcpToolSelectionReplayException(
            'record revision mismatch',
          );
        }
        state.record = record;
        state.revision = record.revision;
        state.tombstone = false;
      case JsonlMcpToolSelectionOperation.delete:
        if (state.sequence < 0 || state.tombstone) {
          throw const JsonlMcpToolSelectionReplayException(
            'delete without record',
          );
        }
        if (envelope.expectedRevision != state.revision ||
            envelope.recordRevision != state.revision) {
          throw const JsonlMcpToolSelectionReplayException(
            'invalid delete transition',
          );
        }
        state.record = null;
        state.tombstone = true;
    }
    state.sequence = envelope.sequence;
  }
}

final class _McpToolSelectionState {
  int sequence = -1;
  int revision = 0;
  bool tombstone = false;
  McpToolSelectionRecord? record;
}

final class _JsonlSelectionStoreCoordinator {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final predecessor = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        released.complete();
      }
    }();
  }
}

McpException _persistenceException() => McpException(
  McpError(
    kind: McpErrorKind.persistence,
    message: sanitizedMcpPersistenceMessage(),
  ),
);

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throw _cancelledException();
  }
}

McpException _cancelledException() =>
    McpException(McpError(kind: McpErrorKind.cancelled, message: 'cancelled'));

Never _throwConflict(McpToolAccessTarget target) {
  throwMcp(
    McpErrorKind.persistence,
    'MCP tool selection for ${target.storeKey} was updated concurrently.',
  );
}

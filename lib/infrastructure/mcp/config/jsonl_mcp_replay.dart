import 'dart:convert';
import 'dart:typed_data';

import '../../../core/mcp/mcp.dart';
import '../../agents/jsonl/jsonl_replay.dart';
import 'jsonl_mcp_envelope.dart';

final class JsonlMcpReplayResult {
  JsonlMcpReplayResult({
    required Map<String, McpConnectionConfig> records,
    required Set<String> tombstones,
    required Map<String, int> tombstoneRevisions,
    required Map<String, int> sequences,
    required List<int> validPrefix,
    required this.needsRepair,
  }) : records = Map<String, McpConnectionConfig>.unmodifiable(records),
       tombstones = Set<String>.unmodifiable(tombstones),
       tombstoneRevisions = Map<String, int>.unmodifiable(tombstoneRevisions),
       sequences = Map<String, int>.unmodifiable(sequences),
       validPrefix = Uint8List.fromList(validPrefix);

  final Map<String, McpConnectionConfig> records;
  final Set<String> tombstones;
  final Map<String, int> tombstoneRevisions;
  final Map<String, int> sequences;
  final Uint8List validPrefix;
  final bool needsRepair;
}

final class JsonlMcpReplayException implements Exception {
  const JsonlMcpReplayException(this.reason);

  final String reason;

  @override
  String toString() => 'JsonlMcpReplayException($reason)';
}

/// Replays the append-only MCP connections stream.
///
/// The stream is a sequence of per-connection operations. Sequence numbers and
/// revisions must be strictly increasing per connection; a truncated trailing
/// line is tolerated and reported through [JsonlMcpReplayResult.needsRepair].
final class JsonlMcpConnectionReplay {
  JsonlMcpConnectionReplay({
    this.envelopeCodec = const JsonlMcpConnectionEnvelopeCodec(),
    this.recordCodec = const McpConnectionCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits();

  final JsonlMcpConnectionEnvelopeCodec envelopeCodec;
  final McpConnectionCodec recordCodec;
  final JsonlStorageLimits limits;

  Future<JsonlMcpReplayResult> replay(Stream<List<int>> chunks) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    try {
      await for (final chunk in chunks) {
        length += chunk.length;
        if (length > limits.maxStreamBytes) {
          throw const JsonlMcpReplayException('stream limit exceeded');
        }
        builder.add(chunk);
      }
    } on JsonlMcpReplayException {
      rethrow;
    } on Object {
      throw const JsonlMcpReplayException('stream read failed');
    }
    final bytes = builder.takeBytes();
    final states = <String, _McpConnectionState>{};
    var lineStart = 0;
    var completePrefixLength = 0;
    for (var index = 0; index < bytes.length; index += 1) {
      if (bytes[index] != 0x0a) {
        continue;
      }
      final lineLength = index - lineStart;
      if (lineLength <= 0 || lineLength > limits.maxEntryBytes) {
        throw const JsonlMcpReplayException('entry limit or framing violation');
      }
      final String line;
      try {
        line = utf8.decode(
          bytes.sublist(lineStart, index),
          allowMalformed: false,
        );
      } on Object {
        throw const JsonlMcpReplayException('entry is not valid UTF-8');
      }
      final JsonlMcpConnectionEnvelope envelope;
      try {
        envelope = envelopeCodec.decodeLine(line);
      } on Object {
        throw const JsonlMcpReplayException('invalid envelope');
      }
      _apply(states, envelope);
      completePrefixLength = index + 1;
      lineStart = index + 1;
    }
    final fragmentLength = bytes.length - completePrefixLength;
    if (fragmentLength > limits.maxEntryBytes) {
      throw const JsonlMcpReplayException('entry limit exceeded');
    }
    final records = <String, McpConnectionConfig>{};
    final tombstones = <String>{};
    final tombstoneRevisions = <String, int>{};
    final sequences = <String, int>{};
    for (final entry in states.entries) {
      sequences[entry.key] = entry.value.sequence;
      final record = entry.value.record;
      if (record == null) {
        tombstones.add(entry.key);
        tombstoneRevisions[entry.key] = entry.value.revision;
      } else {
        records[entry.key] = record;
      }
    }
    return JsonlMcpReplayResult(
      records: records,
      tombstones: tombstones,
      tombstoneRevisions: tombstoneRevisions,
      sequences: sequences,
      validPrefix: bytes.sublist(0, completePrefixLength),
      needsRepair: fragmentLength > 0,
    );
  }

  void _apply(
    Map<String, _McpConnectionState> states,
    JsonlMcpConnectionEnvelope envelope,
  ) {
    final state = states.putIfAbsent(
      envelope.connectionId,
      () => _McpConnectionState(),
    );
    if (state.sequence < 0) {
      if (envelope.sequence != 0) {
        throw const JsonlMcpReplayException('stream sequence mismatch');
      }
    } else if (envelope.sequence != state.sequence + 1) {
      throw const JsonlMcpReplayException('stream sequence mismatch');
    }
    switch (envelope.operation) {
      case JsonlMcpConnectionOperation.upsert:
        final McpConnectionConfig record;
        try {
          record = recordCodec.decode(envelope.record);
        } on Object {
          throw const JsonlMcpReplayException('record payload rejected');
        }
        if (record.connectionId.value != envelope.connectionId ||
            record.revision != envelope.recordRevision) {
          throw const JsonlMcpReplayException('record identity mismatch');
        }
        if (state.sequence < 0) {
          if (envelope.expectedRevision != 0 || envelope.recordRevision != 0) {
            throw const JsonlMcpReplayException('invalid initial revision');
          }
        } else if (envelope.expectedRevision != state.revision ||
            envelope.recordRevision != state.revision + 1) {
          throw const JsonlMcpReplayException('record revision mismatch');
        }
        state.record = record;
        state.revision = record.revision;
        state.tombstone = false;
      case JsonlMcpConnectionOperation.delete:
        if (state.sequence < 0 || state.tombstone) {
          throw const JsonlMcpReplayException('delete without record');
        }
        if (envelope.expectedRevision != state.revision ||
            envelope.recordRevision != state.revision) {
          throw const JsonlMcpReplayException('invalid delete transition');
        }
        state.record = null;
        state.tombstone = true;
    }
    state.sequence = envelope.sequence;
  }
}

final class _McpConnectionState {
  int sequence = -1;
  int revision = 0;
  bool tombstone = false;
  McpConnectionConfig? record;
}

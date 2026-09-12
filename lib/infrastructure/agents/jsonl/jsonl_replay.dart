import 'dart:convert';
import 'dart:typed_data';

import '../../../core/agents/ids.dart';
import '../../../core/agents/record.dart';
import 'jsonl_envelope.dart';

final class JsonlStorageLimits {
  JsonlStorageLimits({
    this.maxEntryBytes = 32 * 1024 * 1024,
    this.maxStreamBytes = 256 * 1024 * 1024,
  }) {
    if (maxEntryBytes <= 0 || maxStreamBytes <= 0) {
      throw ArgumentError('JSONL storage limits must be positive.');
    }
    if (maxEntryBytes > maxStreamBytes) {
      throw ArgumentError('JSONL entry limit must not exceed stream limit.');
    }
  }

  final int maxEntryBytes;
  final int maxStreamBytes;
}

final class JsonlReplayResult {
  JsonlReplayResult({
    required this.sequence,
    required this.recordRevision,
    required this.record,
    required this.isTombstone,
    required List<int> validPrefix,
    required this.needsRepair,
  }) : validPrefix = Uint8List.fromList(validPrefix);

  final int? sequence;
  final int? recordRevision;
  final AgentSessionRecord? record;
  final bool isTombstone;
  final Uint8List validPrefix;
  final bool needsRepair;
}

final class JsonlReplayException implements Exception {
  const JsonlReplayException(this.reason);

  final String reason;

  @override
  String toString() => 'JsonlReplayException($reason)';
}

final class JsonlSessionReplay {
  JsonlSessionReplay({
    this.envelopeCodec = const JsonlSessionEnvelopeCodec(),
    this.recordCodec = const AgentSessionCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits();

  final JsonlSessionEnvelopeCodec envelopeCodec;
  final AgentSessionCodec recordCodec;
  final JsonlStorageLimits limits;

  Future<JsonlReplayResult> replay(
    AgentSessionId expectedId,
    Stream<List<int>> chunks,
  ) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    try {
      await for (final chunk in chunks) {
        length += chunk.length;
        if (length > limits.maxStreamBytes) {
          throw const JsonlReplayException('stream limit exceeded');
        }
        builder.add(chunk);
      }
    } on JsonlReplayException {
      rethrow;
    } on Object {
      throw const JsonlReplayException('stream read failed');
    }
    final bytes = builder.takeBytes();
    var lineStart = 0;
    var sequence = -1;
    int? revision;
    AgentSessionRecord? record;
    var tombstone = false;
    var completePrefixLength = 0;
    var sawEntry = false;

    for (var index = 0; index < bytes.length; index += 1) {
      if (bytes[index] != 0x0a) {
        continue;
      }
      final lineLength = index - lineStart;
      if (lineLength <= 0 || lineLength > limits.maxEntryBytes) {
        throw const JsonlReplayException('entry limit or framing violation');
      }
      final String line;
      try {
        line = utf8.decode(
          bytes.sublist(lineStart, index),
          allowMalformed: false,
        );
      } on Object {
        throw const JsonlReplayException('entry is not valid UTF-8');
      }
      final JsonlSessionEnvelope envelope;
      try {
        envelope = envelopeCodec.decodeLine(line);
      } on Object {
        throw const JsonlReplayException('invalid envelope');
      }
      if (envelope.sessionId != expectedId) {
        throw const JsonlReplayException('session identity mismatch');
      }
      if (!sawEntry && envelope.operation == JsonlSessionOperation.delete) {
        if (envelope.expectedRevision != envelope.recordRevision) {
          throw const JsonlReplayException('invalid tombstone revision');
        }
        sequence = envelope.sequence;
        revision = envelope.recordRevision;
        tombstone = true;
      } else {
        if (envelope.sequence != sequence + 1) {
          throw const JsonlReplayException('stream sequence mismatch');
        }
        if (tombstone) {
          throw const JsonlReplayException('operation follows tombstone');
        }
        if (envelope.operation == JsonlSessionOperation.upsert) {
          if (!sawEntry) {
            if (envelope.sequence != 0 ||
                envelope.expectedRevision != 0 ||
                envelope.recordRevision != 0) {
              throw const JsonlReplayException('invalid initial revision');
            }
          } else if (revision == null ||
              envelope.expectedRevision != revision ||
              envelope.recordRevision != revision + 1) {
            throw const JsonlReplayException('record revision mismatch');
          }
          final AgentSessionRecord decoded;
          try {
            decoded = recordCodec.decode(envelope.record);
          } on Object {
            throw const JsonlReplayException('record payload rejected');
          }
          if (decoded.id != expectedId ||
              decoded.revision != envelope.recordRevision) {
            throw const JsonlReplayException('record identity mismatch');
          }
          record = decoded;
          revision = decoded.revision;
        } else {
          if (!sawEntry ||
              revision == null ||
              envelope.expectedRevision != revision ||
              envelope.recordRevision != revision) {
            throw const JsonlReplayException('invalid delete transition');
          }
          record = null;
          tombstone = true;
        }
        sequence = envelope.sequence;
      }
      sawEntry = true;
      completePrefixLength = index + 1;
      lineStart = index + 1;
    }

    final fragmentLength = bytes.length - completePrefixLength;
    if (fragmentLength > limits.maxEntryBytes) {
      throw const JsonlReplayException('entry limit exceeded');
    }
    if (!sawEntry) {
      throw const JsonlReplayException('stream has no complete entry');
    }
    return JsonlReplayResult(
      sequence: sawEntry ? sequence : null,
      recordRevision: revision,
      record: record,
      isTombstone: tombstone,
      validPrefix: bytes.sublist(0, completePrefixLength),
      needsRepair: fragmentLength > 0,
    );
  }
}

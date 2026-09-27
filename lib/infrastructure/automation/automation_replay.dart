import 'dart:convert';
import 'dart:typed_data';

import '../agents/jsonl/jsonl_replay.dart';
import 'automation_envelope.dart';

final class JsonlAutomationReplayResult {
  JsonlAutomationReplayResult({
    required this.sequence,
    required this.revision,
    required this.payload,
    required List<int> validPrefix,
    required this.needsRepair,
  }) : validPrefix = Uint8List.fromList(validPrefix);

  final int sequence;
  final int revision;
  final Map<String, Object?> payload;
  final Uint8List validPrefix;

  /// True when a truncated tail was dropped; the caller can repair the stream
  /// by publishing [validPrefix] plus a successor entry.
  final bool needsRepair;
}

/// Replays one versioned JSONL stream of the automation store.
///
/// The replay validates the operation/stream kind pair, the identity, the
/// sequence and the revision chain, and fails closed with
/// [JsonlReplayException] on anything else. A trailing fragment without its
/// newline is a truncated write and is reported through
/// [JsonlAutomationReplayResult.needsRepair] instead of being accepted.
final class JsonlAutomationReplay {
  JsonlAutomationReplay({
    this.envelopeCodec = const JsonlAutomationEnvelopeCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits();

  final JsonlAutomationEnvelopeCodec envelopeCodec;
  final JsonlStorageLimits limits;

  /// Maximum complete records accepted per stream kind.
  static const maxRunRecords = 3;

  Future<JsonlAutomationReplayResult> replay({
    required JsonlAutomationStreamKind kind,
    required String streamId,
    required Stream<List<int>> chunks,
  }) async {
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
    Map<String, Object?>? payload;
    var completePrefixLength = 0;
    var sawEntry = false;
    var entryCount = 0;

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
      final JsonlAutomationEnvelope envelope;
      try {
        envelope = envelopeCodec.decodeLine(line);
      } on Object {
        throw const JsonlReplayException('invalid envelope');
      }
      if (envelope.streamKind != kind || envelope.streamId != streamId) {
        throw const JsonlReplayException('stream identity mismatch');
      }
      if (envelope.sequence != sequence + 1) {
        throw const JsonlReplayException('stream sequence mismatch');
      }
      if (!sawEntry) {
        if (envelope.sequence != 0 ||
            envelope.expectedRevision != 0 ||
            envelope.entryRevision != 0) {
          throw const JsonlReplayException('invalid initial revision');
        }
      } else if (revision == null ||
          envelope.expectedRevision != revision ||
          envelope.entryRevision != revision + 1) {
        throw const JsonlReplayException('record revision mismatch');
      }
      entryCount += 1;
      if (kind == JsonlAutomationStreamKind.run && entryCount > maxRunRecords) {
        throw const JsonlReplayException('too many run records');
      }
      sequence = envelope.sequence;
      revision = envelope.entryRevision;
      payload = envelope.payload;
      sawEntry = true;
      completePrefixLength = index + 1;
      lineStart = index + 1;
    }

    final fragmentLength = bytes.length - completePrefixLength;
    if (fragmentLength > limits.maxEntryBytes) {
      throw const JsonlReplayException('entry limit exceeded');
    }
    if (!sawEntry || revision == null || payload == null) {
      throw const JsonlReplayException('stream has no complete entry');
    }
    return JsonlAutomationReplayResult(
      sequence: sequence,
      revision: revision,
      payload: payload,
      validPrefix: bytes.sublist(0, completePrefixLength),
      needsRepair: fragmentLength > 0,
    );
  }
}

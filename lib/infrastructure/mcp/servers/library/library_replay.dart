import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/research/research.dart';
import '../../../agents/jsonl/jsonl_replay.dart';
import 'library_envelope.dart';

final class JsonlLibraryReplayResult {
  JsonlLibraryReplayResult({
    required this.sequence,
    required this.recordRevision,
    required this.record,
    required List<int> validPrefix,
    required this.needsRepair,
  }) : validPrefix = Uint8List.fromList(validPrefix);

  final int? sequence;
  final int? recordRevision;
  final LibraryRecord? record;
  final Uint8List validPrefix;

  /// True when a truncated tail was dropped; the caller can repair the stream
  /// by publishing [validPrefix] plus a successor entry.
  final bool needsRepair;
}

/// Replays one versioned JSONL stream of a library record.
///
/// A trailing fragment without its newline is a truncated write: it is ignored
/// and reported through [JsonlLibraryReplayResult.needsRepair]. Anything else
/// that cannot be replayed - bad UTF-8, an unknown envelope version, a broken
/// sequence, or a record that fails validation - throws
/// [JsonlReplayException] so the store fails closed instead of returning a
/// partially accepted record.
final class JsonlLibraryReplay {
  JsonlLibraryReplay({
    this.envelopeCodec = const JsonlLibraryEnvelopeCodec(),
    this.recordCodec = const LibraryRecordCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits();

  final JsonlLibraryEnvelopeCodec envelopeCodec;
  final LibraryRecordCodec recordCodec;
  final JsonlStorageLimits limits;

  Future<JsonlLibraryReplayResult> replay(
    LibraryId expectedId,
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
    LibraryRecord? record;
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
      final JsonlLibraryEnvelope envelope;
      try {
        envelope = envelopeCodec.decodeLine(line);
      } on Object {
        throw const JsonlReplayException('invalid envelope');
      }
      if (envelope.libraryId != expectedId.value) {
        throw const JsonlReplayException('library identity mismatch');
      }
      if (envelope.sequence != sequence + 1) {
        throw const JsonlReplayException('stream sequence mismatch');
      }
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
      final LibraryRecord decoded;
      try {
        decoded = recordCodec.decode(envelope.record);
      } on Object {
        throw const JsonlReplayException('record payload rejected');
      }
      if (decoded.libraryId != expectedId ||
          decoded.revision != envelope.recordRevision) {
        throw const JsonlReplayException('record identity mismatch');
      }
      record = decoded;
      revision = decoded.revision;
      sequence = envelope.sequence;
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
    return JsonlLibraryReplayResult(
      sequence: sequence,
      recordRevision: revision,
      record: record,
      validPrefix: bytes.sublist(0, completePrefixLength),
      needsRepair: fragmentLength > 0,
    );
  }
}

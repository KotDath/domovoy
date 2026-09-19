import 'dart:convert';
import 'dart:typed_data';

import '../../../core/projects/ids.dart';
import '../../../core/projects/record.dart';
import '../../agents/jsonl/jsonl_replay.dart';
import 'jsonl_project_envelope.dart';

final class JsonlProjectReplayResult {
  JsonlProjectReplayResult({
    required this.sequence,
    required this.recordRevision,
    required this.record,
    required this.isTombstone,
    required List<int> validPrefix,
    required this.needsRepair,
  }) : validPrefix = Uint8List.fromList(validPrefix);

  final int? sequence;
  final int? recordRevision;
  final ProjectRecord? record;
  final bool isTombstone;
  final Uint8List validPrefix;
  final bool needsRepair;
}

final class JsonlProjectReplay {
  JsonlProjectReplay({
    this.envelopeCodec = const JsonlProjectEnvelopeCodec(),
    this.recordCodec = const ProjectCodec(),
    JsonlStorageLimits? limits,
  }) : limits = limits ?? JsonlStorageLimits();

  final JsonlProjectEnvelopeCodec envelopeCodec;
  final ProjectCodec recordCodec;
  final JsonlStorageLimits limits;

  Future<JsonlProjectReplayResult> replay(
    ProjectId expectedId,
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
    ProjectRecord? record;
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
      final JsonlProjectEnvelope envelope;
      try {
        envelope = envelopeCodec.decodeLine(line);
      } on Object {
        throw const JsonlReplayException('invalid envelope');
      }
      if (envelope.projectId != expectedId) {
        throw const JsonlReplayException('project identity mismatch');
      }
      if (!sawEntry && envelope.operation == JsonlProjectOperation.delete) {
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
        if (envelope.operation == JsonlProjectOperation.upsert) {
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
          final ProjectRecord decoded;
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
    return JsonlProjectReplayResult(
      sequence: sawEntry ? sequence : null,
      recordRevision: revision,
      record: record,
      isTombstone: tombstone,
      validPrefix: bytes.sublist(0, completePrefixLength),
      needsRepair: fragmentLength > 0,
    );
  }
}

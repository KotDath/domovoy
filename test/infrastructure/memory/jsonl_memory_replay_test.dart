import 'dart:convert';

import 'package:domovoy/infrastructure/agents/jsonl/jsonl_replay.dart';
import 'package:domovoy/infrastructure/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

MemoryJsonlEnvelope _upsert(
  String recordId,
  int sequence,
  int expectedRevision,
  int revision, {
  MemoryJsonlStream stream = MemoryJsonlStream.working,
  Map<String, Object?> record = const <String, Object?>{'value': 1},
}) {
  return MemoryJsonlEnvelope(
    stream: stream,
    recordId: recordId,
    sequence: sequence,
    operation: MemoryJsonlOperation.upsert,
    expectedRevision: expectedRevision,
    recordRevision: revision,
    record: record,
  );
}

MemoryJsonlEnvelope _delete(
  String recordId,
  int sequence,
  int revision, {
  MemoryJsonlStream stream = MemoryJsonlStream.working,
}) {
  return MemoryJsonlEnvelope(
    stream: stream,
    recordId: recordId,
    sequence: sequence,
    operation: MemoryJsonlOperation.delete,
    expectedRevision: revision,
    recordRevision: revision,
  );
}

List<int> _encodeLines(
  List<MemoryJsonlEnvelope> envelopes, {
  String suffix = '',
}) {
  const codec = MemoryJsonlEnvelopeCodec();
  final buffer = StringBuffer();
  for (final envelope in envelopes) {
    buffer.write(codec.encodeLine(envelope));
  }
  buffer.write(suffix);
  return utf8.encode(buffer.toString());
}

Future<MemoryJsonlReplayResult> _replay(
  List<int> bytes, {
  MemoryJsonlStream stream = MemoryJsonlStream.working,
  String recordId = 'record-1',
}) {
  return MemoryJsonlReplay().replay(
    stream: stream,
    recordId: recordId,
    chunks: Stream<List<int>>.value(bytes),
  );
}

Matcher _replayFailure(String reason) => throwsA(
  isA<JsonlReplayException>().having((error) => error.reason, 'reason', reason),
);

void main() {
  group('MemoryJsonlKeyCodec', () {
    const codec = MemoryJsonlKeyCodec();

    test('round-trips every namespace', () {
      for (final stream in MemoryJsonlStream.values) {
        final key = codec.encode(stream, 'record with spaces/ü');
        expect(codec.isMemoryKey(key), isTrue);
        expect(codec.tryDecodeRecordId(stream, key), 'record with spaces/ü');
      }
    });

    test('isolates identical ids across namespaces', () {
      final keys = <String>{
        for (final stream in MemoryJsonlStream.values)
          codec.encode(stream, 'same-id'),
      };
      expect(keys, hasLength(MemoryJsonlStream.values.length));
    });

    test('rejects foreign and malformed keys', () {
      expect(codec.isMemoryKey('session-v1_abc'), isFalse);
      expect(codec.isMemoryKey('memory-v1_'), isFalse);
      expect(codec.isMemoryKey('memory-v1_x'), isFalse);
      expect(codec.isMemoryKey('memory-v1_zZm9v'), isFalse);
      expect(
        codec.tryDecodeRecordId(
          MemoryJsonlStream.working,
          codec.encode(MemoryJsonlStream.longTerm, 'id'),
        ),
        isNull,
      );
    });
  });

  group('MemoryJsonlEnvelopeCodec', () {
    const codec = MemoryJsonlEnvelopeCodec();

    test('round-trips upsert and delete envelopes', () {
      final upsert = _upsert('r1', 0, 0, 0);
      final delete = _delete('r1', 1, 0);
      expect(codec.decodeLine(codec.encodeLine(upsert)), upsert);
      expect(codec.decodeLine(codec.encodeLine(delete)), delete);
    });

    test('rejects unsupported envelope shapes', () {
      expect(
        () => codec.decodeLine('{"type":"other","version":1}'),
        throwsFormatException,
      );
      final upsert = _upsert('r1', 0, 0, 0);
      final json = Map<String, Object?>.from(upsert.toJson())..['extra'] = 1;
      expect(() => codec.decodeLine(jsonEncode(json)), throwsFormatException);
      final badStream = Map<String, Object?>.from(upsert.toJson())
        ..['stream'] = 'episodic';
      expect(
        () => codec.decodeLine(jsonEncode(badStream)),
        throwsFormatException,
      );
    });
  });

  group('MemoryJsonlReplay', () {
    test('accepts a growing revision chain', () async {
      final result = await _replay(
        _encodeLines([
          _upsert('record-1', 0, 0, 0, record: const {'value': 'first'}),
          _upsert('record-1', 1, 0, 1, record: const {'value': 'second'}),
        ]),
      );
      expect(result.sequence, 1);
      expect(result.recordRevision, 1);
      expect(result.record, {'value': 'second'});
      expect(result.isTombstone, isFalse);
      expect(result.needsRepair, isFalse);
    });

    test('accepts an initial tombstone and a delete after upsert', () async {
      final tombstoneOnly = await _replay(
        _encodeLines([_delete('record-1', 0, 0)]),
      );
      expect(tombstoneOnly.isTombstone, isTrue);
      expect(tombstoneOnly.record, isNull);

      final deleted = await _replay(
        _encodeLines([_upsert('record-1', 0, 0, 0), _delete('record-1', 1, 0)]),
      );
      expect(deleted.isTombstone, isTrue);
      expect(deleted.record, isNull);
      expect(deleted.recordRevision, 0);
    });

    test('rejects sequence, revision, and identity violations', () {
      expect(
        () => _replay(_encodeLines([_upsert('record-1', 0, 1, 1)])),
        _replayFailure('invalid initial revision'),
      );
      expect(
        () => _replay(
          _encodeLines([
            _upsert('record-1', 0, 0, 0),
            _upsert('record-1', 1, 0, 2),
          ]),
        ),
        _replayFailure('record revision mismatch'),
      );
      expect(
        () => _replay(
          _encodeLines([
            _upsert('record-1', 0, 0, 0),
            _upsert('record-1', 2, 0, 1),
          ]),
        ),
        _replayFailure('stream sequence mismatch'),
      );
      expect(
        () => _replay(_encodeLines([_upsert('other', 0, 0, 0)])),
        _replayFailure('stream identity mismatch'),
      );
      expect(
        () => _replay(
          _encodeLines([
            _upsert('record-1', 0, 0, 0, stream: MemoryJsonlStream.longTerm),
          ]),
        ),
        _replayFailure('stream identity mismatch'),
      );
      expect(
        () => _replay(
          _encodeLines([
            _upsert('record-1', 0, 0, 0),
            _delete('record-1', 1, 1),
          ]),
        ),
        _replayFailure('invalid delete transition'),
      );
    });

    test('repairs a truncated tail without losing the valid prefix', () async {
      final bytes = _encodeLines([
        _upsert('record-1', 0, 0, 0),
      ], suffix: '{"partial"');
      final result = await _replay(bytes);
      expect(result.needsRepair, isTrue);
      expect(result.record, {'value': 1});
      expect(result.validPrefix, hasLength(bytes.length - 10));

      final repaired = await _replay(result.validPrefix);
      expect(repaired.needsRepair, isFalse);
      expect(repaired.record, {'value': 1});
    });

    test('rejects malformed framing and payloads', () {
      expect(
        () => _replay(utf8.encode('{"not":"an envelope"}\n')),
        _replayFailure('invalid envelope'),
      );
      expect(
        () => _replay(<int>[0xff, 0x0a]),
        _replayFailure('entry is not valid UTF-8'),
      );
      expect(
        () => _replay(utf8.encode('no newline')),
        _replayFailure('stream has no complete entry'),
      );
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../../../core/llm/cancellation.dart';
import '../../../../core/research/research.dart';
import '../../../agents/jsonl/jsonl_stream_storage.dart';
import 'library_envelope.dart';
import 'library_limits.dart';
import 'library_replay.dart';

/// Clock used for `LibraryRecord.savedAt`.
abstract interface class LibraryClock {
  DateTime nowUtc();
}

/// Wall clock of the running application.
final class SystemLibraryClock implements LibraryClock {
  const SystemLibraryClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// Source of library record identities.
abstract interface class LibraryIdGenerator {
  LibraryId next();
}

/// Unpredictable default generator: 16 random bytes per record.
final class RandomLibraryIdGenerator implements LibraryIdGenerator {
  RandomLibraryIdGenerator([Random? random])
    : _random = random ?? Random.secure();

  final Random _random;

  @override
  LibraryId next() => LibraryId.generate(_random);
}

/// Versioned JSONL repository of the local research library.
///
/// One record lives in its own atomic JSONL stream keyed by its identity; the
/// stream is published through [JsonlStreamStorage], so the repository inherits
/// the project's atomic publish/replay boundary instead of inventing a file
/// path API. Records are immutable in v1: `save_digest` either appends a fresh
/// record or returns the existing record of the same `runId`.
final class JsonlLibraryStore implements LibraryRepository {
  JsonlLibraryStore({
    required this.storage,
    LibraryLimits? limits,
    LibraryClock? clock,
    LibraryIdGenerator? ids,
    this.recordCodec = const LibraryRecordCodec(),
    this.envelopeCodec = const JsonlLibraryEnvelopeCodec(),
  }) : limits = limits ?? const LibraryLimits(),
       clock = clock ?? const SystemLibraryClock(),
       ids = ids ?? RandomLibraryIdGenerator(),
       _coordinator = _JsonlLibraryStoreCoordinator() {
    replay = JsonlLibraryReplay(
      envelopeCodec: envelopeCodec,
      recordCodec: recordCodec,
      limits: this.limits.jsonlLimits,
    );
  }

  /// Opaque stream key of one record; derived from the identity, never from a
  /// caller-supplied path.
  static String streamKeyFor(LibraryId id) => id.value;

  final JsonlStreamStorage storage;
  final LibraryLimits limits;
  final LibraryClock clock;
  final LibraryIdGenerator ids;
  final LibraryRecordCodec recordCodec;
  final JsonlLibraryEnvelopeCodec envelopeCodec;
  final _JsonlLibraryStoreCoordinator _coordinator;
  late final JsonlLibraryReplay replay;

  @override
  Future<LibrarySaveResult> save({
    required String topic,
    required List<Paper> papers,
    required Digest digest,
    String? runId,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<LibrarySaveResult>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final candidate = LibraryRecord(
        libraryId: ids.next().value,
        runId: runId,
        topic: topic,
        papers: papers,
        digest: digest,
        savedAt: clock.nowUtc(),
      );
      _assertRecordFits(candidate);
      if (candidate.runId != null) {
        final existing = await _findByRunId(candidate.runId!, cancellation);
        if (existing != null) {
          if (existing.payloadFingerprint == candidate.payloadFingerprint) {
            return LibrarySaveResult(record: existing, created: false);
          }
          throwLibrary(
            LibraryErrorKind.conflict,
            'runId "${candidate.runId}" is already bound to record '
            '${existing.libraryId.value} with a different topic, paper '
            'snapshot or digest; nothing was written. Read the existing '
            'record with get_saved or retry with the original payload.',
          );
        }
      }
      final envelope = JsonlLibraryEnvelope(
        libraryId: candidate.libraryId.value,
        sequence: 0,
        operation: JsonlLibraryOperation.upsert,
        expectedRevision: 0,
        recordRevision: 0,
        record: recordCodec.encode(candidate),
      );
      final contents = _encode(envelope);
      _throwIfCancelled(cancellation);
      await _publish(candidate.libraryId.value, contents);
      return LibrarySaveResult(record: candidate, created: true);
    });
  }

  @override
  Future<LibraryRecord?> find(
    LibraryId id, {
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<LibraryRecord?>.error(_cancelledException());
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final state = await _read(id);
      _throwIfCancelled(cancellation);
      return state?.record;
    });
  }

  @override
  Future<LibraryPage> list({
    String? query,
    required int limit,
    String? cursor,
    required CancellationToken cancellation,
  }) {
    if (cancellation.isCancelled) {
      return Future<LibraryPage>.error(_cancelledException());
    }
    if (limit <= 0 || limit > limits.maxListLimit) {
      return Future<LibraryPage>.error(
        LibraryException(
          LibraryError(
            kind: LibraryErrorKind.invalidInput,
            message:
                'limit must be between 1 and ${limits.maxListLimit}; '
                'got $limit.',
          ),
        ),
      );
    }
    return _coordinator.run(() async {
      _throwIfCancelled(cancellation);
      final normalized = normalizeLibraryQuery(query);
      LibraryPageCursor? position;
      if (cursor != null) {
        position = LibraryPageCursor.tryDecode(cursor);
        if (position == null) {
          throwLibrary(
            LibraryErrorKind.invalidInput,
            'cursor is malformed; start a new listing without a cursor.',
          );
        }
        if (position.query != normalized) {
          throwLibrary(
            LibraryErrorKind.invalidInput,
            'cursor belongs to a different query; start a new listing.',
          );
        }
      }
      final records = await _readAll(cancellation);
      final matching =
          records
              .where((record) => _matchesQuery(record, normalized))
              .toList(growable: false)
            ..sort(compareLibraryRecordsDescending);
      final afterCursor = position == null
          ? matching
          : matching
                .where((record) => _isAfterCursor(record, position!))
                .toList(growable: false);
      final page = afterCursor.take(limit).toList(growable: false);
      final hasMore = afterCursor.length > page.length;
      final nextCursor = hasMore && page.isNotEmpty
          ? LibraryPageCursor(
              query: normalized,
              savedAt: page.last.savedAt,
              libraryId: page.last.libraryId,
            ).encode()
          : null;
      _throwIfCancelled(cancellation);
      return LibraryPage(
        cards: page.map(summarizeLibraryRecord).toList(growable: false),
        nextCursor: nextCursor,
        totalCount: matching.length,
      );
    });
  }

  Future<LibraryRecord?> _findByRunId(
    String runId,
    CancellationToken cancellation,
  ) async {
    final records = await _readAll(cancellation);
    for (final record in records) {
      if (record.runId == runId) {
        return record;
      }
    }
    return null;
  }

  Future<List<LibraryRecord>> _readAll(CancellationToken cancellation) async {
    final List<String> listed;
    try {
      listed = await storage.listKeys();
    } on Object {
      throw _persistence('library stream list could not be read.');
    }
    _throwIfCancelled(cancellation);
    final keys = listed.toSet().toList()..sort();
    final records = <LibraryRecord>[];
    for (final key in keys) {
      final id = LibraryId.tryParse(key);
      if (id == null) {
        throw _corruption(
          'library storage contains a stream that is not a library record.',
        );
      }
      final state = await _read(id);
      if (state?.record == null) {
        throw _corruption('library record ${id.value} has no complete entry.');
      }
      records.add(state!.record!);
    }
    return records;
  }

  Future<JsonlLibraryReplayResult?> _read(LibraryId id) async {
    final Stream<List<int>>? chunks;
    try {
      chunks = await storage.read(streamKeyFor(id));
    } on Object {
      throw _persistence('library record ${id.value} could not be read.');
    }
    if (chunks == null) {
      return null;
    }
    try {
      return await replay.replay(id, chunks);
    } on Object {
      throw _corruption(
        'library record ${id.value} is damaged and was not partially read.',
      );
    }
  }

  void _assertRecordFits(LibraryRecord record) {
    final recordBytes = utf8.encode(jsonEncode(record.toJson())).length;
    if (recordBytes > limits.maxRecordBytes) {
      throwLibrary(
        LibraryErrorKind.invalidInput,
        'Library record is $recordBytes bytes and exceeds the '
        '${limits.maxRecordBytes} byte limit; nothing was written.',
      );
    }
  }

  Uint8List _encode(JsonlLibraryEnvelope envelope) {
    final bytes = Uint8List.fromList(
      utf8.encode(envelopeCodec.encodeLine(envelope)),
    );
    final jsonl = limits.jsonlLimits;
    if (bytes.length - 1 > jsonl.maxEntryBytes ||
        bytes.length > jsonl.maxStreamBytes) {
      throwLibrary(
        LibraryErrorKind.invalidInput,
        'Library record does not fit the bounded JSONL stream; '
        'nothing was written.',
      );
    }
    return bytes;
  }

  Future<void> _publish(String key, List<int> contents) async {
    try {
      await storage.publish(key, List<int>.unmodifiable(contents));
    } on Object {
      throw _persistence('library record could not be published.');
    }
    try {
      await storage.cleanup(key);
    } on Object {
      // Cleanup is best effort after the active generation is selected.
    }
  }

  bool _matchesQuery(LibraryRecord record, String? query) {
    if (query == null) {
      return true;
    }
    final haystack = <String>[
      record.libraryId.value,
      if (record.runId != null) record.runId!,
      record.topic,
      record.digest.overview,
      for (final paper in record.papers) ...<String>[
        paper.arxivId.value,
        paper.title,
        ...paper.authors,
      ],
      for (final item in record.digest.items) ...<String>[
        item.arxivId.value,
        item.finding,
        if (item.limitation != null) item.limitation!,
      ],
    ].join('\n');
    return haystack.toLowerCase().contains(query);
  }

  bool _isAfterCursor(LibraryRecord record, LibraryPageCursor position) {
    if (record.savedAt.isBefore(position.savedAt)) {
      return true;
    }
    if (record.savedAt.isAfter(position.savedAt)) {
      return false;
    }
    return record.libraryId.value.compareTo(position.libraryId.value) < 0;
  }

  LibraryException _corruption(String message) => LibraryException(
    LibraryError(kind: LibraryErrorKind.corruption, message: message),
  );

  LibraryException _persistence(String message) => LibraryException(
    LibraryError(kind: LibraryErrorKind.persistence, message: message),
  );
}

final class _JsonlLibraryStoreCoordinator {
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

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throw _cancelledException();
  }
}

LibraryException _cancelledException() => LibraryException(
  LibraryError(kind: LibraryErrorKind.cancelled, message: 'cancelled'),
);

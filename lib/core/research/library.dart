import 'dart:convert';
import 'dart:math';

import '../llm/json.dart';
import 'digest.dart';
import 'errors.dart';
import 'library_errors.dart';
import 'paper.dart';

/// Version of the persisted library record contract (B5).
///
/// Bump only together with a replay/migration path: readers reject unknown
/// versions instead of partially accepting a new shape.
const libraryRecordSchemaVersion = 1;

final RegExp _libraryIdPattern = RegExp(r'^lib_[a-z0-9]{16,64}$');
final RegExp _controlCharacters = RegExp(r'[\u0000-\u001F\u007F]');

/// Normalized identity of one saved library record.
///
/// Generated identities are unpredictable (`lib_` plus 16 random bytes), so a
/// guessed or duplicated ID can never select someone else's record.
final class LibraryId {
  LibraryId(String raw) : value = _normalizeLibraryId(raw);

  factory LibraryId.fromJson(Object? json) {
    if (json is! String) {
      throwLibrary(LibraryErrorKind.invalidInput, 'libraryId must be text.');
    }
    return LibraryId(json);
  }

  /// Parses [raw] or returns null when it is not a library identity.
  static LibraryId? tryParse(String raw) {
    try {
      return LibraryId(raw);
    } on LibraryException {
      return null;
    }
  }

  /// Creates a fresh unpredictable identity from [random].
  static LibraryId generate(Random random) {
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return LibraryId('lib_$hex');
  }

  /// Identifier without decoration, for example `lib_4f2a...`.
  final String value;

  /// Stable local reference used by tool results and the library UI.
  String get recordRef => 'domovoy://library/$value';

  Map<String, Object?> toJson() =>
      freezeJsonMap(<String, Object?>{'libraryId': value});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LibraryId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

String _normalizeLibraryId(String raw) {
  final candidate = raw.trim();
  if (!_libraryIdPattern.hasMatch(candidate)) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'libraryId must look like lib_<hex>; got '
      '"${_clipForMessage(candidate)}".',
    );
  }
  return candidate;
}

/// One immutable saved digest with its paper snapshots and origin metadata.
///
/// The record is the only persisted representation of the library: it never
/// contains PDF bytes, provider credentials or arbitrary model text outside
/// the validated Digest v1 contract.
final class LibraryRecord {
  LibraryRecord({
    required String libraryId,
    String? runId,
    required String topic,
    required List<Paper> papers,
    required this.digest,
    required DateTime savedAt,
    int revision = 0,
  }) : libraryId = LibraryId(libraryId),
       runId = normalizeLibraryRunId(runId),
       topic = _requireTopic(topic),
       papers = List<Paper>.unmodifiable(papers),
       savedAt = savedAt.toUtc(),
       revision = _requireRevision(revision) {
    validateLibraryPayload(
      topic: this.topic,
      papers: this.papers,
      digest: digest,
    );
    payloadFingerprint = libraryPayloadFingerprint(
      topic: this.topic,
      papers: this.papers,
      digest: digest,
    );
  }

  factory LibraryRecord.fromJson(Object? json) {
    final map = _requireObject(json, 'library record');
    final version = map['schemaVersion'];
    if (version != libraryRecordSchemaVersion) {
      throwLibrary(
        LibraryErrorKind.versionMismatch,
        'Unsupported library record schemaVersion "$version".',
      );
    }
    final expected = <String>{
      'schemaVersion',
      'libraryId',
      'topic',
      'papers',
      'digest',
      'savedAt',
      'revision',
      if (map.containsKey('runId')) 'runId',
    };
    if (map.length != expected.length || !map.keys.every(expected.contains)) {
      throwLibrary(
        LibraryErrorKind.invalidInput,
        'Unexpected library record fields.',
      );
    }
    final rawPapers = map['papers'];
    if (rawPapers is! List || rawPapers.isEmpty) {
      throwLibrary(
        LibraryErrorKind.invalidInput,
        'Expected a non-empty "papers" list.',
      );
    }
    final papers = <Paper>[];
    for (final raw in rawPapers) {
      try {
        verifyPaperV1Fields(raw);
        papers.add(Paper.fromJson(raw));
      } on ResearchException catch (error) {
        throwLibrary(
          LibraryErrorKind.invalidInput,
          'Invalid paper snapshot: ${error.error.message}',
        );
      }
    }
    final Digest digest;
    try {
      verifyDigestV1Fields(map['digest']);
      digest = Digest.fromJson(map['digest']);
    } on ResearchException catch (error) {
      throwLibrary(
        error.error.kind == ResearchErrorKind.unsupportedVersion
            ? LibraryErrorKind.versionMismatch
            : LibraryErrorKind.invalidInput,
        'Invalid digest payload: ${error.error.message}',
      );
    }
    return LibraryRecord(
      libraryId: _requireText(map, 'libraryId'),
      runId: map['runId'] == null ? null : _requireText(map, 'runId'),
      topic: _requireText(map, 'topic'),
      papers: papers,
      digest: digest,
      savedAt: _requireUtcDate(map, 'savedAt'),
      revision: _requireNonNegativeInt(map, 'revision'),
    );
  }

  final LibraryId libraryId;

  /// Trusted run identity of the agent/scheduler invocation, when supplied.
  final String? runId;
  final String topic;
  final List<Paper> papers;
  final Digest digest;
  final DateTime savedAt;
  final int revision;

  /// Canonical payload identity used to detect a conflicting `runId` retry.
  ///
  /// Built from the trimmed topic, the paper snapshot as a set (order does not
  /// matter) and the complete Digest v1 payload. Equal fingerprints mean the
  /// same digest was requested for the same run, so the stored record can be
  /// returned without a duplicate write.
  late final String payloadFingerprint;

  String get recordRef => libraryId.recordRef;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'schemaVersion': libraryRecordSchemaVersion,
    'libraryId': libraryId.value,
    if (runId != null) 'runId': runId,
    'topic': topic,
    'papers': papers.map((paper) => paper.toJson()).toList(growable: false),
    'digest': digest.toJson(),
    'savedAt': savedAt.toIso8601String(),
    'revision': revision,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryRecord &&
          other.libraryId == libraryId &&
          other.runId == runId &&
          other.topic == topic &&
          _papersEqual(other.papers, papers) &&
          other.digest == digest &&
          other.savedAt == savedAt &&
          other.revision == revision;

  @override
  int get hashCode => Object.hash(
    libraryId,
    runId,
    topic,
    Object.hashAll(papers),
    digest,
    savedAt,
    revision,
  );

  @override
  String toString() =>
      'LibraryRecord(${libraryId.value}, "$topic", '
      '${papers.length} papers, rev=$revision)';
}

/// Compact card of one saved record, returned by `list_saved`.
final class LibraryCard {
  LibraryCard({
    required String libraryId,
    this.runId,
    required this.topic,
    required DateTime savedAt,
    required this.paperCount,
    required this.itemCount,
    required List<String> arxivIds,
  }) : libraryId = LibraryId(libraryId),
       savedAt = savedAt.toUtc(),
       arxivIds = List<String>.unmodifiable(arxivIds);

  final LibraryId libraryId;
  final String? runId;
  final String topic;
  final DateTime savedAt;
  final int paperCount;
  final int itemCount;
  final List<String> arxivIds;

  String get recordRef => libraryId.recordRef;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'libraryId': libraryId.value,
    if (runId != null) 'runId': runId,
    'topic': topic,
    'savedAt': savedAt.toIso8601String(),
    'paperCount': paperCount,
    'itemCount': itemCount,
    'arxivIds': arxivIds,
    'recordRef': recordRef,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryCard &&
          other.libraryId == libraryId &&
          other.runId == runId &&
          other.topic == topic &&
          other.savedAt == savedAt &&
          other.paperCount == paperCount &&
          other.itemCount == itemCount &&
          listEquals(other.arxivIds, arxivIds);

  @override
  int get hashCode => Object.hash(
    libraryId,
    runId,
    topic,
    savedAt,
    paperCount,
    itemCount,
    Object.hashAll(arxivIds),
  );

  @override
  String toString() =>
      'LibraryCard(${libraryId.value}, "$topic", $paperCount papers)';
}

/// Builds the compact card of [record] without loading the full payload.
LibraryCard summarizeLibraryRecord(LibraryRecord record) => LibraryCard(
  libraryId: record.libraryId.value,
  runId: record.runId,
  topic: record.topic,
  savedAt: record.savedAt,
  paperCount: record.papers.length,
  itemCount: record.digest.items.length,
  arxivIds: record.papers
      .map((paper) => paper.arxivId.value)
      .toList(growable: false),
);

/// Newest-first order of records: `savedAt` descending, identity as tiebreak.
///
/// The order never depends on a mutable offset, so a keyset cursor stays
/// stable when newer records are inserted between two pages.
int compareLibraryRecordsDescending(LibraryRecord left, LibraryRecord right) {
  final byTime = right.savedAt.compareTo(left.savedAt);
  if (byTime != 0) {
    return byTime;
  }
  return right.libraryId.value.compareTo(left.libraryId.value);
}

/// Newest-first order of cards; see [compareLibraryRecordsDescending].
int compareLibraryCardsDescending(LibraryCard left, LibraryCard right) {
  final byTime = right.savedAt.compareTo(left.savedAt);
  if (byTime != 0) {
    return byTime;
  }
  return right.libraryId.value.compareTo(left.libraryId.value);
}

/// Canonical payload identity of one save request.
///
/// The paper snapshot is treated as a set (order-insensitive); the digest
/// payload keeps its own item order, because the stored digest is the exact
/// validated Digest v1 value.
String libraryPayloadFingerprint({
  required String topic,
  required List<Paper> papers,
  required Digest digest,
}) {
  final sorted = List<Paper>.of(papers)..sort(_comparePaperSnapshots);
  return jsonEncode(<String, Object?>{
    'topic': topic.trim(),
    'papers': sorted.map((paper) => paper.toJson()).toList(growable: false),
    'digest': digest.toJson(),
  });
}

final class LibraryRecordCodec {
  const LibraryRecordCodec();

  Map<String, Object?> encode(LibraryRecord record) =>
      freezeJsonMap(record.toJson());

  LibraryRecord decode(Object? json) => LibraryRecord.fromJson(json);
}

int _comparePaperSnapshots(Paper left, Paper right) {
  final byId = left.arxivId.value.compareTo(right.arxivId.value);
  if (byId != 0) {
    return byId;
  }
  return (left.version ?? '').compareTo(right.version ?? '');
}

Map<String, Object?> _requireObject(Object? json, String label) {
  if (json is! Map) {
    throwLibrary(LibraryErrorKind.invalidInput, 'Expected a JSON object.');
  }
  final map = <String, Object?>{};
  json.forEach((key, value) {
    if (key is! String) {
      throwLibrary(
        LibraryErrorKind.invalidInput,
        'JSON keys of $label must be strings.',
      );
    }
    map[key] = value;
  });
  return map;
}

String _requireText(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'Expected string field "$key".',
    );
  }
  return value;
}

/// Validates the payload of one library record before an identity exists.
///
/// `save` calls this before comparing an existing `runId` or allocating a new
/// identity, so invalid input never burns an ID and never reports a conflict
/// for a payload that could not be stored at all. [LibraryRecord] calls the
/// same function from its constructor, so the tool boundary, the store and the
/// replay path share one contract.
void validateLibraryPayload({
  required String topic,
  required List<Paper> papers,
  required Digest digest,
}) {
  final normalizedTopic = _requireTopic(topic);
  if (papers.isEmpty) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'A library record requires at least one paper snapshot.',
    );
  }
  if (digest.topic != normalizedTopic) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'Library topic must match the digest topic.',
    );
  }
  final seen = <String>{};
  for (final paper in papers) {
    if (!seen.add(paper.arxivId.value)) {
      throwLibrary(
        LibraryErrorKind.invalidInput,
        'Paper snapshot ${paper.arxivId.value} is repeated; each normalized '
        'arXiv ID may appear once.',
      );
    }
  }
  try {
    verifyDigestItemsBelongToPapers(digest, papers);
  } on ResearchException catch (error) {
    throwLibrary(LibraryErrorKind.invalidInput, error.error.message);
  }
}

String _requireTopic(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'Expected a non-blank library topic.',
    );
  }
  return trimmed;
}

/// Normalizes a `runId` for idempotency comparison, or returns null.
///
/// A supplied `runId` is trimmed and must not contain control characters; the
/// same normalized value is used by the record, by the `runId` lookup and by
/// the conflict message, so a padded retry cannot create a duplicate record.
String? normalizeLibraryRunId(String? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'runId must be a non-blank string when supplied.',
    );
  }
  if (_controlCharacters.hasMatch(trimmed)) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'runId must not contain control characters.',
    );
  }
  return trimmed;
}

int _requireRevision(int value) {
  if (value < 0) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'Library record revision must be non-negative.',
    );
  }
  return value;
}

int _requireNonNegativeInt(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int || value < 0) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'Expected non-negative integer field "$key".',
    );
  }
  return value;
}

DateTime _requireUtcDate(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'Expected ISO 8601 text for "$key".',
    );
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throwLibrary(
      LibraryErrorKind.invalidInput,
      'Expected ISO 8601 text for "$key".',
    );
  }
  return parsed.toUtc();
}

bool _papersEqual(List<Paper> left, List<Paper> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

String _clipForMessage(String value) {
  if (value.length <= 64) {
    return value;
  }
  return '${value.substring(0, 64)}…';
}

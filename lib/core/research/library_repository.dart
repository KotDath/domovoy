import 'dart:convert';

import '../llm/cancellation.dart';
import 'digest.dart';
import 'library.dart';
import 'paper.dart';

/// One bounded page of saved library records.
final class LibraryPage {
  LibraryPage({
    required List<LibraryCard> cards,
    this.nextCursor,
    required this.totalCount,
  }) : cards = List<LibraryCard>.unmodifiable(cards) {
    if (totalCount < 0) {
      throw ArgumentError.value(
        totalCount,
        'totalCount',
        'Library page total must be non-negative.',
      );
    }
  }

  /// Cards of this page in stable newest-first order.
  final List<LibraryCard> cards;

  /// Opaque keyset cursor for the next page, or null on the last page.
  final String? nextCursor;

  /// Number of matching records before pagination.
  final int totalCount;
}

/// Result of one idempotent `save_digest` call.
final class LibrarySaveResult {
  const LibrarySaveResult({required this.record, required this.created});

  final LibraryRecord record;

  /// True when a new record was written, false when an existing `runId`
  /// returned its original record without a duplicate write.
  final bool created;
}

/// Opaque keyset cursor of `list_saved`.
///
/// The cursor stores the exact `(savedAt, libraryId)` position of the last
/// returned card plus the normalized query it belongs to. Pagination therefore
/// never depends on a mutable offset: inserting newer records between two
/// pages cannot shift, skip or duplicate an older page. Using the cursor with
/// a different query is rejected instead of silently mixing two result sets.
final class LibraryPageCursor {
  LibraryPageCursor({
    required this.query,
    required this.savedAt,
    required this.libraryId,
  });

  static const version = 1;

  /// Normalized query the cursor was issued for, or null when unfiltered.
  final String? query;

  /// `savedAt` of the last card of the previous page, in UTC.
  final DateTime savedAt;

  /// Identity of the last card of the previous page.
  final LibraryId libraryId;

  String encode() => base64Url.encode(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'v': version,
        'q': query,
        't': savedAt.toUtc().toIso8601String(),
        'id': libraryId.value,
      }),
    ),
  );

  /// Decodes [value] or returns null when the cursor is malformed.
  static LibraryPageCursor? tryDecode(String value) {
    try {
      final decoded = utf8.decode(base64Url.decode(value));
      final raw = jsonDecode(decoded);
      if (raw is! Map) {
        return null;
      }
      final map = <String, Object?>{};
      raw.forEach((key, nested) {
        if (key is! String) {
          throw const FormatException('cursor keys must be strings');
        }
        map[key] = nested;
      });
      const expectedKeys = <String>{'v', 'q', 't', 'id'};
      if (map.length != expectedKeys.length ||
          !map.keys.every(expectedKeys.contains) ||
          map['v'] != version) {
        return null;
      }
      final query = map['q'];
      if (query != null && query is! String) {
        return null;
      }
      final savedAt = map['t'];
      if (savedAt is! String) {
        return null;
      }
      final parsed = DateTime.tryParse(savedAt);
      if (parsed == null) {
        return null;
      }
      final id = map['id'];
      if (id is! String) {
        return null;
      }
      final libraryId = LibraryId.tryParse(id);
      if (libraryId == null) {
        return null;
      }
      return LibraryPageCursor(
        query: query as String?,
        savedAt: parsed.toUtc(),
        libraryId: libraryId,
      );
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibraryPageCursor &&
          other.query == query &&
          other.savedAt == savedAt &&
          other.libraryId == libraryId;

  @override
  int get hashCode => Object.hash(query, savedAt, libraryId);

  @override
  String toString() =>
      'LibraryPageCursor(${libraryId.value}, ${savedAt.toIso8601String()})';
}

/// Normalizes a free-text library query for matching and cursor binding.
///
/// Blank input means "no filter"; otherwise the query is trimmed and
/// lower-cased so matching stays case-insensitive.
String? normalizeLibraryQuery(String? raw) {
  if (raw == null) {
    return null;
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  return trimmed.toLowerCase();
}

/// Domain contract of the one and only local library owner.
///
/// The `library` MCP server and, through it, the library UI read the same
/// repository: there is no second copy of the library in the application.
abstract interface class LibraryRepository {
  /// Saves one validated digest idempotently.
  ///
  /// With a [runId], an existing record with the same canonical payload is
  /// returned unchanged (`created: false`); a different payload for the same
  /// `runId` is an explicit conflict. Without a [runId] every call creates a
  /// fresh record with a new identity.
  Future<LibrarySaveResult> save({
    required String topic,
    required List<Paper> papers,
    required Digest digest,
    String? runId,
    required CancellationToken cancellation,
  });

  /// Returns the full record, or null when [id] is unknown.
  Future<LibraryRecord?> find(
    LibraryId id, {
    required CancellationToken cancellation,
  });

  /// Returns one bounded newest-first page, optionally filtered by [query].
  Future<LibraryPage> list({
    String? query,
    required int limit,
    String? cursor,
    required CancellationToken cancellation,
  });
}

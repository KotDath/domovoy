import '../../../../core/mcp/mcp.dart';
import '../../../agents/jsonl/jsonl_replay.dart';

/// Hard limits enforced by the local `library` MCP server and its JSONL store.
///
/// The limits bound every dimension of one saved record: number of paper
/// snapshots, topic/runId text, serialized paper, digest and record bytes, the
/// JSONL stream sizes, and the `list_saved` query/limit/cursor. They protect
/// the app from hostile input and from a runaway record, and they are
/// validated once so a misconfigured composition fails at construction.
final class LibraryLimits {
  const LibraryLimits({
    this.minPapers = 1,
    this.maxPapers = 10,
    this.maxTopicCharacters = 500,
    this.maxRunIdCharacters = 128,
    this.maxQueryCharacters = 200,
    this.maxCursorCharacters = 1024,
    this.defaultListLimit = 20,
    this.maxListLimit = 50,
    this.maxPaperBytes = 16384,
    this.maxPapersBytes = 65536,
    this.maxDigestBytes = 65536,
    this.maxRecordBytes = 262144,
    this.maxStreamBytes = 524288,
  });

  /// Smallest accepted number of paper snapshots in one record.
  final int minPapers;

  /// Largest accepted number of paper snapshots in one record.
  final int maxPapers;

  final int maxTopicCharacters;
  final int maxRunIdCharacters;
  final int maxQueryCharacters;
  final int maxCursorCharacters;

  /// Page size used by `list_saved` when the caller omits `limit`.
  final int defaultListLimit;

  /// Largest accepted `list_saved` page size.
  final int maxListLimit;

  /// Byte cap for one serialized Paper v1 snapshot.
  final int maxPaperBytes;

  /// Byte cap for all serialized Paper v1 snapshots of one record.
  final int maxPapersBytes;

  /// Byte cap for the serialized Digest v1 payload of one record.
  final int maxDigestBytes;

  /// Byte cap for the complete serialized library record.
  final int maxRecordBytes;

  /// Byte cap for one JSONL stream (a record plus its revisions).
  final int maxStreamBytes;

  /// Headroom reserved for the JSONL envelope around [maxRecordBytes].
  static const envelopeHeadroomBytes = 4096;

  /// JSONL storage limits derived from the record limits.
  ///
  /// One entry carries the envelope plus the record payload; the whole stream
  /// stays bounded so a corrupted or hostile file cannot exhaust memory.
  JsonlStorageLimits get jsonlLimits => JsonlStorageLimits(
    maxEntryBytes: maxRecordBytes + envelopeHeadroomBytes,
    maxStreamBytes: maxStreamBytes,
  );

  /// Validates cross-field invariants; returns `this` when acceptable.
  LibraryLimits validate() {
    void positive(String name, int value) {
      if (value <= 0) {
        throwMcp(
          McpErrorKind.configuration,
          'Library limit "$name" must be positive.',
        );
      }
    }

    positive('minPapers', minPapers);
    positive('maxPapers', maxPapers);
    if (minPapers > maxPapers) {
      throwMcp(
        McpErrorKind.configuration,
        'Library limit "minPapers" must not exceed "maxPapers".',
      );
    }
    positive('maxTopicCharacters', maxTopicCharacters);
    positive('maxRunIdCharacters', maxRunIdCharacters);
    positive('maxQueryCharacters', maxQueryCharacters);
    positive('maxCursorCharacters', maxCursorCharacters);
    positive('defaultListLimit', defaultListLimit);
    positive('maxListLimit', maxListLimit);
    if (defaultListLimit > maxListLimit) {
      throwMcp(
        McpErrorKind.configuration,
        'Library limit "defaultListLimit" must not exceed "maxListLimit".',
      );
    }
    positive('maxPaperBytes', maxPaperBytes);
    positive('maxPapersBytes', maxPapersBytes);
    positive('maxDigestBytes', maxDigestBytes);
    positive('maxRecordBytes', maxRecordBytes);
    positive('maxStreamBytes', maxStreamBytes);
    if (maxPapersBytes < maxPaperBytes) {
      throwMcp(
        McpErrorKind.configuration,
        'Library limit "maxPapersBytes" must not be smaller than '
        '"maxPaperBytes".',
      );
    }
    if (maxPapersBytes > maxRecordBytes || maxDigestBytes > maxRecordBytes) {
      throwMcp(
        McpErrorKind.configuration,
        'Library limits "maxPapersBytes" and "maxDigestBytes" must not '
        'exceed "maxRecordBytes".',
      );
    }
    if (maxRecordBytes + envelopeHeadroomBytes > maxStreamBytes) {
      throwMcp(
        McpErrorKind.configuration,
        'Library limit "maxStreamBytes" must hold the largest record plus '
        'the JSONL envelope headroom.',
      );
    }
    return this;
  }
}

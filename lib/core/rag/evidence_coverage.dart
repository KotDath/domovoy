import 'models.dart';

/// Exact union coverage against revision-aware source coordinates. Separate
/// chunks may cover one span; overlaps never count as multiple evidence units.
bool ragEvidenceCoversSpan({
  required String documentId,
  required String revision,
  required int start,
  required int end,
  required Iterable<RagChunk> chunks,
}) {
  if (start < 0 || end <= start) throw ArgumentError('Invalid evidence span');
  var cursor = start;
  final matching =
      chunks
          .where(
            (c) => c.documentId == documentId && c.documentRevision == revision,
          )
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));
  for (final chunk in matching) {
    if (chunk.start > cursor) break;
    if (chunk.end > cursor) cursor = chunk.end;
    if (cursor >= end) return true;
  }
  return false;
}

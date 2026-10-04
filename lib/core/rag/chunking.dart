import 'dart:math';

import '../llm/cancellation.dart';
import 'contracts.dart';
import 'models.dart';

/// Chunk boundaries are chosen in Dart using real tokenizer offsets.
final class RagChunker {
  const RagChunker(this.models, {this.target = 384, this.overlap = 64});
  final RagModelProvider models;
  final int target;
  final int overlap;

  Future<List<RagChunk>> split(
    RagDocument doc,
    ChunkStrategy strategy,
    CancellationToken cancellation,
  ) async {
    if (target <= 0 || overlap < 0 || overlap >= target) {
      throw ArgumentError('Invalid chunking configuration');
    }
    checkRagCancellation(cancellation.isCancelled);
    final tokens = await models.tokenize(doc.text, cancellation);
    if (tokens.isEmpty) return [];
    final chunks = <RagChunk>[];
    final sections = strategy == ChunkStrategy.fixed
        ? [_Section(0, doc.text.length, doc.title)]
        : _sections(doc);
    for (final section in sections) {
      final inSection = tokens
          .where((t) => t.start < section.end && t.end > section.start)
          .toList();
      if (inSection.isEmpty) continue;
      final boundaries = _blockEnds(doc.text, section);
      var cursor = 0;
      while (cursor < inSection.length) {
        checkRagCancellation(cancellation.isCancelled);
        var until = min(cursor + target, inSection.length);
        if (strategy == ChunkStrategy.structure && until < inSection.length) {
          for (var n = until; n > cursor + overlap; n--) {
            final end = inSection[n - 1].end;
            // A whole block fits only if no token crosses its boundary.
            if (boundaries.any((b) => end <= b && inSection[n].start >= b)) {
              until = n;
              break;
            }
          }
        }
        final start = max(section.start, inSection[cursor].start);
        var end = min(section.end, inSection[until - 1].end);
        if (end > start && doc.text.substring(start, end).trim().isNotEmpty) {
          var actual = await models.tokenize(
            doc.text.substring(start, end),
            cancellation,
          );
          var rankTokens = await models.tokenize(
            doc.text.substring(start, end),
            cancellation,
            reranker: true,
          );
          // BGE v2-m3 pair budget: 8192; reserve 1024 query + 4 specials.
          const rankPassageLimit = 7164;
          while ((actual.length > target ||
                  rankTokens.length > rankPassageLimit) &&
              until > cursor + 1) {
            until = max(
              cursor + 1,
              until -
                  max(
                    1,
                    max(
                      actual.length - target,
                      (rankTokens.length - rankPassageLimit) ~/ 4,
                    ),
                  ),
            );
            end = min(section.end, inSection[until - 1].end);
            actual = await models.tokenize(
              doc.text.substring(start, end),
              cancellation,
            );
            rankTokens = await models.tokenize(
              doc.text.substring(start, end),
              cancellation,
              reranker: true,
            );
          }
          if (actual.length > target || rankTokens.length > rankPassageLimit) {
            throw const FormatException(
              'A tokenizer unit exceeds chunk budget',
            );
          }
          final chunk = _chunk(
            doc,
            strategy,
            section,
            chunks.length,
            start,
            end,
            actual.length,
            until < inSection.length &&
                !boundaries.any((b) => end <= b && inSection[until].start >= b),
          );
          if (!chunks.any((existing) => existing.id == chunk.id)) {
            chunks.add(chunk);
          }
        }
        if (until == inSection.length) break;
        cursor = max(cursor + 1, until - overlap);
      }
    }
    return chunks;
  }

  RagChunk _chunk(
    RagDocument doc,
    ChunkStrategy strategy,
    _Section section,
    int ordinal,
    int start,
    int end,
    int count,
    bool forced,
  ) => RagChunk(
    documentId: doc.id,
    documentRevision: doc.revision,
    source: doc.source,
    title: doc.title,
    section: section.title,
    start: start,
    end: end,
    text: doc.text.substring(start, end),
    strategy: strategy,
    tokens: count,
    ordinal: ordinal,
    config: 'v1-$target-$overlap',
    pageStart: doc.pageAt(start),
    pageEnd: doc.pageAt(end - 1),
    forcedSplit: strategy == ChunkStrategy.structure && forced,
  );

  /// End coordinates of paragraphs, list groups, tables and fenced code.
  /// A fitting block is never cut just because one of its lines ends.
  List<int> _blockEnds(String text, _Section section) {
    final lines = text.substring(section.start, section.end).split('\n');
    final ends = <int>[];
    var offset = section.start;
    String? fence;
    String? kind;
    for (final line in lines) {
      final trimmed = line.trimLeft();
      final marker = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed);
      if (fence != null) {
        offset = min(section.end, offset + line.length + 1);
        if (marker != null &&
            marker.group(1)![0] == fence[0] &&
            marker.group(1)!.length >= fence.length) {
          fence = null;
          ends.add(offset);
          kind = null;
        }
        continue;
      }
      final next = marker != null
          ? 'code'
          : trimmed.isEmpty
          ? 'blank'
          : RegExp(r'^(?:[-*+] |\d+[.)] )').hasMatch(trimmed)
          ? 'list'
          : trimmed.contains('|')
          ? 'table'
          : trimmed.startsWith('#')
          ? 'heading'
          : 'paragraph';
      // Indented continuation lines remain attached to lists.
      final continuation =
          kind == 'list' && line.startsWith('  ') && next == 'paragraph';
      if (kind != null && next != kind && !continuation) ends.add(offset);
      offset = min(section.end, offset + line.length + 1);
      if (marker != null) fence = marker.group(1);
      if (!continuation) kind = next;
      if (next == 'blank' || next == 'heading') {
        ends.add(offset);
        kind = null;
      }
    }
    ends.add(section.end);
    return ends.toSet().toList()..sort();
  }

  List<_Section> _sections(RagDocument doc) {
    final boundaries = <(int, String)>[(0, doc.title)];
    var offset = 0;
    String? fence;
    final path = <String>[];
    for (final line in doc.text.split('\n')) {
      final trimmed = line.trimLeft();
      final marker = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed);
      if (marker != null) {
        final value = marker.group(1)!;
        if (fence == null) {
          fence = value;
        } else if (value[0] == fence[0] && value.length >= fence.length) {
          fence = null;
        }
      } else if (fence == null) {
        final heading = RegExp(r'^(#{1,6})\s+(.+?)\s*#*\s*$').firstMatch(line);
        final pdfHeading = doc.pageStarts.isNotEmpty && line.length < 120
            ? RegExp(
                r'^(?:(\d{1,2}(?:\.\d{1,2})*)\.?\s+[A-Z][^.]{1,100}|Abstract|Introduction|Conclusion[s]?)$',
              ).firstMatch(line.trim())
            : null;
        if (heading != null || pdfHeading != null) {
          final depth =
              heading?.group(1)?.length ??
              (pdfHeading?.group(1)?.split('.').length ?? 1);
          while (path.length >= depth) {
            path.removeLast();
          }
          path.add(heading?.group(2) ?? line.trim());
          if (offset == 0) {
            boundaries[0] = (0, path.join(' / '));
          } else {
            boundaries.add((offset, path.join(' / ')));
          }
        }
      }
      offset += line.length + 1;
    }
    return [
      for (var i = 0; i < boundaries.length; i++)
        _Section(
          boundaries[i].$1,
          i + 1 < boundaries.length ? boundaries[i + 1].$1 : doc.text.length,
          boundaries[i].$2,
        ),
    ];
  }
}

final class _Section {
  const _Section(this.start, this.end, this.title);
  final int start;
  final int end;
  final String title;
}

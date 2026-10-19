import 'dart:convert';

import '../../../core/llm/cancellation.dart';
import '../../../core/rag/contracts.dart';
import '../../../core/rag/models.dart';
import '../../../core/rag/turn.dart';

/// Support-only coverage around actual admitted dense hits. Never recursively
/// expands supplemental chunks or reads the mutable active index pointer.
final class SupportEvidenceContext {
  SupportEvidenceContext._(
    this.turn,
    List<_Neighbor> neighbors,
    List<Map<String, Object?>> decisions,
  ) : _neighbors = List.unmodifiable(neighbors),
      _decisions = List.unmodifiable(
        decisions.map((d) => Map<String, Object?>.unmodifiable(d)),
      );

  final RagPreparedTurn turn;
  final List<_Neighbor> _neighbors;
  final List<Map<String, Object?>> _decisions;

  // ragEvidenceContext serializes only chunk data, never the placeholder score.
  String get context => _context(turn, _neighbors);

  Map<String, Object?> toJson() => {
    ...turn.toJson(),
    'context': context,
    'context_bytes': utf8.encode(context).length,
    'support_expansion': {
      'policy': 'immediate_document_neighbors_v1',
      'generation': turn.generation,
      'max_chunks': 10,
      'max_added_context_bytes': 8000,
      'order': 'dense seed rank; next then previous; no recursion',
      'decisions': _decisions,
    },
    'final_evidence_ids': [
      for (final hit in turn.evidence) hit.chunk.id,
      for (final neighbor in _neighbors) neighbor.chunk.id,
    ],
    'candidates': [
      ...turn.toJson()['candidates'] as List,
      for (final neighbor in _neighbors)
        {
          'chunk': neighbor.chunk.toJson(),
          'dense_rank': null,
          'rerank_rank': null,
          'cosine': null,
          'rerank': null,
          'sent': true,
          'excluded_reason': null,
          'retrieval_kind': 'support_document_neighbor',
          'seed_chunk_id': neighbor.seedId,
          'neighbor_direction': neighbor.direction,
          'generation': turn.generation,
        },
    ],
  };
}

final class _Neighbor {
  const _Neighbor(this.chunk, this.seedId, this.direction);
  final RagChunk chunk;
  final String seedId, direction;
}

String _context(RagPreparedTurn turn, List<_Neighbor> neighbors) =>
    neighbors.isEmpty
    ? turn.context
    : ragEvidenceContext([
        ...turn.evidence,
        for (final neighbor in neighbors) RagHit(neighbor.chunk, 0),
      ]);

Future<SupportEvidenceContext> expandSupportEvidence(
  RagRepository repository,
  RagPreparedTurn turn,
  CancellationToken cancellation,
) async {
  void check() => checkRagCancellation(cancellation.isCancelled);
  check();
  if (turn.request.protocol != RagProtocol.m1 || turn.generation == null) {
    throw StateError('Support requires frozen M1 evidence');
  }
  final index = await repository.loadGeneration(
    turn.request.project,
    turn.request.corpus,
    turn.generation!,
  );
  check();
  if (index == null ||
      index.generation != turn.generation ||
      index.fingerprint != turn.fingerprint ||
      index.strategy != turn.request.strategy) {
    throw StateError('Frozen support index is unavailable or changed');
  }
  final baseBytes = utf8.encode(turn.context).length;
  if (baseBytes > turn.request.contextByteBudget) {
    throw StateError('Support evidence exceeds context budget');
  }
  final chunks = {for (final chunk in index.chunks) chunk.id: chunk};
  final neighbors = <_Neighbor>[];
  final decisions = <Map<String, Object?>>[];
  final sent = {for (final hit in turn.evidence) hit.chunk.id};
  for (final seed in turn.evidence) {
    check();
    final chunk = chunks[seed.chunk.id];
    if (chunk == null ||
        jsonEncode(chunk.toJson()) != jsonEncode(seed.chunk.toJson())) {
      throw StateError('Dense support evidence differs from frozen index');
    }
    final siblings =
        index.chunks
            .where(
              (c) =>
                  c.documentId == chunk.documentId &&
                  c.documentRevision == chunk.documentRevision &&
                  c.source == chunk.source,
            )
            .toList()
          ..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final position = siblings.indexWhere((c) => c.id == chunk.id);
    for (final offset in [1, -1]) {
      check();
      final adjacent = position + offset;
      if (adjacent < 0 || adjacent >= siblings.length) continue;
      final candidate = siblings[adjacent];
      final decision = <String, Object?>{
        'chunk_id': candidate.id,
        'seed_chunk_id': chunk.id,
        'direction': offset == 1 ? 'next' : 'previous',
      };
      decisions.add(decision);
      if (sent.contains(candidate.id)) {
        decision['result'] = 'already_sent';
        continue;
      }
      if (neighbors.length >= 10) {
        decision['result'] = 'chunk_limit';
        continue;
      }
      final neighbor = _Neighbor(
        candidate,
        chunk.id,
        offset == 1 ? 'next' : 'previous',
      );
      final bytes = utf8
          .encode(_context(turn, [...neighbors, neighbor]))
          .length;
      decision['trial_context_bytes'] = bytes;
      // Includes JSON escaping, metadata, separators and envelope; dense hits
      // always retain their admission and order, even under a tight budget.
      if (bytes > turn.request.contextByteBudget) {
        decision['result'] = 'context_budget';
        continue;
      }
      if (bytes - baseBytes > 8000) {
        decision['result'] = 'supplemental_byte_limit';
        continue;
      }
      decision['result'] = 'sent';
      neighbors.add(neighbor);
      sent.add(candidate.id);
    }
  }
  check();
  return SupportEvidenceContext._(turn, neighbors, decisions);
}

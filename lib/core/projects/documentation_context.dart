import 'dart:convert';

import '../llm/cancellation.dart';
import '../rag/models.dart';
import '../rag/turn.dart';

/// Actual dense retrieval plus a small navigation anchor from the project's
/// root README. Generic overview questions otherwise often retrieve only short
/// section headings. All excerpts come from the same frozen index generation.
final class ProjectDocumentationContext {
  ProjectDocumentationContext({required this.turn, required this.overview});
  final RagPreparedTurn turn;
  final List<RagHit> overview;
  String get context => ragEvidenceContext([...overview, ...turn.evidence]);
  Map<String, Object?> toJson() => {
    ...turn.toJson(),
    'context': context,
    'context_bytes': utf8.encode(context).length,
    'overview_policy':
        'first two chunks per root README; 8000 UTF-8 bytes; same generation',
    'final_evidence_ids': [
      for (final hit in [...overview, ...turn.evidence]) hit.chunk.id,
    ],
    'candidates': [
      ...turn.toJson()['candidates'] as List,
      for (final hit in overview)
        if (!turn.candidates.any((c) => c.chunk.id == hit.chunk.id))
          {
            'chunk': hit.chunk.toJson(),
            'sent': true,
            'dense_rank': null,
            'cosine': null,
            'retrieval_kind': 'project_readme_overview',
          },
    ],
  };
}

Future<ProjectDocumentationContext> prepareProjectDocumentationContext(
  RagTurnCoordinator coordinator,
  RagTurnRequest request,
  CancellationToken cancellation,
) async {
  final turn = await coordinator.prepare(request, cancellation);
  final index = await coordinator.repository.loadGeneration(
    request.project,
    request.corpus,
    turn.generation!,
  );
  checkRagCancellation(cancellation.isCancelled);
  if (index == null) throw StateError('Frozen project index is unavailable');
  final overview = <RagHit>[];
  var bytes = 0;
  final ordinals = <String, int>{};
  for (final chunk in index.chunks) {
    if (chunk.source.contains('/') ||
        !RegExp(
          r'^readme(?:\.[a-z0-9_-]+)*$',
          caseSensitive: false,
        ).hasMatch(chunk.source)) {
      continue;
    }
    final ordinal = ordinals.update(
      chunk.source,
      (n) => n + 1,
      ifAbsent: () => 1,
    );
    if (ordinal > 2 || turn.evidence.any((h) => h.chunk.id == chunk.id)) {
      continue;
    }
    final length = utf8.encode(chunk.text).length;
    if (bytes + length > 8000) continue;
    final hit = RagHit(chunk, 0); // Navigation evidence has no dense score.
    if (utf8
            .encode(ragEvidenceContext([...overview, hit, ...turn.evidence]))
            .length >
        request.contextByteBudget) {
      continue;
    }
    overview.add(hit);
    bytes += length;
  }
  return ProjectDocumentationContext(
    turn: turn,
    overview: List.unmodifiable(overview),
  );
}

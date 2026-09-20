import '../llm/cancellation.dart';
import 'context.dart';
import 'enums.dart';
import 'entry.dart';
import 'render.dart';
import 'repository.dart';
import 'service.dart';

/// Deterministic project/global retrieval over the confirmed memory stores.
///
/// Working records are project-scoped, long-term records are user-global.
/// Retrieval performs no provider call, never mutates storage, and returns an
/// exact [MemoryContextTrace] of what was and was not supplied.
final class LayeredMemoryRetrievalService implements MemoryRetrievalService {
  LayeredMemoryRetrievalService({required this.repositories});

  final MemoryRepositories repositories;

  @override
  Future<MemoryReadPlan> planRead(MemoryReadRequest request) async {
    final cancellation = CancellationSource().token;
    final working = await repositories.workingRepository.list(
      projectId: request.projectId,
      includeForgotten: true,
      cancellation: cancellation,
    );
    final longTerm = await repositories.longTermRepository.list(
      includeForgotten: true,
      cancellation: cancellation,
    );

    final considered = <_PlannedEntry>[];
    final excluded = <MemoryTraceRecord>[];

    for (final entry in _sortedById(working)) {
      if (entry.isForgotten) {
        excluded.add(_trace(entry, MemoryReadReason.forgotten));
      } else if (!request.includeWorking) {
        excluded.add(_trace(entry, MemoryReadReason.layerDisabled));
      } else {
        considered.add(_PlannedEntry(entry, MemoryReadReason.workingPriority));
      }
    }

    final lexical = <MemoryEntry>[];
    for (final entry in _sortedById(longTerm)) {
      if (entry.isForgotten) {
        excluded.add(_trace(entry, MemoryReadReason.forgotten));
      } else if (!request.includeLongTerm) {
        excluded.add(_trace(entry, MemoryReadReason.layerDisabled));
      } else if (entry.kind == MemoryKind.preference) {
        // Confirmed preferences are always eligible and are not subject to the
        // long-term lexical cap.
        considered.add(
          _PlannedEntry(entry, MemoryReadReason.confirmedPreference),
        );
      } else {
        lexical.add(entry);
      }
    }

    final ranked =
        lexical
            .map(
              (entry) => (
                entry: entry,
                score: memoryLexicalScore(request.query, entry.content),
              ),
            )
            .toList()
          ..sort((left, right) {
            final byScore = right.score.compareTo(left.score);
            if (byScore != 0) {
              return byScore;
            }
            return left.entry.id.value.compareTo(right.entry.id.value);
          });
    for (var index = 0; index < ranked.length; index += 1) {
      final entry = ranked[index].entry;
      if (ranked[index].score > 0 && index < request.maxLongTermRecords) {
        considered.add(_PlannedEntry(entry, MemoryReadReason.lexicalMatch));
      } else {
        excluded.add(_trace(entry, MemoryReadReason.notSelected));
      }
    }

    considered.sort(
      (left, right) => compareMemoryReadPlanItems(left.item, right.item),
    );

    var used = memorySystemPromptOverheadRunes;
    final items = <MemoryReadPlanItem>[];
    final trace = <MemoryTraceRecord>[];
    for (final planned in considered) {
      final rendered = memoryItemRenderedRunes(
        layer: planned.entry.layer,
        kind: planned.entry.kind,
        content: planned.entry.content,
      );
      if (used + rendered <= request.characterBudget) {
        used += rendered;
        items.add(planned.item);
        trace.add(planned.trace());
      } else {
        trace.add(planned.trace(reason: MemoryReadReason.budgetExceeded));
      }
    }
    trace.addAll(excluded);
    trace.sort(compareMemoryTraceRecords);
    return MemoryReadPlan(request: request, items: items, trace: trace);
  }
}

/// Deterministic lexical score: the number of distinct query terms present in
/// [content]. No stemming, embeddings, or provider calls are involved.
int memoryLexicalScore(String query, String content) {
  final terms = memoryQueryTerms(query);
  if (terms.isEmpty) {
    return 0;
  }
  final haystack = content.toLowerCase();
  var score = 0;
  for (final term in terms) {
    if (haystack.contains(term)) {
      score += 1;
    }
  }
  return score;
}

final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// Lowercased, deduplicated, sorted query terms.
List<String> memoryQueryTerms(String query) {
  final terms = <String>{};
  for (final match in _wordPattern.allMatches(query.toLowerCase())) {
    terms.add(match.group(0)!);
  }
  final sorted = terms.toList()..sort();
  return List<String>.unmodifiable(sorted);
}

List<MemoryEntry> _sortedById(List<MemoryEntry> entries) {
  return List<MemoryEntry>.from(entries)
    ..sort((left, right) => left.id.value.compareTo(right.id.value));
}

final class _PlannedEntry {
  const _PlannedEntry(this.entry, this.reason);

  final MemoryEntry entry;
  final MemoryReadReason reason;

  MemoryReadPlanItem get item => MemoryReadPlanItem(
    entryId: entry.id,
    revision: entry.revision,
    layer: entry.layer,
    scope: entry.scope,
    kind: entry.kind,
    content: entry.content,
    reason: reason,
  );

  MemoryTraceRecord trace({MemoryReadReason? reason}) => MemoryTraceRecord(
    entryId: entry.id,
    revision: entry.revision,
    layer: entry.layer,
    scope: entry.scope,
    kind: entry.kind,
    included: reason == null,
    reason: reason ?? this.reason,
    sourceIds: entry.sourceIds,
  );
}

MemoryTraceRecord _trace(MemoryEntry entry, MemoryReadReason reason) {
  return MemoryTraceRecord(
    entryId: entry.id,
    revision: entry.revision,
    layer: entry.layer,
    scope: entry.scope,
    kind: entry.kind,
    included: false,
    reason: reason,
    sourceIds: entry.sourceIds,
  );
}

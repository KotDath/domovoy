import 'dart:convert';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../core/rag/grounding.dart';
import '../../../core/rag/models.dart';
import '../../../core/rag/turn.dart';

enum RagGroundingFault { none, wrongChunkId, wrongQuote }

/// Application-owned policy; generic runtime owns and accounts for transport.
final class RagFinalAnswerGate implements AgentFinalAnswerGate {
  RagFinalAnswerGate({
    required this.turn,
    required this.persistDiagnostic,
    this.fault = RagGroundingFault.none,
    this.includeTaskInstruction = false,
  });
  final RagPreparedTurn turn;
  final RagGroundingFault fault;
  final bool includeTaskInstruction;
  final Future<void> Function(Map<String, Object?>) persistDiagnostic;
  RagGroundedAnswer? accepted;
  final diagnostics = <Map<String, Object?>>[];

  @override
  Future<AgentFinalAnswerDecision> evaluate(
    AgentFinalAnswerDraft draft,
    CancellationToken cancellation,
  ) async {
    checkRagCancellation(cancellation.isCancelled);
    final clock = Stopwatch()..start();
    var candidate = draft.text;
    String? failure;
    RagGroundedAnswer? result;
    try {
      if (draft.finishReason != LlmFinishReason.stop) {
        throw const FormatException('answer_incomplete');
      }
      if (fault != RagGroundingFault.none) {
        final decoded = jsonDecode(candidate) as Map<String, dynamic>;
        final claims = decoded['claims'] as List;
        if (claims.isNotEmpty) {
          final citation =
              ((claims.first as Map)['evidence'] as List).first as Map;
          if (fault == RagGroundingFault.wrongChunkId) {
            citation['chunk_id'] = 'EXPLICIT_DEMO_FORGED_CHUNK_ID';
          } else {
            citation['quote'] =
                'EXPLICIT_DEMO_QUOTE_NOT_PRESENT_IN_ANY_SENT_CHUNK';
          }
          candidate = jsonEncode(decoded);
        } else {
          throw const FormatException('fault_injection_requires_claim');
        }
      }
      result = RagGroundedAnswer.parse(candidate, turn);
    } on Object catch (error) {
      failure = error is FormatException
          ? error.message.toString()
          : 'answer_schema';
    }
    final diagnostic = <String, Object?>{
      'version': 1,
      'kind': 'final_answer_validation',
      'repair_attempt': draft.repairAttempt,
      'fault_injection': fault.name,
      'accepted': result != null,
      'reason': failure,
      'elapsed_ms': clock.elapsedMilliseconds,
      if (result != null) 'grounding': result.toJson(),
      if (result == null) 'rejected_draft_diagnostic_only': candidate,
      'draft_sha256': ragHash(candidate),
      'semantic_entailment': 'not_automatically_proven',
    };
    await persistDiagnostic(diagnostic);
    checkRagCancellation(cancellation.isCancelled);
    diagnostics.add(Map.unmodifiable(diagnostic));
    if (result != null) {
      accepted = result;
      return AgentFinalAnswerAccepted(result.render());
    }
    final hints = _repairHints(candidate, turn);
    return AgentFinalAnswerRejected(
      reason: failure ?? 'invalid_answer',
      repairRequest: draft.repairAttempt
          ? null
          : LlmRequest(
              model: draft.request.model,
              // JSON-mode providers can return only whitespace. The single
              // isolated repair uses text transport in that case, still requiring
              // the same strict application JSON and exact evidence validation.
              generation:
                  candidate.trim().isEmpty &&
                      draft.request.generation.responseFormat ==
                          LlmResponseFormat.jsonObject
                  ? LlmGenerationConfig(
                      responseFormat: LlmResponseFormat.text,
                      reasoningMode: draft.request.generation.reasoningMode,
                      reasoningEffort: draft.request.generation.reasoningEffort,
                      temperature: draft.request.generation.temperature,
                      maxOutputTokens: draft.request.generation.maxOutputTokens,
                    )
                  : draft.request.generation,
              context: LlmContext(
                systemPrompt: [
                  ragGroundedAnswerInstruction,
                  if (turn.request.taskState != null || includeTaskInstruction)
                    ragTaskGroundingInstruction,
                  'This is the one repair. Mandatory: remove EVERY citation marked remove_unmatched_citation in exact_quote_repair_hints. A quote assembled across intervening source text is invalid, even if all its words occur in the source. Delete any claim left without evidence, or replace its evidence with a different EXACT contiguous passage. Do not try to recreate or lightly reword an unavailable quote. Return partial if deletion leaves requested aspects unsupported.',
                ].join('\n\n'),
                messages: [
                  LlmMessage(
                    role: LlmMessageRole.user,
                    parts: [
                      LlmTextPart(
                        jsonEncode({
                          'question': turn.request.query,
                          'evidence': [
                            for (final hit in turn.evidence) hit.chunk.toJson(),
                          ],
                          if (turn.request.taskState != null)
                            'user_state_evidence': turn.request.taskState!.facts
                                .map(turn.request.taskState!.evidenceJson)
                                .toList(),
                          'draft_suggestion_not_approved': _repairSuggestion(
                            candidate,
                            turn,
                            hints,
                          ),
                          'validation_error': failure,
                          'exact_quote_repair_hints': [
                            for (final hint in hints)
                              {
                                for (final entry in hint.entries)
                                  if (entry.key != 'rejected_quote')
                                    entry.key: entry.value,
                              },
                          ],
                          'instruction':
                              r'Rebuild the answer once using only current supplied evidence. draft_suggestion_not_approved retains original MODEL claim text with exact original source-span suggestions; unavailable citations/claims are omitted. This is NOT an accepted answer or semantic approval. Remove or correct unsupported claims, even when a suggested quote is exact. Use exact_quote_repair_hints as JSON string VALUES. Encode newlines/control characters exactly once: after JSON parsing, \n becomes a real newline and \u0002 that actual control character. Use partial when requested aspects cannot all be supported, or abstained with empty claims if none can. NEVER copy unavailable quotations from earlier history. No additional repair is allowed.',
                        }),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}

/// A prompt aid for a real model repair, not a returned/accepted answer. Original
/// rejection remains in diagnostics. Do not teach the model an impossible quote
/// by repeating it as a draft it should copy. No new claim text is created here.
Map<String, Object?>? _repairSuggestion(
  String candidate,
  RagPreparedTurn turn,
  List<Map<String, String>> hints,
) {
  try {
    final root = jsonDecode(candidate);
    if (root is! Map || root['claims'] is! List) return null;
    final sources = <String, String>{
      for (final h in turn.evidence) h.chunk.id: h.chunk.text,
      if (turn.request.taskState case final state?)
        for (final f in state.facts) state.evidenceId(f): f.quote,
    };
    final claims = <Map<String, Object?>>[];
    var dropped = false;
    for (final c in (root['claims'] as List).take(16)) {
      if (c is! Map ||
          c['text'] is! String ||
          (c['text'] as String).length > 4000 ||
          c['evidence'] is! List) {
        dropped = true;
        continue;
      }
      final evidence = <Map<String, String>>[];
      for (final e in (c['evidence'] as List).take(4)) {
        if (e is! Map || e['chunk_id'] is! String || e['quote'] is! String) {
          dropped = true;
          continue;
        }
        var id = e['chunk_id'] as String, quote = e['quote'] as String;
        for (final hint in hints) {
          if (hint['rejected_chunk_id'] == id &&
              hint['rejected_quote'] == quote &&
              hint.containsKey('actual_exact_quote')) {
            id = hint['suggested_chunk_id']!;
            quote = hint['actual_exact_quote']!;
            break;
          }
        }
        if (quote.isEmpty ||
            quote.length > 1600 ||
            !(sources[id]?.contains(quote) ?? false)) {
          dropped = true;
          continue;
        }
        evidence.add({'chunk_id': id, 'quote': quote});
      }
      if (evidence.isEmpty ||
          (c['kind'] == 'derived' &&
              evidence
                      .map((e) => e['chunk_id']!.startsWith('user-state:'))
                      .toSet()
                      .length !=
                  2)) {
        dropped = true;
        continue;
      }
      claims.add({
        'text': c['text'],
        if (c['kind'] == 'derived') 'kind': 'derived',
        'evidence': evidence,
      });
    }
    return {
      'status': claims.isEmpty
          ? 'abstained'
          : dropped
          ? 'partial'
          : root['status'],
      'claims': claims,
    };
  } on Object {
    return null;
  }
}

/// Suggestions are data for the ONE model repair, never host acceptance or
/// canonicalization. Every repaired citation still passes the original gate.
List<Map<String, String>> _repairHints(String candidate, RagPreparedTurn turn) {
  try {
    final root = jsonDecode(candidate);
    if (root is! Map || root['claims'] is! List) return [];
    final state = turn.request.taskState;
    final sources = <(String, String)>[
      for (final h in turn.evidence) (h.chunk.id, h.chunk.text),
      if (state != null)
        for (final f in state.facts) (state.evidenceId(f), f.quote),
    ];
    final hints = <Map<String, String>>[];
    for (final claim in root['claims'] as List) {
      if (claim is! Map || claim['evidence'] is! List) continue;
      for (final c in claim['evidence'] as List) {
        if (c is! Map || c['quote'] is! String || c['chunk_id'] is! String) {
          continue;
        }
        final quote = c['quote'] as String, id = c['chunk_id'] as String;
        if (quote.length > 1600 || quote.trim().isEmpty) continue;
        if (sources.any((s) => s.$1 == id && s.$2.contains(quote))) continue;
        final ordered = [
          ...sources.where((s) => s.$1 == id),
          ...sources.where((s) => s.$1 != id),
        ];
        var matched = false;
        for (final source in ordered) {
          final exact = _whitespaceSpan(source.$2, quote);
          if (exact == null || exact.length > 1600) continue;
          matched = true;
          hints.add({
            'rejected_chunk_id': id,
            'rejected_quote': quote,
            'suggested_chunk_id': source.$1,
            'actual_exact_quote': exact,
          });
          break;
        }
        if (!matched) {
          hints.add({
            'rejected_chunk_id': id,
            'rejected_quote': quote,
            'action': 'remove_unmatched_citation',
            'reason':
                'No matching excerpt exists in the CURRENT sent evidence. Remove this citation; remove the claim if it has no supporting current evidence. Use partial if aspects remain unanswered.',
          });
        }
        if (hints.length >= 16) return hints;
      }
    }
    return hints;
  } on Object {
    return [];
  }
}

String? _whitespaceSpan(String source, String quote) {
  // Providers commonly omit Markdown emphasis/code delimiters as well as
  // wrapping whitespace. PDF extraction can also retain soft-hyphen/control
  // markers. This matching is ONLY a repair suggestion; return
  // the original characters and coordinates, never a normalized quote.
  final normalized = StringBuffer();
  final offsets = <int>[];
  int? gap;
  final whitespace = RegExp(r'\s');
  bool marker(String c) =>
      c == '*' || c == '`' || c == '\u0002' || c == '\u00ad';
  for (var i = 0; i < source.length; i++) {
    final c = source[i];
    if (marker(c)) continue;
    if (whitespace.hasMatch(c)) {
      gap ??= i;
      continue;
    }
    if (gap != null && offsets.isNotEmpty) {
      normalized.write(' ');
      offsets.add(gap);
    }
    gap = null;
    normalized.write(c);
    offsets.add(i);
  }
  final needle = quote
      .replaceAll(RegExp('[*`\u0002\u00ad]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  final start = normalized.toString().indexOf(needle);
  if (start < 0 || needle.isEmpty) return null;
  var a = offsets[start], b = offsets[start + needle.length - 1] + 1;
  while (a > 0 && marker(source[a - 1])) {
    a--;
  }
  while (b < source.length && marker(source[b])) {
    b++;
  }
  return source.substring(a, b);
}

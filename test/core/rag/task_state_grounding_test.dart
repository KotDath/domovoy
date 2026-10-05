import 'dart:convert';

import 'package:domovoy/core/rag/grounding.dart';
import 'package:domovoy/core/rag/task_state.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/rag_grounding_fixture.dart';
import '../../support/rag_task_state_fixture.dart';

RagPreparedTurn prepared(RagTaskState state, {bool documents = true}) {
  final f = RagGroundingFixture();
  return RagPreparedTurn(
    request: RagTurnRequest(
      id: 'request',
      project: 'p',
      session: 's',
      query: 'Current time?',
      corpus: 'domovoy',
      strategy: f.chunk.strategy,
      protocol: RagProtocol.m1,
      contextByteBudget: 24000,
      taskState: state,
    ),
    generation: 'g',
    fingerprint: 'fp',
    candidates: documents ? f.turn.candidates : [],
    evidence: documents ? f.turn.evidence : [],
    context: f.turn.context,
    timings: {},
    exclusions: {},
  );
}

void main() {
  test(
    'short exact user quote validates owner/revision/UTF-16, not as a document',
    () {
      final state = changedTaskState(
        RagTaskState(project: 'p', session: 's'),
        '08:30',
      );
      final fact = state.facts.single;
      final answer = jsonEncode({
        'status': 'answered',
        'claims': [
          {
            'text': 'You chose 08:30.',
            'evidence': [
              {'chunk_id': state.evidenceId(fact), 'quote': '08:30'},
            ],
          },
        ],
      });
      final parsed = RagGroundedAnswer.parse(
        answer,
        prepared(state, documents: false),
      );
      final cite = parsed.claims.single.evidence.single;
      expect(cite.chunk, isNull);
      expect(cite.fact, same(fact));
      expect(cite.start, fact.userText.indexOf('08:30'));
      expect(fact.userText.substring(cite.start, cite.end), '08:30');
      expect(
        cite.start,
        greaterThan(fact.userText.substring(0, cite.start).runes.length),
      );
      expect(cite.toJson()['source_kind'], 'user_state');
      expect(cite.toJson()['state_revision'], 1);
      expect(cite.toJson()['document_id'], isNull);
      expect(parsed.claims.single.kind, 'user_state');
      expect(parsed.render(), contains('user_state r1'));
      final next = changedTaskState(state, '07:45');
      expect(
        () => RagGroundedAnswer.parse(answer, prepared(next)),
        throwsFormatException,
      );
      expect(
        () => RagGroundedAnswer.parse(
          answer,
          prepared(
            changedTaskState(
              RagTaskState(project: 'other', session: 's'),
              '08:30',
            ),
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'derived claim requires both document and scoped user-state sources',
    () {
      final state = changedTaskState(
        RagTaskState(project: 'p', session: 's'),
        '08:30',
      );
      final f = RagGroundingFixture();
      final evidence = [
        {'chunk_id': state.evidenceId(state.facts.single), 'quote': '08:30'},
        {'chunk_id': f.chunk.id, 'quote': RagGroundingFixture.quote},
      ];
      String answer(List<Object?> citations) => jsonEncode({
        'status': 'answered',
        'claims': [
          {
            'kind': 'derived',
            'text': 'A derived test claim.',
            'evidence': citations,
          },
        ],
      });
      final parsed = RagGroundedAnswer.parse(answer(evidence), prepared(state));
      expect(parsed.claims.single.kind, 'derived');
      expect(
        parsed.toJson()['semantic_entailment'],
        'not_automatically_proven',
      );
      expect(
        () =>
            RagGroundedAnswer.parse(answer([evidence.first]), prepared(state)),
        throwsFormatException,
      );
      expect(
        () => RagGroundedAnswer.parse(answer([evidence.last]), prepared(state)),
        throwsFormatException,
      );
    },
  );
}

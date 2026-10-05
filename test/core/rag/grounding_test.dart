import 'dart:convert';

import 'package:domovoy/core/rag/grounding.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/rag_grounding_fixture.dart';

void main() {
  test('quote provenance uses frozen sent revision and UTF-16 coordinates', () {
    final f = RagGroundingFixture();
    final answer = RagGroundedAnswer.parse(f.answer(), f.turn);
    final citation = answer.claims.single.evidence.single;
    final relative = f.chunk.text.indexOf(RagGroundingFixture.quote);
    expect(citation.start, f.chunk.start + relative);
    expect(citation.end, citation.start + RagGroundingFixture.quote.length);
    expect(
      f.chunk.text.substring(relative, citation.end - f.chunk.start),
      citation.quote,
    );
    expect(
      relative,
      greaterThan(f.chunk.text.substring(0, relative).runes.length),
    );
    expect(citation.toJson()['revision'], f.chunk.documentRevision);
    expect(
      answer.render(),
      contains('Источник: facts.md · Лимиты · chunk ${f.chunk.id}'),
    );
    expect(answer.toJson()['semantic_entailment'], 'not_automatically_proven');
  });

  test(
    'forged IDs, altered quotes and model-authored coordinates fail closed',
    () {
      final f = RagGroundingFixture();
      for (final bad in [
        f.json(id: 'another-document-revision'),
        f.json(quote: 'SOUL.md допускает 5000 символов.'),
        f.json(quote: 'SOUL.md  допускает 4000 символов.'),
        f.json(quote: '4000'),
        {...f.json(), 'answer': 'uncited prose'},
        {'status': 'answered', 'claims': <Object?>[]},
        f.json(status: 'abstained'),
      ]) {
        expect(
          () => RagGroundedAnswer.parse(jsonEncode(bad), f.turn),
          throwsFormatException,
        );
      }
      final coordinates =
          jsonDecode(jsonEncode(f.json())) as Map<String, dynamic>;
      final evidence =
          ((coordinates['claims'] as List).single as Map)['evidence'] as List;
      (evidence.single as Map)['start'] = 0;
      expect(
        () => RagGroundedAnswer.parse(jsonEncode(coordinates), f.turn),
        throwsFormatException,
      );
    },
  );

  test(
    'partial retains supported facts; abstention invents no sources or quotes',
    () {
      final f = RagGroundingFixture();
      final partial = RagGroundedAnswer.parse(
        jsonEncode(f.json(status: 'partial')),
        f.turn,
      );
      expect(
        partial.render(),
        contains('Для полного ответа недостаточно данных'),
      );
      final abstained = RagGroundedAnswer.parse(
        '{"status":"abstained","claims":[]}',
        f.turn,
      );
      expect(abstained.claims, isEmpty);
      expect(abstained.render(), ragInsufficientEvidenceAnswer);
      expect(abstained.render(), isNot(contains('Источник:')));
    },
  );
}

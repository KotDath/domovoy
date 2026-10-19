import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/features/support/application/support_evidence_context.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/support_evidence_fixture.dart';
import '../../../support/memory_jsonl_storage.dart';

void main() {
  test(
    'publishing a new active revision cannot substitute frozen neighbor text',
    () async {
      final original = fixture();
      final replacement = fixture(
        generation: 'new-generation',
        texts: ['NEW REVISION\n', 'DO NOT MIX\n'],
      );
      final repository = JsonlRagRepository(FakeMemoryJsonlStorage());
      await repository.saveDocuments(
        'support-test',
        'docs',
        original.documents,
      );
      await repository.publishIndex('support-test', 'docs', original);
      final turn = prepared(original, [RagHit(original.chunks[2], .8)]);
      await repository.saveDocuments(
        'support-test',
        'docs',
        replacement.documents,
      );
      await repository.publishIndex('support-test', 'docs', replacement);
      expect(
        (await repository.loadIndex(
          'support-test',
          'docs',
          ChunkStrategy.structure,
        ))!.generation,
        replacement.generation,
      );
      final expanded = await expandSupportEvidence(
        repository,
        turn,
        CancellationSource().token,
      );
      expect(expanded.context, isNot(contains('DO NOT MIX')));
      expect(
        evidencePayload(expanded.context).map((e) => e['revision']).toSet(),
        {original.documents.first.revision},
      );
      expect(
        evidencePayload(expanded.context),
        contains(containsPair('text', original.chunks[3].text)),
      );
    },
  );

  test(
    'ordinary documents expand only direct neighbors of admitted dense seeds',
    () async {
      final index = fixture();
      final dense = [
        RagHit(index.chunks[2], .81),
        RagHit(index.chunks[3], .72),
      ];
      final turn = prepared(index, dense);
      final repository = FrozenRepository(index);
      final result = await expandSupportEvidence(
        repository,
        turn,
        CancellationSource().token,
      );
      final trace = result.toJson();
      expect(repository.generations, [index.generation]);
      final payload = evidencePayload(result.context);
      expect(payload.map((e) => e['chunk_id']), [
        index.chunks[2].id,
        index.chunks[3].id,
        index.chunks[1].id,
        index.chunks[4].id,
      ]);
      expect(result.context, isNot(contains('OTHER_DOCUMENT_BODY')));
      expect(
        payload.map((e) => e['chunk_id']).toSet(),
        hasLength(payload.length),
      );
      final candidates = trace['candidates'] as List;
      expect(candidates.take(2), turn.toJson()['candidates']);
      for (final row in candidates.skip(2).cast<Map>()) {
        expect(row['retrieval_kind'], 'support_document_neighbor');
        expect(row['dense_rank'], isNull);
        expect(row['cosine'], isNull);
        final source = index.chunks.singleWhere(
          (c) => c.id == row['chunk']['id'],
        );
        expect(row['chunk'], source.toJson());
        expect(row['generation'], index.generation);
      }
      expect(trace['context_bytes'], utf8.encode(result.context).length);
      expect(
        (trace['support_expansion'] as Map)['decisions'],
        contains(containsPair('result', 'already_sent')),
      );
    },
  );

  test(
    'next and previous boundaries never spill to another document',
    () async {
      final index = fixture();
      for (final ordinal in [0, 5]) {
        final result = await expandSupportEvidence(
          FrozenRepository(index),
          prepared(index, [RagHit(index.chunks[ordinal], .8)]),
          CancellationSource().token,
        );
        final payload = evidencePayload(result.context);
        expect(payload, hasLength(2));
        expect(
          payload.every((e) => e['document_id'] == index.documents.first.id),
          true,
        );
      }
    },
  );

  test(
    'full escaped multibyte envelope fits exactly and rejects one byte less without dropping dense',
    () async {
      final index = fixture(
        texts: ['前置き "quoted"\\\n', 'Seed 😀\n', '後続 "escape"\\\n'],
      );
      final dense = [RagHit(index.chunks[1], .9)];
      final full = await expandSupportEvidence(
        FrozenRepository(index),
        prepared(index, dense),
        CancellationSource().token,
      );
      final bytes = utf8.encode(full.context).length;
      final exact = await expandSupportEvidence(
        FrozenRepository(index),
        prepared(index, dense, budget: bytes),
        CancellationSource().token,
      );
      expect(exact.context, full.context);
      final tight = await expandSupportEvidence(
        FrozenRepository(index),
        prepared(index, dense, budget: bytes - 1),
        CancellationSource().token,
      );
      expect(utf8.encode(tight.context).length, lessThanOrEqualTo(bytes - 1));
      expect(
        evidencePayload(tight.context).first['chunk_id'],
        dense.single.chunk.id,
      );
      expect(evidencePayload(tight.context), hasLength(2));
      expect(
        (tight.toJson()['support_expansion'] as Map)['decisions'],
        contains(containsPair('result', 'context_budget')),
      );
      final base = prepared(index, dense);
      final none = await expandSupportEvidence(
        FrozenRepository(index),
        prepared(index, dense, budget: utf8.encode(base.context).length),
        CancellationSource().token,
      );
      expect(none.context, base.context);
    },
  );

  test(
    'supplemental envelope byte cap skips large neighbors and remains nonrecursive',
    () async {
      final index = fixture(
        texts: ['far\n', 'я' * 5000, 'seed\n', '小' * 5000, 'far end\n'],
      );
      final dense = [RagHit(index.chunks[2], .9)];
      final turn = prepared(index, dense, budget: 60000);
      final result = await expandSupportEvidence(
        FrozenRepository(index),
        turn,
        CancellationSource().token,
      );
      expect(result.context, turn.context);
      final decisions =
          (result.toJson()['support_expansion'] as Map)['decisions'] as List;
      expect(decisions, hasLength(2));
      expect(
        decisions.every((d) => d['result'] == 'supplemental_byte_limit'),
        true,
      );
    },
  );

  test(
    'frozen generation is used despite a different active revision',
    () async {
      final index = fixture();
      final repository = FrozenRepository(index);
      // loadIndex is deliberately unsupported: expansion must never follow it.
      final result = await expandSupportEvidence(
        repository,
        prepared(index, [RagHit(index.chunks[1], .7)]),
        CancellationSource().token,
      );
      expect(
        evidencePayload(
          result.context,
        ).every((e) => e['revision'] == index.documents.first.revision),
        true,
      );
    },
  );

  test(
    'missing, wrong generation/fingerprint/strategy and mismatched seeds fail closed',
    () async {
      final index = fixture();
      final turn = prepared(index, [RagHit(index.chunks[1], .7)]);
      for (final other in [
        null,
        fixture(generation: 'replacement'),
        fixture(fingerprint: 'other'),
        fixture(strategy: ChunkStrategy.fixed),
        fixture(texts: ['different\n', 'content\n']),
      ]) {
        await expectLater(
          expandSupportEvidence(
            FrozenRepository(other),
            turn,
            CancellationSource().token,
          ),
          throwsStateError,
        );
      }
      final empty = await expandSupportEvidence(
        FrozenRepository(index),
        prepared(index, []),
        CancellationSource().token,
      );
      expect(empty.context, isEmpty);
      expect(empty.toJson()['final_evidence_ids'], isEmpty);
    },
  );

  test(
    'cancellation before and while loading frozen generation aborts',
    () async {
      final index = fixture();
      final turn = prepared(index, [RagHit(index.chunks[1], .7)]);
      final cancelled = CancellationSource()..cancel();
      final repository = FrozenRepository(index);
      await expectLater(
        expandSupportEvidence(repository, turn, cancelled.token),
        throwsA(isA<RagCancelled>()),
      );
      expect(repository.generations, isEmpty);
      final during = CancellationSource();
      repository.onLoad = during.cancel;
      await expectLater(
        expandSupportEvidence(repository, turn, during.token),
        throwsA(isA<RagCancelled>()),
      );
    },
  );
}

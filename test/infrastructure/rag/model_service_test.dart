import 'dart:convert';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/rag/contracts.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/retrieval.dart';
import 'package:domovoy/infrastructure/rag/model_service_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'reranker preserves negative logit scale, verifies response IDs and drift',
    () async {
      var invalid = false;
      final chunk = RagChunk(
        documentId: 'd',
        documentRevision: 'r',
        source: 's',
        title: 't',
        section: 's',
        start: 0,
        end: 1,
        text: 'x',
        strategy: ChunkStrategy.fixed,
        tokens: 1,
        ordinal: 0,
      );
      final client = RagModelServiceClient(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'fingerprint': 'rank-v1',
              'score_scale': 'bge_raw_logit',
              'truncated': false,
              'outputs': [
                {'id': invalid ? 'unknown' : chunk.id, 'score': -4.5},
              ],
            }),
            200,
          ),
        ),
        Uri.parse('http://localhost:8765'),
      );
      const model = RagRerankerInfo(
        fingerprint: 'rank-v1',
        scale: 'bge_raw_logit',
      );
      final token = CancellationSource().token;
      expect(
        (await client.rerank('q', [RagHit(chunk, 0.8)], model, token)).scores,
        {chunk.id: -4.5},
      );
      invalid = true;
      await expectLater(
        client.rerank('q', [RagHit(chunk, 0.8)], model, token),
        throwsFormatException,
      );
    },
  );
  test(
    'codepoint tokenizer positions map to UTF-16 without splitting emoji',
    () async {
      final provider = RagModelServiceClient(
        MockClient(
          (r) async => http.Response(
            jsonEncode({
              'offset_unit': 'codepoint',
              'offsets': [
                [0, 1],
                [1, 2],
                [2, 3],
              ],
            }),
            200,
          ),
        ),
        Uri.parse('http://127.0.0.1:8765'),
      );
      final tokens = await provider.tokenize(
        'я😀x',
        CancellationSource().token,
      );
      expect(tokens.map((t) => (t.start, t.end)), [(0, 1), (1, 3), (3, 4)]);
    },
  );
  test(
    'embeddings use response IDs, reject truncation and unknown IDs',
    () async {
      var truncated = false;
      var badId = false;
      final provider = RagModelServiceClient(
        MockClient(
          (r) async => http.Response(
            jsonEncode({
              'fingerprint': 'v1',
              'dimension': 2,
              'normalized': true,
              'truncated': truncated,
              'outputs': [
                {
                  'id': badId ? 'unknown' : 'input-1',
                  'vector': [0, 1],
                },
                {
                  'id': 'input-0',
                  'vector': [1, 0],
                },
              ],
            }),
            200,
          ),
        ),
        Uri.parse('http://localhost:8765'),
      );
      const model = RagModelInfo('v1', 2, 'TEST');
      final token = CancellationSource().token;
      expect(await provider.embed(['a', 'b'], model, token), [
        [1, 0],
        [0, 1],
      ]);
      truncated = true;
      await expectLater(
        provider.embed(['a', 'b'], model, token),
        throwsFormatException,
      );
      truncated = false;
      badId = true;
      await expectLater(
        provider.embed(['a', 'b'], model, token),
        throwsFormatException,
      );
    },
  );
  test('remote cleartext endpoints and credential URLs are rejected', () {
    final client = MockClient((_) async => http.Response('', 200));
    expect(
      () => RagModelServiceClient(client, Uri.parse('http://example.org')),
      throwsArgumentError,
    );
    expect(
      () => RagModelServiceClient(
        client,
        Uri.parse('https://secret@example.org'),
      ),
      throwsArgumentError,
    );
  });
}

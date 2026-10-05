import 'dart:convert';

import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/turn.dart';

final class RagGroundingFixture {
  RagGroundingFixture() {
    final doc = RagDocument(
      source: 'facts.md',
      title: 'Facts',
      text:
          'Вступление 🌙. SOUL.md допускает 4000 символов. USER.md — 2500 символов.',
    );
    document = doc;
    chunk = RagChunk(
      documentId: doc.id,
      documentRevision: doc.revision,
      source: doc.source,
      title: doc.title,
      section: 'Лимиты',
      start: 5,
      end: doc.text.length,
      text: doc.text.substring(5),
      strategy: ChunkStrategy.fixed,
      tokens: 30,
      ordinal: 0,
    );
    turn = RagPreparedTurn(
      request: const RagTurnRequest(
        id: 'request',
        project: 'p',
        session: 's',
        query: 'Лимит SOUL.md?',
        corpus: 'domovoy',
        strategy: ChunkStrategy.fixed,
        protocol: RagProtocol.m4,
        contextByteBudget: 24000,
      ),
      generation: 'generation',
      fingerprint: 'fp',
      candidates: [RagHit(chunk, .9)],
      evidence: [RagHit(chunk, .9)],
      context: ragEvidenceContext([RagHit(chunk, .9)]),
      timings: {},
      exclusions: {},
    );
  }
  late final RagChunk chunk;
  late final RagDocument document;
  late final RagPreparedTurn turn;
  static const quote = 'SOUL.md допускает 4000 символов.';
  Map<String, Object?> json({
    String? id,
    String? quote,
    String status = 'answered',
  }) => {
    'status': status,
    'claims': [
      {
        'text': 'Лимит SOUL.md составляет 4000 символов.',
        'evidence': [
          {
            'chunk_id': id ?? chunk.id,
            'quote': quote ?? RagGroundingFixture.quote,
          },
        ],
      },
    ],
  };
  String answer() => jsonEncode(json());
}

import 'dart:convert';
import 'package:domovoy/core/rag/contracts.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/turn.dart';

List<Map<String, dynamic>> evidencePayload(String context) =>
    (jsonDecode(context.split('\n')[1]) as List).cast<Map<String, dynamic>>();

RagPreparedTurn prepared(
  RagIndex index,
  List<RagHit> dense, {
  int budget = 24000,
}) => RagPreparedTurn(
  request: RagTurnRequest(
    id: 'ordinary-turn',
    project: 'support-test',
    session: 'session',
    query: 'How do I configure notifications and quiet hours?',
    corpus: 'docs',
    strategy: index.strategy,
    protocol: RagProtocol.m1,
    contextByteBudget: budget,
  ),
  generation: index.generation,
  fingerprint: index.fingerprint,
  candidates: dense,
  evidence: dense,
  context: dense.isEmpty ? '' : ragEvidenceContext(dense),
  timings: {},
  exclusions: {},
);

RagIndex fixture({
  List<String>? texts,
  String generation = 'frozen',
  String fingerprint = 'embedding',
  ChunkStrategy strategy = ChunkStrategy.structure,
}) {
  texts ??= [
    'Intro\n',
    'Channels\n',
    'Delivery options\n',
    'Quiet hours\n',
    'Recovery\n',
    'References\n',
  ];
  final doc = RagDocument(
    source: 'help://notifications',
    title: 'Notifications',
    text: texts.join(),
  );
  final other = RagDocument(
    source: 'help://unrelated',
    title: 'Other',
    text: 'OTHER_DOCUMENT_BODY',
  );
  var offset = 0;
  final chunks = [
    for (var n = 0; n < texts.length; n++)
      RagChunk(
        documentId: doc.id,
        documentRevision: doc.revision,
        source: doc.source,
        title: doc.title,
        section: 'Section $n',
        start: offset,
        end: offset += texts[n].length,
        text: texts[n],
        strategy: strategy,
        tokens: 10,
        ordinal: n,
      ),
    RagChunk(
      documentId: other.id,
      documentRevision: other.revision,
      source: other.source,
      title: other.title,
      section: 'Other',
      start: 0,
      end: other.text.length,
      text: other.text,
      strategy: strategy,
      tokens: 10,
      ordinal: 0,
    ),
  ];
  return RagIndex(
    fingerprint: fingerprint,
    dimension: 2,
    strategy: strategy,
    chunks: chunks,
    vectors: [
      for (final _ in chunks) [1, 0],
    ],
    documents: [doc, other],
    elapsedMs: 0,
    generation: generation,
  );
}

class FrozenRepository implements RagRepository {
  FrozenRepository(this.index);
  final RagIndex? index;
  final generations = <String>[];
  void Function()? onLoad;
  @override
  Future<RagIndex?> loadGeneration(
    String project,
    String corpus,
    String generation,
  ) async {
    generations.add(generation);
    onLoad?.call();
    return index;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

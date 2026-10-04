import 'package:domovoy/core/rag/evidence_coverage.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:flutter_test/flutter_test.dart';

RagChunk chunk(int start, int end, {String revision = 'r1'}) => RagChunk(
  documentId: 'doc',
  documentRevision: revision,
  source: 'doc.md',
  title: 'Doc',
  section: 'Facts',
  start: start,
  end: end,
  text: 'x' * (end - start),
  strategy: ChunkStrategy.fixed,
  tokens: end - start,
  ordinal: start,
);

void main() {
  test(
    'serialized evidence covers an exact span across overlapping chunks',
    () {
      final chunks = [
        chunk(14, 24),
        chunk(5, 16),
      ].map((c) => RagChunk.fromJson(c.toJson()));
      expect(
        ragEvidenceCoversSpan(
          documentId: 'doc',
          revision: 'r1',
          start: 8,
          end: 23,
          chunks: chunks,
        ),
        true,
      );
      expect(
        ragEvidenceCoversSpan(
          documentId: 'doc',
          revision: 'r2',
          start: 8,
          end: 23,
          chunks: chunks,
        ),
        false,
      );
      expect(
        ragEvidenceCoversSpan(
          documentId: 'other',
          revision: 'r1',
          start: 8,
          end: 23,
          chunks: chunks,
        ),
        false,
      );
    },
  );
  test('a gap and wrong revision cannot complete coverage', () {
    expect(
      ragEvidenceCoversSpan(
        documentId: 'doc',
        revision: 'r1',
        start: 8,
        end: 23,
        chunks: [
          chunk(5, 14),
          chunk(15, 24),
          chunk(10, 20, revision: 'r2'),
        ],
      ),
      false,
    );
    expect(
      () => ragEvidenceCoversSpan(
        documentId: 'doc',
        revision: 'r1',
        start: 8,
        end: 8,
        chunks: [],
      ),
      throwsArgumentError,
    );
  });
}

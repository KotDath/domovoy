import 'package:domovoy/core/rag/calibration.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:flutter_test/flutter_test.dart';

RagHit hit(String document, double score) => RagHit(
  RagChunk(
    documentId: document,
    documentRevision: 'revision',
    source: '$document.md',
    title: document,
    section: document,
    start: 0,
    end: 4,
    text: 'text',
    strategy: ChunkStrategy.fixed,
    tokens: 1,
    ordinal: 0,
  ),
  score,
);

void main() {
  test('dev cutoff separates negative questions on the actual score scale', () {
    final relevant = hit('known', -2), noise = hit('noise', -5);
    final samples = [
      RagCalibrationSample(
        answerable: true,
        candidates: [noise, relevant],
        relevantIds: {relevant.chunk.id},
        scores: {noise.chunk.id: -5, relevant.chunk.id: -2},
      ),
      RagCalibrationSample(
        answerable: false,
        candidates: [noise],
        relevantIds: {},
        scores: {noise.chunk.id: -5},
      ),
    ];
    final profile = calibrateRagThreshold(samples);
    expect(profile['threshold'], -3.5);
    expect(profile['question_f1'], 1);
    expect(profile['sent_passage_precision'], 1);
    expect(profile['known_hit'], 1);
    expect(profile['unknown_empty'], 1);
    expect(profile['sample_count'], 2);
    expect(() => calibrateRagThreshold([samples.first]), throwsArgumentError);
    expect(
      () => calibrateRagThreshold([
        samples.first,
        RagCalibrationSample(
          answerable: false,
          candidates: [noise],
          relevantIds: {},
          scores: {'unknown': -5},
        ),
      ]),
      throwsArgumentError,
    );
  });
}

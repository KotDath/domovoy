import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/core/rag/retrieval.dart';
import 'package:domovoy/infrastructure/rag/calibrated_retrieval.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production calibration equals the frozen host profile; dev hash is intact',
    () {
      final profile = jsonDecode(
        File('eval/rag/calibration.json').readAsStringSync(),
      );
      expect(ragCalibrationProfile, profile);
      final manifest =
          jsonDecode(File('assets/rag_demo/manifest.json').readAsStringSync())
              as List;
      final documents = [
        for (final row in manifest)
          RagDocument(
            source: row['source'] as String,
            title: row['source'] as String,
            text: File(row['asset'] as String).readAsStringSync(),
          ),
      ]..sort((a, b) => a.source.compareTo(b.source));
      expect(
        ragHash(
          jsonEncode([for (final d in documents) '${d.id}:${d.revision}']),
        ),
        profile['corpus_hash'],
      );
      expect(calibratedRagRetrieval.strategy, ChunkStrategy.fixed);
      expect(calibratedRagRetrieval.calibrationId, profile['id']);
      expect(
        profile['dev_hash'],
        ragHash(File('eval/rag/dev_questions.jsonl').readAsStringSync()),
      );
      expect(
        calibratedRagRetrieval.denseThreshold,
        (profile['dense'] as Map)['threshold'],
      );
      expect(
        calibratedRagRetrieval.expectedRerankerFingerprint,
        profile['reranker_fingerprint'],
      );
      expect(
        () => RagRetrievalConfig.fromProfile({
          ...ragCalibrationProfile,
          'score_scale': 'cosine',
        }),
        throwsFormatException,
      );
      expect(
        () => RagRetrievalConfig.fromProfile({
          ...ragCalibrationProfile,
          'dense': {'threshold': 'invalid'},
        }),
        throwsFormatException,
      );
    },
  );
}

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
    },
  );
}

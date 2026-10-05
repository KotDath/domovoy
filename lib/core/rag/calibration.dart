import 'dart:math';

import 'models.dart';
import 'retrieval.dart';

final class RagCalibrationSample {
  const RagCalibrationSample({
    required this.answerable,
    required this.candidates,
    required this.relevantIds,
    required this.scores,
  });
  final bool answerable;
  final List<RagHit> candidates;
  final Set<String> relevantIds;
  final Map<String, double> scores;
}

/// Dev only: maximize question-level F1, then sent-passage precision; choose
/// the higher cutoff for a remaining tie. Golden questions never participate.
Map<String, Object?> calibrateRagThreshold(List<RagCalibrationSample> samples) {
  if (samples.isEmpty ||
      !samples.any((s) => s.answerable) ||
      !samples.any((s) => !s.answerable)) {
    throw ArgumentError('Calibration requires positive and negative questions');
  }
  final values = samples.expand((s) => s.scores.values).toSet().toList()
    ..sort();
  if (values.isEmpty || values.any((v) => !v.isFinite)) {
    throw ArgumentError('Invalid calibration scores');
  }
  for (final sample in samples) {
    final ids = sample.candidates.map((h) => h.chunk.id).toSet();
    if (ids.length != sample.candidates.length ||
        ids.length != sample.scores.length ||
        !ids.containsAll(sample.scores.keys) ||
        !ids.containsAll(sample.relevantIds) ||
        (!sample.answerable && sample.relevantIds.isNotEmpty)) {
      throw ArgumentError('Calibration labels/scores must match candidate IDs');
    }
  }
  final cutoffs = [
    values.first - 0.000001,
    for (var i = 1; i < values.length; i++) (values[i - 1] + values[i]) / 2,
    values.last + 0.000001,
  ];
  var bestF1 = -1.0, bestPrecision = -1.0, bestThreshold = cutoffs.first;
  Map<String, Object?>? best;
  for (final cutoff in cutoffs) {
    var tp = 0, fn = 0, fp = 0, tn = 0, relevantSent = 0, totalSent = 0;
    for (final sample in samples) {
      final ranked = sample.candidates.toList()
        ..sort((a, b) {
          final order = sample.scores[b.chunk.id]!.compareTo(
            sample.scores[a.chunk.id]!,
          );
          return order == 0 ? a.chunk.id.compareTo(b.chunk.id) : order;
        });
      final sent = <RagHit>[];
      for (final hit in ranked) {
        if (sample.scores[hit.chunk.id]! >= cutoff &&
            sent.length < 5 &&
            !sent.any((e) => overlappingRagEvidence(e.chunk, hit.chunk))) {
          sent.add(hit);
        }
      }
      final relevant = sent
          .where((h) => sample.relevantIds.contains(h.chunk.id))
          .length;
      relevantSent += relevant;
      totalSent += sent.length;
      if (sample.answerable) {
        if (relevant > 0) {
          tp++;
        } else {
          fn++;
        }
      } else {
        if (sent.isNotEmpty) {
          fp++;
        } else {
          tn++;
        }
      }
    }
    final f1 = 2 * tp / max(1, 2 * tp + fn + fp);
    final precision = relevantSent / max(1, totalSent);
    if (f1 > bestF1 ||
        (f1 == bestF1 &&
            (precision > bestPrecision ||
                (precision == bestPrecision && cutoff > bestThreshold)))) {
      bestF1 = f1;
      bestPrecision = precision;
      bestThreshold = cutoff;
      best = {
        'threshold': cutoff,
        'question_f1': f1,
        'sent_passage_precision': precision,
        'known_hit': tp,
        'known_miss': fn,
        'unknown_nonempty': fp,
        'unknown_empty': tn,
        'relevant_sent': relevantSent,
        'total_sent': totalSent,
      };
    }
  }
  return {
    ...best!,
    'observed_min': values.first,
    'observed_max': values.last,
    'sample_count': samples.length,
    'cutoff_count': cutoffs.length,
    'objective': 'question F1, sent-passage precision, higher cutoff; dev only',
  };
}

import 'dart:io';

import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canonical LlmUsage', () {
    test('uses mutually exclusive component fallbacks with provenance', () {
      final usage = LlmUsage(
        input: LlmUsageMetric.providerReported(6),
        cacheRead: LlmUsageMetric.providerReported(3),
        cacheWrite: LlmUsageMetric.providerReported(1),
        output: LlmUsageMetric.providerReported(5),
        reasoning: LlmUsageMetric.providerReported(2),
      );

      expect(usage.requestContext?.value, 10);
      expect(
        usage.requestContext?.provenance,
        LlmUsageMetricProvenance.derivedFromProvider,
      );
      expect(usage.responseGenerated?.value, 7);
      expect(usage.overall?.value, 17);
      expect(usage.inputTokens, 10);
      expect(usage.outputTokens, 7);
      expect(usage.totalTokens, 17);
      expect(usage.requestCompleteness, LlmUsageCompleteness.complete);
      expect(usage.responseCompleteness, LlmUsageCompleteness.complete);
      expect(usage.overallCompleteness, LlmUsageCompleteness.complete);
      expect(usage.cacheHitRatio?.value, closeTo(0.3, 0.000001));
      expect(
        usage.cacheHitRatio?.provenance,
        LlmUsageMetricProvenance.derivedFromProvider,
      );
    });

    test(
      'provider parents take precedence and are never added to children',
      () {
        final usage = LlmUsage(
          input: LlmUsageMetric.derivedFromProvider(6),
          cacheRead: LlmUsageMetric.providerReported(4),
          output: LlmUsageMetric.derivedFromProvider(3),
          reasoning: LlmUsageMetric.providerReported(2),
          reportedInputTotal: LlmUsageMetric.providerReported(10),
          reportedOutputTotal: LlmUsageMetric.providerReported(5),
          reportedOverall: LlmUsageMetric.providerReported(15),
          parentSemantics: const LlmUsageParentSemantics(
            inputCacheRead: LlmUsageChildInclusion.included,
            inputCacheWrite: LlmUsageChildInclusion.excluded,
            outputReasoning: LlmUsageChildInclusion.included,
          ),
        );

        expect(usage.requestContext, usage.reportedInputTotal);
        expect(usage.responseGenerated, usage.reportedOutputTotal);
        expect(usage.overall, usage.reportedOverall);
        expect(usage.totalTokens, 15);
        expect(usage.anomalies, isEmpty);
      },
    );

    test('inconsistent overall is diagnostic and falls back to parents', () {
      final usage = LlmUsage(
        reportedInputTotal: LlmUsageMetric.providerReported(10),
        reportedOutputTotal: LlmUsageMetric.providerReported(5),
        reportedOverall: LlmUsageMetric.providerReported(14),
      );

      expect(usage.reportedOverallTokens, 14);
      expect(usage.totalTokens, 15);
      expect(
        usage.overall?.provenance,
        LlmUsageMetricProvenance.derivedFromProvider,
      );
      expect(
        usage.hasAnomaly(
          LlmUsageAnomalyKind.inconsistentTotal,
          metric: LlmUsageMetricKind.reportedOverall,
        ),
        isTrue,
      );
    });

    test('partial and unavailable values stay unknown', () {
      final partial = LlmUsage(cacheRead: LlmUsageMetric.providerReported(0));
      expect(partial.requestContext, isNull);
      expect(partial.responseGenerated, isNull);
      expect(partial.overall, isNull);
      expect(partial.cacheHitRatio, isNull);
      expect(partial.requestCompleteness, LlmUsageCompleteness.partial);
      expect(partial.responseCompleteness, LlmUsageCompleteness.unavailable);
      expect(partial.overallCompleteness, LlmUsageCompleteness.partial);

      final zero = LlmUsage(
        input: LlmUsageMetric.providerReported(0),
        cacheRead: LlmUsageMetric.providerReported(0),
        cacheWrite: LlmUsageMetric.providerReported(0),
      );
      expect(zero.requestContext?.value, 0);
      expect(zero.cacheHitRatio, isNull);
      expect(LlmUsage().overallCompleteness, LlmUsageCompleteness.unavailable);
    });

    test('version one JSON decodes conservatively and version two freezes', () {
      final legacy = LlmUsage.fromJson(<String, Object?>{
        'type': LlmUsage.jsonType,
        'version': 1,
        'inputTokens': 10,
        'outputTokens': 5,
        'totalTokens': 15,
        'cacheHitTokens': 4,
        'cacheMissTokens': 6,
      });

      expect(legacy.reportedInputTotalTokens, 10);
      expect(legacy.reportedOutputTotalTokens, 5);
      expect(legacy.reportedOverallTokens, 15);
      expect(legacy.input?.value, 6);
      expect(
        legacy.input?.provenance,
        LlmUsageMetricProvenance.derivedFromProvider,
      );
      expect(legacy.cacheRead?.value, 4);
      expect(legacy.cacheMissEvidence?.value, 6);
      expect(legacy.cacheWrite, isNull);
      expect(legacy.toJson()['version'], 2);
      expect(LlmUsage.fromJson(legacy.toJson()), legacy);
      expect(
        () => legacy.anomalies.add(
          const LlmUsageAnomaly(LlmUsageAnomalyKind.invalidValue),
        ),
        throwsUnsupportedError,
      );
      expect(() => legacy.toJson()['input'] = null, throwsUnsupportedError);
    });

    test('invalid persisted values and estimated provider metrics reject', () {
      expect(
        () => LlmUsage.fromJson(<String, Object?>{
          'type': LlmUsage.jsonType,
          'version': 2,
          'input': <String, Object?>{
            'value': -1,
            'provenance': 'providerReported',
          },
        }),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => LlmUsage(input: LlmUsageMetric.estimated(1)),
        throwsA(isA<LlmException>()),
      );
    });
  });

  group('semantic normalizer', () {
    test(
      'collapses equal aliases and applies checked inclusive subtraction',
      () {
        final usage = normalizeLlmUsage(
          reportedInputTotal: LlmUsageCounter.fromAliases(<Object?>[10, 10]),
          cacheRead: LlmUsageCounter.fromAliases(<Object?>[3, 3]),
          cacheWrite: const LlmUsageCounter.valid(1),
          reportedOutputTotal: const LlmUsageCounter.valid(8),
          reasoning: const LlmUsageCounter.valid(2),
          reportedOverall: const LlmUsageCounter.valid(18),
          semantics: const LlmUsageNormalizationSemantics(
            inputIncludesCacheRead: true,
            inputIncludesCacheWrite: true,
            outputIncludesReasoning: true,
          ),
        );

        expect(usage.input?.value, 6);
        expect(usage.output?.value, 6);
        expect(
          usage.input?.provenance,
          LlmUsageMetricProvenance.derivedFromProvider,
        );
        expect(
          usage.cacheRead?.provenance,
          LlmUsageMetricProvenance.providerReported,
        );
        expect(
          usage.reasoning?.provenance,
          LlmUsageMetricProvenance.providerReported,
        );
        expect(usage.totalTokens, 18);
        expect(usage.anomalies, isEmpty);
      },
    );

    test('cache miss proves uncached input but never cache write', () {
      final usage = normalizeLlmUsage(
        reportedInputTotal: const LlmUsageCounter.valid(10),
        cacheRead: const LlmUsageCounter.valid(4),
        cacheMiss: const LlmUsageCounter.valid(6),
        semantics: const LlmUsageNormalizationSemantics(
          inputIncludesCacheRead: true,
          cacheMissPartitionsInput: true,
        ),
      );

      expect(usage.input?.value, 6);
      expect(usage.cacheMissEvidence?.value, 6);
      expect(usage.cacheWrite, isNull);
      expect(usage.requestContext?.value, 10);
    });

    test('conflicting and invalid aliases affect only their metric', () {
      final conflict = normalizeLlmUsage(
        reportedInputTotal: LlmUsageCounter.fromAliases(<Object?>[10, 11]),
        reportedOutputTotal: const LlmUsageCounter.valid(4),
        reasoning: LlmUsageCounter.fromAliases(<Object?>[2.0]),
        semantics: const LlmUsageNormalizationSemantics(
          outputIncludesReasoning: true,
        ),
      );

      expect(conflict.reportedInputTotal, isNull);
      expect(conflict.reportedOutputTotal?.value, 4);
      expect(conflict.reasoning, isNull);
      expect(conflict.output, isNull);
      expect(conflict.responseGenerated?.value, 4);
      expect(
        conflict.hasAnomaly(
          LlmUsageAnomalyKind.aliasConflict,
          metric: LlmUsageMetricKind.reportedInputTotal,
        ),
        isTrue,
      );
      expect(
        conflict.hasAnomaly(
          LlmUsageAnomalyKind.invalidValue,
          metric: LlmUsageMetricKind.reasoning,
        ),
        isTrue,
      );
    });

    test('missing operands and impossible children never subtract', () {
      final missing = normalizeLlmUsage(
        reportedInputTotal: const LlmUsageCounter.valid(10),
        semantics: const LlmUsageNormalizationSemantics(
          inputIncludesCacheRead: true,
        ),
      );
      expect(missing.input, isNull);
      expect(missing.requestContext?.value, 10);

      final impossible = normalizeLlmUsage(
        reportedOutputTotal: const LlmUsageCounter.valid(3),
        reasoning: const LlmUsageCounter.valid(4),
        semantics: const LlmUsageNormalizationSemantics(
          outputIncludesReasoning: true,
        ),
      );
      expect(impossible.output, isNull);
      expect(impossible.responseGenerated, isNull);
      expect(impossible.reportedOutputTotal?.value, 3);
      expect(
        impossible.hasAnomaly(
          LlmUsageAnomalyKind.childExceedsParent,
          metric: LlmUsageMetricKind.reportedOutputTotal,
        ),
        isTrue,
      );
    });

    test('an inconsistent overall retains independent valid fields', () {
      final usage = normalizeLlmUsage(
        reportedInputTotal: const LlmUsageCounter.valid(7),
        reportedOutputTotal: const LlmUsageCounter.valid(5),
        reportedOverall: const LlmUsageCounter.valid(10),
      );

      expect(usage.reportedOverallTokens, 10);
      expect(usage.totalTokens, 12);
      expect(usage.inputTokens, 7);
      expect(usage.outputTokens, 5);
    });
  });

  group('cumulative snapshot accumulator', () {
    test(
      'completes and corrects cumulative fields without adding snapshots',
      () {
        final accumulator = LlmUsageSnapshotAccumulator();
        accumulator.reconcile(
          LlmUsage(reportedInputTotal: LlmUsageMetric.providerReported(10)),
        );
        accumulator.reconcile(
          LlmUsage(
            reportedInputTotal: LlmUsageMetric.providerReported(12),
            reportedOutputTotal: LlmUsageMetric.providerReported(3),
            reportedOverall: LlmUsageMetric.providerReported(15),
          ),
        );
        final finalized = accumulator.finalize(
          LlmUsage(
            reportedInputTotal: LlmUsageMetric.providerReported(12),
            reportedOutputTotal: LlmUsageMetric.providerReported(3),
            reportedOverall: LlmUsageMetric.providerReported(15),
          ),
        );

        expect(finalized.inputTokens, 12);
        expect(finalized.outputTokens, 3);
        expect(finalized.totalTokens, 15);
        expect(accumulator.isFinalized, isTrue);
        expect(() => accumulator.finalize(), throwsA(isA<LlmException>()));
        expect(
          () => accumulator.reconcile(LlmUsage(totalTokens: 16)),
          throwsA(isA<LlmException>()),
        );
      },
    );

    test('retains a monotonic value and flags a source decrease', () {
      final accumulator = LlmUsageSnapshotAccumulator(
        LlmUsage(totalTokens: 20),
      );
      final reconciled = accumulator.reconcile(LlmUsage(totalTokens: 18));

      expect(reconciled.totalTokens, 20);
      expect(
        reconciled.hasAnomaly(
          LlmUsageAnomalyKind.snapshotDecrease,
          metric: LlmUsageMetricKind.reportedOverall,
        ),
        isTrue,
      );
    });

    test('empty usage finalizes as unknown rather than fabricated zero', () {
      final finalized = LlmUsageSnapshotAccumulator().finalize();
      expect(finalized.isEmpty, isTrue);
      expect(finalized.totalTokens, isNull);
    });
  });

  test('agent runtime contains no provider-id usage mapping', () {
    final source = File('lib/core/agents/runtime.dart').readAsStringSync();
    expect(source, isNot(contains('prompt_tokens')));
    expect(source, isNot(contains('completion_tokens')));
    expect(source, isNot(contains('input_tokens_details')));
    for (final line in source.split('\n')) {
      expect(
        line.contains('providerId') && line.toLowerCase().contains('usage'),
        isFalse,
        reason:
            'Provider-id usage mapping must remain in adapter dialects: $line',
      );
    }
  });
}

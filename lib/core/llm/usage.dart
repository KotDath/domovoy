import 'errors.dart';
import 'json.dart';

enum LlmFinishReason {
  stop,
  length,
  contentFilter,
  toolCalls,
  unknown;

  static const jsonType = 'llm.finish_reason';

  String get wireName => switch (this) {
    LlmFinishReason.stop => 'stop',
    LlmFinishReason.length => 'length',
    LlmFinishReason.contentFilter => 'content_filter',
    LlmFinishReason.toolCalls => 'tool_calls',
    LlmFinishReason.unknown => 'unknown',
  };

  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'value': wireName});

  static LlmFinishReason fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return fromWireName(requireNonBlankString(map, 'value'));
  }

  static LlmFinishReason fromWireName(String value) {
    return switch (value) {
      'stop' => LlmFinishReason.stop,
      'length' => LlmFinishReason.length,
      'content_filter' => LlmFinishReason.contentFilter,
      'tool_calls' => LlmFinishReason.toolCalls,
      'unknown' => LlmFinishReason.unknown,
      _ => LlmFinishReason.unknown,
    };
  }
}

enum LlmUsageMetricProvenance {
  providerReported,
  derivedFromProvider,
  estimated,
}

enum LlmUsageMetricKind {
  input,
  cacheRead,
  cacheWrite,
  output,
  reasoning,
  reportedInputTotal,
  reportedOutputTotal,
  reportedOverall,
  cacheMissEvidence,
  usage,
}

enum LlmUsageAnomalyKind {
  invalidValue,
  aliasConflict,
  childExceedsParent,
  inconsistentPartition,
  inconsistentTotal,
  snapshotDecrease,
}

enum LlmUsageCompleteness { unavailable, partial, complete }

enum LlmUsageChildInclusion { unknown, included, excluded }

final class LlmUsageParentSemantics {
  const LlmUsageParentSemantics({
    this.inputCacheRead = LlmUsageChildInclusion.unknown,
    this.inputCacheWrite = LlmUsageChildInclusion.unknown,
    this.outputReasoning = LlmUsageChildInclusion.unknown,
  });

  factory LlmUsageParentSemantics.fromJson(Object? json) {
    final map = asJsonObject(json);
    if (map == null) {
      throwLlm(LlmErrorKind.protocol, 'Expected parent semantics object.');
    }
    LlmUsageChildInclusion inclusion(String key) {
      final raw = map[key];
      final value = LlmUsageChildInclusion.values
          .where((candidate) => candidate.name == raw)
          .firstOrNull;
      if (value == null) {
        throwLlm(LlmErrorKind.protocol, 'Unknown parent inclusion semantic.');
      }
      return value;
    }

    return LlmUsageParentSemantics(
      inputCacheRead: inclusion('inputCacheRead'),
      inputCacheWrite: inclusion('inputCacheWrite'),
      outputReasoning: inclusion('outputReasoning'),
    );
  }

  final LlmUsageChildInclusion inputCacheRead;
  final LlmUsageChildInclusion inputCacheWrite;
  final LlmUsageChildInclusion outputReasoning;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'inputCacheRead': inputCacheRead.name,
    'inputCacheWrite': inputCacheWrite.name,
    'outputReasoning': outputReasoning.name,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmUsageParentSemantics &&
          other.inputCacheRead == inputCacheRead &&
          other.inputCacheWrite == inputCacheWrite &&
          other.outputReasoning == outputReasoning;

  @override
  int get hashCode =>
      Object.hash(inputCacheRead, inputCacheWrite, outputReasoning);
}

final class LlmUsageMetric {
  const LlmUsageMetric._(this.value, this.provenance);

  factory LlmUsageMetric.providerReported(int value) => LlmUsageMetric._(
    _requireNonNegative('metric', value),
    LlmUsageMetricProvenance.providerReported,
  );

  factory LlmUsageMetric.derivedFromProvider(int value) => LlmUsageMetric._(
    _requireNonNegative('metric', value),
    LlmUsageMetricProvenance.derivedFromProvider,
  );

  factory LlmUsageMetric.estimated(int value) => LlmUsageMetric._(
    _requireNonNegative('metric', value),
    LlmUsageMetricProvenance.estimated,
  );

  factory LlmUsageMetric.fromJson(Object? json) {
    final map = asJsonObject(json);
    if (map == null) {
      throwLlm(LlmErrorKind.protocol, 'Expected a usage metric object.');
    }
    final value = optionalNonNegativeInt(map, 'value');
    if (value == null) {
      throwLlm(LlmErrorKind.protocol, 'Usage metric value is required.');
    }
    final rawProvenance = map['provenance'];
    final provenance = LlmUsageMetricProvenance.values
        .where((candidate) => candidate.name == rawProvenance)
        .firstOrNull;
    if (provenance == null) {
      throwLlm(LlmErrorKind.protocol, 'Unknown usage metric provenance.');
    }
    return LlmUsageMetric._(value, provenance);
  }

  final int value;
  final LlmUsageMetricProvenance provenance;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'value': value,
    'provenance': provenance.name,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmUsageMetric &&
          other.value == value &&
          other.provenance == provenance;

  @override
  int get hashCode => Object.hash(value, provenance);
}

final class LlmUsageRatio {
  const LlmUsageRatio({required this.value, required this.provenance});

  final double value;
  final LlmUsageMetricProvenance provenance;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmUsageRatio &&
          other.value == value &&
          other.provenance == provenance;

  @override
  int get hashCode => Object.hash(value, provenance);
}

final class LlmUsageAnomaly {
  const LlmUsageAnomaly(this.kind, {this.metric});

  factory LlmUsageAnomaly.fromJson(Object? json) {
    final map = asJsonObject(json);
    if (map == null) {
      throwLlm(LlmErrorKind.protocol, 'Expected a usage anomaly object.');
    }
    final rawKind = map['kind'];
    final kind = LlmUsageAnomalyKind.values
        .where((candidate) => candidate.name == rawKind)
        .firstOrNull;
    if (kind == null) {
      throwLlm(LlmErrorKind.protocol, 'Unknown usage anomaly kind.');
    }
    final rawMetric = map['metric'];
    final metric = rawMetric == null
        ? null
        : LlmUsageMetricKind.values
              .where((candidate) => candidate.name == rawMetric)
              .firstOrNull;
    if (rawMetric != null && metric == null) {
      throwLlm(LlmErrorKind.protocol, 'Unknown usage anomaly metric.');
    }
    return LlmUsageAnomaly(kind, metric: metric);
  }

  final LlmUsageAnomalyKind kind;
  final LlmUsageMetricKind? metric;

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'kind': kind.name,
    if (metric != null) 'metric': metric!.name,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmUsageAnomaly && other.kind == kind && other.metric == metric;

  @override
  int get hashCode => Object.hash(kind, metric);
}

/// A provider-neutral, immutable snapshot for one physical invocation.
///
/// The integer parameters are retained for source compatibility. They have the
/// old coarse meaning and become non-additive provider parent facts. New code
/// should pass canonical [input], [cacheRead], [cacheWrite], [output], and
/// [reasoning] metrics, keeping provider parents separate.
final class LlmUsage {
  factory LlmUsage({
    int? inputTokens,
    int? outputTokens,
    int? totalTokens,
    int? cacheHitTokens,
    int? cacheMissTokens,
    LlmUsageMetric? input,
    LlmUsageMetric? cacheRead,
    LlmUsageMetric? cacheWrite,
    LlmUsageMetric? output,
    LlmUsageMetric? reasoning,
    LlmUsageMetric? reportedInputTotal,
    LlmUsageMetric? reportedOutputTotal,
    LlmUsageMetric? reportedOverall,
    LlmUsageMetric? cacheMissEvidence,
    LlmUsageParentSemantics parentSemantics = const LlmUsageParentSemantics(),
    Iterable<LlmUsageAnomaly> anomalies = const <LlmUsageAnomaly>[],
  }) {
    void rejectBoth(String name, Object? legacy, Object? canonical) {
      if (legacy != null && canonical != null) {
        throwLlm(
          LlmErrorKind.configuration,
          '$name cannot be supplied in both legacy and canonical form.',
        );
      }
    }

    rejectBoth('input', inputTokens, reportedInputTotal);
    rejectBoth('output', outputTokens, reportedOutputTotal);
    rejectBoth('overall', totalTokens, reportedOverall);
    rejectBoth('cache read', cacheHitTokens, cacheRead);
    rejectBoth('cache miss', cacheMissTokens, cacheMissEvidence);
    _assertProviderUsageMetric('input', input);
    _assertProviderUsageMetric('cacheRead', cacheRead);
    _assertProviderUsageMetric('cacheWrite', cacheWrite);
    _assertProviderUsageMetric('output', output);
    _assertProviderUsageMetric('reasoning', reasoning);
    _assertProviderUsageMetric('reportedInputTotal', reportedInputTotal);
    _assertProviderUsageMetric('reportedOutputTotal', reportedOutputTotal);
    _assertProviderUsageMetric('reportedOverall', reportedOverall);
    _assertProviderUsageMetric('cacheMissEvidence', cacheMissEvidence);

    final legacyInput = inputTokens == null
        ? reportedInputTotal
        : LlmUsageMetric.providerReported(inputTokens);
    final legacyOutput = outputTokens == null
        ? reportedOutputTotal
        : LlmUsageMetric.providerReported(outputTokens);
    final legacyOverall = totalTokens == null
        ? reportedOverall
        : LlmUsageMetric.providerReported(totalTokens);
    final legacyCacheRead = cacheHitTokens == null
        ? cacheRead
        : LlmUsageMetric.providerReported(cacheHitTokens);
    final legacyCacheMiss = cacheMissTokens == null
        ? cacheMissEvidence
        : LlmUsageMetric.providerReported(cacheMissTokens);
    var canonicalInput = input;
    if (canonicalInput == null &&
        legacyInput != null &&
        legacyCacheRead != null &&
        legacyCacheMiss != null &&
        legacyInput.value == legacyCacheRead.value + legacyCacheMiss.value) {
      canonicalInput = LlmUsageMetric.derivedFromProvider(
        legacyCacheMiss.value,
      );
    }
    return LlmUsage._validated(
      input: canonicalInput,
      cacheRead: legacyCacheRead,
      cacheWrite: cacheWrite,
      output: output,
      reasoning: reasoning,
      reportedInputTotal: legacyInput,
      reportedOutputTotal: legacyOutput,
      reportedOverall: legacyOverall,
      cacheMissEvidence: legacyCacheMiss,
      parentSemantics: parentSemantics,
      anomalies: anomalies,
    );
  }

  LlmUsage._({
    required this.input,
    required this.cacheRead,
    required this.cacheWrite,
    required this.output,
    required this.reasoning,
    required this.reportedInputTotal,
    required this.reportedOutputTotal,
    required this.reportedOverall,
    required this.cacheMissEvidence,
    required this.parentSemantics,
    required this.anomalies,
  });

  factory LlmUsage._validated({
    required LlmUsageMetric? input,
    required LlmUsageMetric? cacheRead,
    required LlmUsageMetric? cacheWrite,
    required LlmUsageMetric? output,
    required LlmUsageMetric? reasoning,
    required LlmUsageMetric? reportedInputTotal,
    required LlmUsageMetric? reportedOutputTotal,
    required LlmUsageMetric? reportedOverall,
    required LlmUsageMetric? cacheMissEvidence,
    required LlmUsageParentSemantics parentSemantics,
    required Iterable<LlmUsageAnomaly> anomalies,
  }) {
    final checked = <LlmUsageAnomaly>{...anomalies};
    final requestChildren = _knownSum(<LlmUsageMetric?>[
      input,
      if (parentSemantics.inputCacheRead == LlmUsageChildInclusion.included)
        cacheRead,
      if (parentSemantics.inputCacheWrite == LlmUsageChildInclusion.included)
        cacheWrite,
    ]);
    if (reportedInputTotal != null &&
        requestChildren > reportedInputTotal.value) {
      checked.add(
        const LlmUsageAnomaly(
          LlmUsageAnomalyKind.childExceedsParent,
          metric: LlmUsageMetricKind.reportedInputTotal,
        ),
      );
    }
    final responseChildren = _knownSum(<LlmUsageMetric?>[
      output,
      if (parentSemantics.outputReasoning == LlmUsageChildInclusion.included)
        reasoning,
    ]);
    if (reportedOutputTotal != null &&
        responseChildren > reportedOutputTotal.value) {
      checked.add(
        const LlmUsageAnomaly(
          LlmUsageAnomalyKind.childExceedsParent,
          metric: LlmUsageMetricKind.reportedOutputTotal,
        ),
      );
    }
    final requestLowerBound = _consistentParentValue(
      reportedInputTotal,
      checked,
      LlmUsageMetricKind.reportedInputTotal,
    );
    final responseLowerBound = _consistentParentValue(
      reportedOutputTotal,
      checked,
      LlmUsageMetricKind.reportedOutputTotal,
    );
    final knownOverallLowerBound =
        (requestLowerBound ?? requestChildren) +
        (responseLowerBound ?? responseChildren);
    if (reportedOverall != null &&
        reportedOverall.value < knownOverallLowerBound) {
      checked.add(
        const LlmUsageAnomaly(
          LlmUsageAnomalyKind.inconsistentTotal,
          metric: LlmUsageMetricKind.reportedOverall,
        ),
      );
    }
    return LlmUsage._(
      input: input,
      cacheRead: cacheRead,
      cacheWrite: cacheWrite,
      output: output,
      reasoning: reasoning,
      reportedInputTotal: reportedInputTotal,
      reportedOutputTotal: reportedOutputTotal,
      reportedOverall: reportedOverall,
      cacheMissEvidence: cacheMissEvidence,
      parentSemantics: parentSemantics,
      anomalies: Set<LlmUsageAnomaly>.unmodifiable(checked),
    );
  }

  factory LlmUsage.fromJson(Object? json) {
    final map = asJsonObject(json);
    if (map == null || map[llmJsonTypeKey] != jsonType) {
      throwLlm(LlmErrorKind.protocol, 'Expected type "$jsonType".');
    }
    final version = map[llmJsonVersionKey];
    if (version == 1) {
      return LlmUsage(
        inputTokens: optionalNonNegativeInt(map, 'inputTokens'),
        outputTokens: optionalNonNegativeInt(map, 'outputTokens'),
        totalTokens: optionalNonNegativeInt(map, 'totalTokens'),
        cacheHitTokens: optionalNonNegativeInt(map, 'cacheHitTokens'),
        cacheMissTokens: optionalNonNegativeInt(map, 'cacheMissTokens'),
      );
    }
    if (version != jsonVersion) {
      throwLlm(LlmErrorKind.protocol, 'Unsupported version for "$jsonType".');
    }
    LlmUsageMetric? metric(String key) =>
        map[key] == null ? null : LlmUsageMetric.fromJson(map[key]);
    final rawAnomalies = map['anomalies'];
    if (rawAnomalies != null && rawAnomalies is! List) {
      throwLlm(LlmErrorKind.protocol, 'Expected usage anomalies to be a list.');
    }
    return LlmUsage(
      input: metric('input'),
      cacheRead: metric('cacheRead'),
      cacheWrite: metric('cacheWrite'),
      output: metric('output'),
      reasoning: metric('reasoning'),
      reportedInputTotal: metric('reportedInputTotal'),
      reportedOutputTotal: metric('reportedOutputTotal'),
      reportedOverall: metric('reportedOverall'),
      cacheMissEvidence: metric('cacheMissEvidence'),
      parentSemantics: map['parentSemantics'] == null
          ? const LlmUsageParentSemantics()
          : LlmUsageParentSemantics.fromJson(map['parentSemantics']),
      anomalies:
          (rawAnomalies as List?)?.map(LlmUsageAnomaly.fromJson) ??
          const <LlmUsageAnomaly>[],
    );
  }

  static const jsonType = 'llm.usage';
  static const jsonVersion = 2;

  /// Mutually exclusive uncached request tokens.
  final LlmUsageMetric? input;
  final LlmUsageMetric? cacheRead;
  final LlmUsageMetric? cacheWrite;

  /// Mutually exclusive non-reasoning generated tokens.
  final LlmUsageMetric? output;
  final LlmUsageMetric? reasoning;
  final LlmUsageMetric? reportedInputTotal;
  final LlmUsageMetric? reportedOutputTotal;
  final LlmUsageMetric? reportedOverall;
  final LlmUsageMetric? cacheMissEvidence;
  final LlmUsageParentSemantics parentSemantics;
  final Set<LlmUsageAnomaly> anomalies;

  bool get isEmpty =>
      input == null &&
      cacheRead == null &&
      cacheWrite == null &&
      output == null &&
      reasoning == null &&
      reportedInputTotal == null &&
      reportedOutputTotal == null &&
      reportedOverall == null &&
      cacheMissEvidence == null &&
      anomalies.isEmpty;

  bool get requestDecompositionIsComplete =>
      input != null && cacheRead != null && cacheWrite != null;

  bool get responseDecompositionIsComplete =>
      output != null && reasoning != null;

  LlmUsageCompleteness get requestCompleteness => _completeness(
    complete: requestDecompositionIsComplete,
    present: <Object?>[
      input,
      cacheRead,
      cacheWrite,
      reportedInputTotal,
      cacheMissEvidence,
    ].any((value) => value != null),
  );

  LlmUsageCompleteness get responseCompleteness => _completeness(
    complete: responseDecompositionIsComplete,
    present: <Object?>[
      output,
      reasoning,
      reportedOutputTotal,
    ].any((value) => value != null),
  );

  LlmUsageMetric? get requestContext {
    if (_parentIsConsistent(LlmUsageMetricKind.reportedInputTotal) &&
        !_hasPositiveExcludedRequestChild) {
      return reportedInputTotal;
    }
    if (!requestDecompositionIsComplete) {
      return null;
    }
    return LlmUsageMetric.derivedFromProvider(
      input!.value + cacheRead!.value + cacheWrite!.value,
    );
  }

  LlmUsageMetric? get responseGenerated {
    if (_parentIsConsistent(LlmUsageMetricKind.reportedOutputTotal) &&
        !_hasPositiveExcludedReasoning) {
      return reportedOutputTotal;
    }
    if (!responseDecompositionIsComplete) {
      return null;
    }
    return LlmUsageMetric.derivedFromProvider(output!.value + reasoning!.value);
  }

  LlmUsageMetric? get overall {
    if (reportedOverall != null &&
        !hasAnomaly(
          LlmUsageAnomalyKind.inconsistentTotal,
          metric: LlmUsageMetricKind.reportedOverall,
        )) {
      return reportedOverall;
    }
    if (_parentIsConsistent(LlmUsageMetricKind.reportedInputTotal) &&
        _parentIsConsistent(LlmUsageMetricKind.reportedOutputTotal)) {
      return LlmUsageMetric.derivedFromProvider(
        reportedInputTotal!.value + reportedOutputTotal!.value,
      );
    }
    if (requestDecompositionIsComplete && responseDecompositionIsComplete) {
      return LlmUsageMetric.derivedFromProvider(
        input!.value +
            cacheRead!.value +
            cacheWrite!.value +
            output!.value +
            reasoning!.value,
      );
    }
    return null;
  }

  LlmUsageCompleteness get overallCompleteness =>
      _completeness(complete: overall != null, present: !isEmpty);

  LlmUsageRatio? get cacheHitRatio {
    final denominator = requestContext;
    if (cacheRead == null || denominator == null || denominator.value <= 0) {
      return null;
    }
    return LlmUsageRatio(
      value: cacheRead!.value / denominator.value,
      provenance: LlmUsageMetricProvenance.derivedFromProvider,
    );
  }

  /// Coarse compatibility projections retained for existing runtime callers.
  int? get inputTokens => requestContext?.value;
  int? get outputTokens => responseGenerated?.value;
  int? get totalTokens => overall?.value;
  int? get cacheHitTokens => cacheRead?.value;
  int? get cacheMissTokens => cacheMissEvidence?.value;
  int? get reportedInputTotalTokens => reportedInputTotal?.value;
  int? get reportedOutputTotalTokens => reportedOutputTotal?.value;
  int? get reportedOverallTokens => reportedOverall?.value;

  bool hasAnomaly(LlmUsageAnomalyKind kind, {LlmUsageMetricKind? metric}) =>
      anomalies.any(
        (anomaly) =>
            anomaly.kind == kind &&
            (metric == null || anomaly.metric == metric),
      );

  bool _parentIsConsistent(LlmUsageMetricKind metric) {
    final parent = switch (metric) {
      LlmUsageMetricKind.reportedInputTotal => reportedInputTotal,
      LlmUsageMetricKind.reportedOutputTotal => reportedOutputTotal,
      _ => null,
    };
    return parent != null &&
        !hasAnomaly(LlmUsageAnomalyKind.childExceedsParent, metric: metric) &&
        !hasAnomaly(LlmUsageAnomalyKind.inconsistentPartition, metric: metric);
  }

  bool get _hasPositiveExcludedRequestChild =>
      (parentSemantics.inputCacheRead == LlmUsageChildInclusion.excluded &&
          (cacheRead?.value ?? 0) > 0) ||
      (parentSemantics.inputCacheWrite == LlmUsageChildInclusion.excluded &&
          (cacheWrite?.value ?? 0) > 0);

  bool get _hasPositiveExcludedReasoning =>
      parentSemantics.outputReasoning == LlmUsageChildInclusion.excluded &&
      (reasoning?.value ?? 0) > 0;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    version: jsonVersion,
    fields: <String, Object?>{
      if (input != null) 'input': input!.toJson(),
      if (cacheRead != null) 'cacheRead': cacheRead!.toJson(),
      if (cacheWrite != null) 'cacheWrite': cacheWrite!.toJson(),
      if (output != null) 'output': output!.toJson(),
      if (reasoning != null) 'reasoning': reasoning!.toJson(),
      if (reportedInputTotal != null)
        'reportedInputTotal': reportedInputTotal!.toJson(),
      if (reportedOutputTotal != null)
        'reportedOutputTotal': reportedOutputTotal!.toJson(),
      if (reportedOverall != null) 'reportedOverall': reportedOverall!.toJson(),
      if (cacheMissEvidence != null)
        'cacheMissEvidence': cacheMissEvidence!.toJson(),
      'parentSemantics': parentSemantics.toJson(),
      if (anomalies.isNotEmpty)
        'anomalies':
            (anomalies.toList()..sort((a, b) {
                  final kind = a.kind.index.compareTo(b.kind.index);
                  return kind != 0
                      ? kind
                      : (a.metric?.index ?? -1).compareTo(
                          b.metric?.index ?? -1,
                        );
                }))
                .map((anomaly) => anomaly.toJson())
                .toList(growable: false),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmUsage &&
          other.input == input &&
          other.cacheRead == cacheRead &&
          other.cacheWrite == cacheWrite &&
          other.output == output &&
          other.reasoning == reasoning &&
          other.reportedInputTotal == reportedInputTotal &&
          other.reportedOutputTotal == reportedOutputTotal &&
          other.reportedOverall == reportedOverall &&
          other.cacheMissEvidence == cacheMissEvidence &&
          other.parentSemantics == parentSemantics &&
          _setEquals(other.anomalies, anomalies);

  @override
  int get hashCode => Object.hash(
    input,
    cacheRead,
    cacheWrite,
    output,
    reasoning,
    reportedInputTotal,
    reportedOutputTotal,
    reportedOverall,
    cacheMissEvidence,
    parentSemantics,
    Object.hashAllUnordered(anomalies),
  );
}

enum LlmUsageCounterState { absent, valid, invalid, conflicting }

/// A sanitized semantic counter extracted from one or more wire aliases.
final class LlmUsageCounter {
  const LlmUsageCounter.absent()
    : state = LlmUsageCounterState.absent,
      value = null;

  const LlmUsageCounter.valid(this.value)
    : assert(value != null && value >= 0),
      state = LlmUsageCounterState.valid;

  const LlmUsageCounter.invalid()
    : state = LlmUsageCounterState.invalid,
      value = null;

  const LlmUsageCounter.conflicting()
    : state = LlmUsageCounterState.conflicting,
      value = null;

  factory LlmUsageCounter.fromAliases(Iterable<Object?> aliases) {
    int? selected;
    var sawValue = false;
    var invalid = false;
    var conflict = false;
    for (final raw in aliases) {
      if (raw == null) {
        continue;
      }
      sawValue = true;
      if (raw is! int || raw < 0) {
        invalid = true;
        continue;
      }
      if (selected == null) {
        selected = raw;
      } else if (selected != raw) {
        conflict = true;
      }
    }
    if (!sawValue) {
      return const LlmUsageCounter.absent();
    }
    if (conflict) {
      return const LlmUsageCounter.conflicting();
    }
    if (invalid || selected == null) {
      return const LlmUsageCounter.invalid();
    }
    return LlmUsageCounter.valid(selected);
  }

  final LlmUsageCounterState state;
  final int? value;
}

final class LlmUsageNormalizationSemantics {
  const LlmUsageNormalizationSemantics({
    this.inputIncludesCacheRead = false,
    this.inputIncludesCacheWrite = false,
    this.outputIncludesReasoning = false,
    this.cacheMissPartitionsInput = false,
  });

  final bool inputIncludesCacheRead;
  final bool inputIncludesCacheWrite;
  final bool outputIncludesReasoning;
  final bool cacheMissPartitionsInput;
}

/// Normalizes already-extracted semantic counters without knowing a provider id.
LlmUsage normalizeLlmUsage({
  LlmUsageCounter input = const LlmUsageCounter.absent(),
  LlmUsageCounter cacheRead = const LlmUsageCounter.absent(),
  LlmUsageCounter cacheWrite = const LlmUsageCounter.absent(),
  LlmUsageCounter output = const LlmUsageCounter.absent(),
  LlmUsageCounter reasoning = const LlmUsageCounter.absent(),
  LlmUsageCounter reportedInputTotal = const LlmUsageCounter.absent(),
  LlmUsageCounter reportedOutputTotal = const LlmUsageCounter.absent(),
  LlmUsageCounter reportedOverall = const LlmUsageCounter.absent(),
  LlmUsageCounter cacheMiss = const LlmUsageCounter.absent(),
  LlmUsageNormalizationSemantics semantics =
      const LlmUsageNormalizationSemantics(),
  Iterable<LlmUsageAnomaly> additionalAnomalies = const <LlmUsageAnomaly>[],
}) {
  final anomalies = <LlmUsageAnomaly>{...additionalAnomalies};
  LlmUsageMetric? reported(LlmUsageCounter counter, LlmUsageMetricKind kind) {
    switch (counter.state) {
      case LlmUsageCounterState.absent:
        return null;
      case LlmUsageCounterState.valid:
        return LlmUsageMetric.providerReported(counter.value!);
      case LlmUsageCounterState.invalid:
        anomalies.add(
          LlmUsageAnomaly(LlmUsageAnomalyKind.invalidValue, metric: kind),
        );
        return null;
      case LlmUsageCounterState.conflicting:
        anomalies.add(
          LlmUsageAnomaly(LlmUsageAnomalyKind.aliasConflict, metric: kind),
        );
        return null;
    }
  }

  var normalizedInput = reported(input, LlmUsageMetricKind.input);
  final normalizedCacheRead = reported(cacheRead, LlmUsageMetricKind.cacheRead);
  final normalizedCacheWrite = reported(
    cacheWrite,
    LlmUsageMetricKind.cacheWrite,
  );
  var normalizedOutput = reported(output, LlmUsageMetricKind.output);
  final normalizedReasoning = reported(reasoning, LlmUsageMetricKind.reasoning);
  final inputParent = reported(
    reportedInputTotal,
    LlmUsageMetricKind.reportedInputTotal,
  );
  final outputParent = reported(
    reportedOutputTotal,
    LlmUsageMetricKind.reportedOutputTotal,
  );
  final overallParent = reported(
    reportedOverall,
    LlmUsageMetricKind.reportedOverall,
  );
  final missEvidence = reported(
    cacheMiss,
    LlmUsageMetricKind.cacheMissEvidence,
  );

  if (normalizedInput == null && input.state == LlmUsageCounterState.absent) {
    if (semantics.cacheMissPartitionsInput &&
        cacheMiss.state != LlmUsageCounterState.absent) {
      if (inputParent != null &&
          normalizedCacheRead != null &&
          missEvidence != null) {
        final partition =
            normalizedCacheRead.value +
            missEvidence.value +
            (semantics.inputIncludesCacheWrite
                ? normalizedCacheWrite?.value ?? -1
                : 0);
        if (partition == inputParent.value) {
          normalizedInput = LlmUsageMetric.derivedFromProvider(
            missEvidence.value,
          );
        } else {
          anomalies.add(
            const LlmUsageAnomaly(
              LlmUsageAnomalyKind.inconsistentPartition,
              metric: LlmUsageMetricKind.reportedInputTotal,
            ),
          );
        }
      }
    } else if (inputParent != null) {
      final requiredChildren = <LlmUsageMetric?>[
        if (semantics.inputIncludesCacheRead) normalizedCacheRead,
        if (semantics.inputIncludesCacheWrite) normalizedCacheWrite,
      ];
      if (requiredChildren.every((child) => child != null)) {
        final childTotal = _knownSum(requiredChildren);
        if (childTotal <= inputParent.value) {
          normalizedInput = LlmUsageMetric.derivedFromProvider(
            inputParent.value - childTotal,
          );
        } else {
          anomalies.add(
            const LlmUsageAnomaly(
              LlmUsageAnomalyKind.childExceedsParent,
              metric: LlmUsageMetricKind.reportedInputTotal,
            ),
          );
        }
      }
    }
  }

  if (normalizedOutput == null &&
      output.state == LlmUsageCounterState.absent &&
      outputParent != null) {
    if (!semantics.outputIncludesReasoning || normalizedReasoning != null) {
      final reasoningValue = semantics.outputIncludesReasoning
          ? normalizedReasoning!.value
          : 0;
      if (reasoningValue <= outputParent.value) {
        normalizedOutput = LlmUsageMetric.derivedFromProvider(
          outputParent.value - reasoningValue,
        );
      } else {
        anomalies.add(
          const LlmUsageAnomaly(
            LlmUsageAnomalyKind.childExceedsParent,
            metric: LlmUsageMetricKind.reportedOutputTotal,
          ),
        );
      }
    }
  }

  return LlmUsage(
    input: normalizedInput,
    cacheRead: normalizedCacheRead,
    cacheWrite: normalizedCacheWrite,
    output: normalizedOutput,
    reasoning: normalizedReasoning,
    reportedInputTotal: inputParent,
    reportedOutputTotal: outputParent,
    reportedOverall: overallParent,
    cacheMissEvidence: missEvidence,
    parentSemantics: LlmUsageParentSemantics(
      inputCacheRead: semantics.inputIncludesCacheRead
          ? LlmUsageChildInclusion.included
          : LlmUsageChildInclusion.excluded,
      inputCacheWrite: semantics.inputIncludesCacheWrite
          ? LlmUsageChildInclusion.included
          : LlmUsageChildInclusion.excluded,
      outputReasoning: semantics.outputIncludesReasoning
          ? LlmUsageChildInclusion.included
          : LlmUsageChildInclusion.excluded,
    ),
    anomalies: anomalies,
  );
}

/// Reconciles source-ordered cumulative snapshots for one invocation.
final class LlmUsageSnapshotAccumulator {
  LlmUsageSnapshotAccumulator([LlmUsage? initial])
    : _snapshot = initial ?? LlmUsage();

  LlmUsage _snapshot;
  bool _isFinalized = false;

  LlmUsage get snapshot => _snapshot;
  bool get isFinalized => _isFinalized;

  LlmUsage reconcile(LlmUsage incoming) {
    if (_isFinalized) {
      throwLlm(
        LlmErrorKind.configuration,
        'A finalized usage accumulator cannot accept another snapshot.',
      );
    }
    final anomalies = <LlmUsageAnomaly>{
      ..._snapshot.anomalies,
      ...incoming.anomalies,
    };
    LlmUsageMetric? metric(
      LlmUsageMetric? current,
      LlmUsageMetric? next,
      LlmUsageMetricKind kind,
    ) {
      if (next == null) {
        return current;
      }
      if (current == null || next.value > current.value) {
        return next;
      }
      if (next.value < current.value) {
        anomalies.add(
          LlmUsageAnomaly(LlmUsageAnomalyKind.snapshotDecrease, metric: kind),
        );
        return current;
      }
      return _provenanceRank(next.provenance) >
              _provenanceRank(current.provenance)
          ? next
          : current;
    }

    _snapshot = LlmUsage(
      input: metric(_snapshot.input, incoming.input, LlmUsageMetricKind.input),
      cacheRead: metric(
        _snapshot.cacheRead,
        incoming.cacheRead,
        LlmUsageMetricKind.cacheRead,
      ),
      cacheWrite: metric(
        _snapshot.cacheWrite,
        incoming.cacheWrite,
        LlmUsageMetricKind.cacheWrite,
      ),
      output: metric(
        _snapshot.output,
        incoming.output,
        LlmUsageMetricKind.output,
      ),
      reasoning: metric(
        _snapshot.reasoning,
        incoming.reasoning,
        LlmUsageMetricKind.reasoning,
      ),
      reportedInputTotal: metric(
        _snapshot.reportedInputTotal,
        incoming.reportedInputTotal,
        LlmUsageMetricKind.reportedInputTotal,
      ),
      reportedOutputTotal: metric(
        _snapshot.reportedOutputTotal,
        incoming.reportedOutputTotal,
        LlmUsageMetricKind.reportedOutputTotal,
      ),
      reportedOverall: metric(
        _snapshot.reportedOverall,
        incoming.reportedOverall,
        LlmUsageMetricKind.reportedOverall,
      ),
      cacheMissEvidence: metric(
        _snapshot.cacheMissEvidence,
        incoming.cacheMissEvidence,
        LlmUsageMetricKind.cacheMissEvidence,
      ),
      parentSemantics: _snapshot.isEmpty
          ? incoming.parentSemantics
          : _snapshot.parentSemantics,
      anomalies: anomalies,
    );
    return _snapshot;
  }

  LlmUsage finalize([LlmUsage? terminal]) {
    if (_isFinalized) {
      throwLlm(
        LlmErrorKind.configuration,
        'Usage for this invocation has already been finalized.',
      );
    }
    if (terminal != null) {
      reconcile(terminal);
    }
    _isFinalized = true;
    return _snapshot;
  }
}

LlmUsageCompleteness _completeness({
  required bool complete,
  required bool present,
}) {
  if (complete) {
    return LlmUsageCompleteness.complete;
  }
  return present
      ? LlmUsageCompleteness.partial
      : LlmUsageCompleteness.unavailable;
}

int _knownSum(Iterable<LlmUsageMetric?> metrics) => metrics
    .whereType<LlmUsageMetric>()
    .fold<int>(0, (sum, metric) => sum + metric.value);

int? _consistentParentValue(
  LlmUsageMetric? parent,
  Set<LlmUsageAnomaly> anomalies,
  LlmUsageMetricKind kind,
) {
  if (parent == null ||
      anomalies.any(
        (anomaly) =>
            anomaly.metric == kind &&
            (anomaly.kind == LlmUsageAnomalyKind.childExceedsParent ||
                anomaly.kind == LlmUsageAnomalyKind.inconsistentPartition),
      )) {
    return null;
  }
  return parent.value;
}

int _provenanceRank(LlmUsageMetricProvenance provenance) =>
    switch (provenance) {
      LlmUsageMetricProvenance.estimated => 0,
      LlmUsageMetricProvenance.derivedFromProvider => 1,
      LlmUsageMetricProvenance.providerReported => 2,
    };

void _assertProviderUsageMetric(String name, LlmUsageMetric? metric) {
  if (metric?.provenance == LlmUsageMetricProvenance.estimated) {
    throwLlm(
      LlmErrorKind.configuration,
      '$name cannot use estimated provenance in provider usage.',
    );
  }
}

int _requireNonNegative(String name, int value) {
  if (value < 0) {
    throwLlm(
      LlmErrorKind.configuration,
      '$name must be a non-negative integer.',
    );
  }
  return value;
}

bool _setEquals<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

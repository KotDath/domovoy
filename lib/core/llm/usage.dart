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

final class LlmUsage {
  LlmUsage({
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.cacheHitTokens,
    this.cacheMissTokens,
  }) {
    _assertNonNegative('inputTokens', inputTokens);
    _assertNonNegative('outputTokens', outputTokens);
    _assertNonNegative('totalTokens', totalTokens);
    _assertNonNegative('cacheHitTokens', cacheHitTokens);
    _assertNonNegative('cacheMissTokens', cacheMissTokens);
  }

  factory LlmUsage.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmUsage(
      inputTokens: optionalNonNegativeInt(map, 'inputTokens'),
      outputTokens: optionalNonNegativeInt(map, 'outputTokens'),
      totalTokens: optionalNonNegativeInt(map, 'totalTokens'),
      cacheHitTokens: optionalNonNegativeInt(map, 'cacheHitTokens'),
      cacheMissTokens: optionalNonNegativeInt(map, 'cacheMissTokens'),
    );
  }

  static const jsonType = 'llm.usage';

  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final int? cacheHitTokens;
  final int? cacheMissTokens;

  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      totalTokens == null &&
      cacheHitTokens == null &&
      cacheMissTokens == null;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{};
    if (inputTokens != null) {
      fields['inputTokens'] = inputTokens;
    }
    if (outputTokens != null) {
      fields['outputTokens'] = outputTokens;
    }
    if (totalTokens != null) {
      fields['totalTokens'] = totalTokens;
    }
    if (cacheHitTokens != null) {
      fields['cacheHitTokens'] = cacheHitTokens;
    }
    if (cacheMissTokens != null) {
      fields['cacheMissTokens'] = cacheMissTokens;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmUsage &&
          other.inputTokens == inputTokens &&
          other.outputTokens == outputTokens &&
          other.totalTokens == totalTokens &&
          other.cacheHitTokens == cacheHitTokens &&
          other.cacheMissTokens == cacheMissTokens;

  @override
  int get hashCode => Object.hash(
    inputTokens,
    outputTokens,
    totalTokens,
    cacheHitTokens,
    cacheMissTokens,
  );
}

void _assertNonNegative(String name, int? value) {
  if (value != null && value < 0) {
    throwLlm(
      LlmErrorKind.configuration,
      '$name must be a non-negative integer.',
    );
  }
}

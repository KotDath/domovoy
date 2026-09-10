import 'errors.dart';
import 'json.dart';

enum ReasoningMode {
  enabled,
  disabled;

  static ReasoningMode fromName(String value) {
    return switch (value) {
      'enabled' => ReasoningMode.enabled,
      'disabled' => ReasoningMode.disabled,
      _ => throwLlm(LlmErrorKind.protocol, 'Unknown reasoning mode "$value".'),
    };
  }
}

enum ReasoningEffort {
  modelDefault,
  low,
  medium,
  high,
  max;

  static ReasoningEffort fromName(String value) {
    return switch (value) {
      'modelDefault' => ReasoningEffort.modelDefault,
      'low' => ReasoningEffort.low,
      'medium' => ReasoningEffort.medium,
      'high' => ReasoningEffort.high,
      'max' => ReasoningEffort.max,
      _ => throwLlm(
        LlmErrorKind.protocol,
        'Unknown reasoning effort "$value".',
      ),
    };
  }

  bool get isExplicit => this != ReasoningEffort.modelDefault;
}

enum ModelReasoningCapability {
  unsupported,
  optional,
  required;

  static ModelReasoningCapability fromName(String value) {
    return switch (value) {
      'unsupported' => ModelReasoningCapability.unsupported,
      'optional' => ModelReasoningCapability.optional,
      'required' => ModelReasoningCapability.required,
      _ => throwLlm(
        LlmErrorKind.protocol,
        'Unknown reasoning capability "$value".',
      ),
    };
  }
}

final class LlmGenerationConfig {
  LlmGenerationConfig({
    this.reasoningMode = ReasoningMode.enabled,
    this.reasoningEffort = ReasoningEffort.modelDefault,
    double? temperature,
    int? maxOutputTokens,
  }) : temperature = _validateTemperature(temperature),
       maxOutputTokens = _validateMaxOutputTokens(maxOutputTokens) {
    if (reasoningMode == ReasoningMode.disabled &&
        reasoningEffort != ReasoningEffort.modelDefault) {
      throwLlm(
        LlmErrorKind.configuration,
        'Disabled reasoning cannot carry an explicit effort.',
      );
    }
  }

  factory LlmGenerationConfig.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmGenerationConfig(
      reasoningMode: ReasoningMode.fromName(
        requireNonBlankString(map, 'reasoningMode'),
      ),
      reasoningEffort: map['reasoningEffort'] == null
          ? ReasoningEffort.modelDefault
          : ReasoningEffort.fromName(
              requireNonBlankString(map, 'reasoningEffort'),
            ),
      temperature: optionalFiniteDouble(map, 'temperature'),
      maxOutputTokens: optionalNonNegativeInt(map, 'maxOutputTokens') == null
          ? null
          : requirePositiveInt(map, 'maxOutputTokens'),
    );
  }

  static const jsonType = 'llm.generation_config';

  static final defaults = LlmGenerationConfig();

  final ReasoningMode reasoningMode;
  final ReasoningEffort reasoningEffort;
  final double? temperature;
  final int? maxOutputTokens;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{
      'reasoningMode': reasoningMode.name,
      'reasoningEffort': reasoningEffort.name,
    };
    if (temperature != null) {
      fields['temperature'] = temperature;
    }
    if (maxOutputTokens != null) {
      fields['maxOutputTokens'] = maxOutputTokens;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmGenerationConfig &&
          other.reasoningMode == reasoningMode &&
          other.reasoningEffort == reasoningEffort &&
          other.temperature == temperature &&
          other.maxOutputTokens == maxOutputTokens;

  @override
  int get hashCode =>
      Object.hash(reasoningMode, reasoningEffort, temperature, maxOutputTokens);
}

double? _validateTemperature(double? temperature) {
  if (temperature == null) {
    return null;
  }
  if (temperature.isNaN || temperature.isInfinite) {
    throwLlm(
      LlmErrorKind.configuration,
      'Temperature must be a finite number.',
    );
  }
  if (temperature < 0 || temperature > 2) {
    throwLlm(
      LlmErrorKind.configuration,
      'Temperature must be between 0.0 and 2.0.',
    );
  }
  return temperature;
}

int? _validateMaxOutputTokens(int? maxOutputTokens) {
  if (maxOutputTokens == null) {
    return null;
  }
  if (maxOutputTokens <= 0) {
    throwLlm(
      LlmErrorKind.configuration,
      'maxOutputTokens must be a positive integer.',
    );
  }
  return maxOutputTokens;
}

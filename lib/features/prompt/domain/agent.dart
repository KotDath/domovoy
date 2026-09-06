enum AgentFailureKind {
  configuration,
  authentication,
  rateLimit,
  provider,
  network,
  protocol,
  interrupted,
  unknown,
}

enum ThinkingMode { enabled, disabled }

enum ResponseFormatKind { json, markdown }

enum AgentFinishReason {
  stop,
  length,
  contentFilter,
  toolCalls,
  insufficientSystemResource,
  unknown,
}

final class AgentTokenUsage {
  const AgentTokenUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.cacheHitPromptTokens,
    this.cacheMissPromptTokens,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? cacheHitPromptTokens;
  final int? cacheMissPromptTokens;

  bool get isEmpty =>
      promptTokens == null &&
      completionTokens == null &&
      totalTokens == null &&
      cacheHitPromptTokens == null &&
      cacheMissPromptTokens == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTokenUsage &&
          other.promptTokens == promptTokens &&
          other.completionTokens == completionTokens &&
          other.totalTokens == totalTokens &&
          other.cacheHitPromptTokens == cacheHitPromptTokens &&
          other.cacheMissPromptTokens == cacheMissPromptTokens;

  @override
  int get hashCode => Object.hash(
    promptTokens,
    completionTokens,
    totalTokens,
    cacheHitPromptTokens,
    cacheMissPromptTokens,
  );

  @override
  String toString() =>
      'AgentTokenUsage(prompt: $promptTokens, '
      'completion: $completionTokens, total: $totalTokens, '
      'cacheHit: $cacheHitPromptTokens, cacheMiss: $cacheMissPromptTokens)';
}

sealed class ResponseControl {
  const ResponseControl();
}

final class FormatControl extends ResponseControl {
  FormatControl({
    required this.kind,
    required this.contractText,
    this.exampleText,
    bool? useJsonMode,
  }) : useJsonModeResolved = useJsonMode ?? (kind == ResponseFormatKind.json) {
    if (contractText.trim().isEmpty) {
      throw ArgumentError.value(
        contractText,
        'contractText',
        'Format contract must not be empty.',
      );
    }
  }

  final ResponseFormatKind kind;
  final String contractText;
  final String? exampleText;
  final bool useJsonModeResolved;
}

final class LengthControl extends ResponseControl {
  LengthControl({required this.maxChars, required this.maxTokens}) {
    if (maxChars <= 0) {
      throw ArgumentError.value(
        maxChars,
        'maxChars',
        'Character target must be positive.',
      );
    }
    if (maxTokens <= 0) {
      throw ArgumentError.value(
        maxTokens,
        'maxTokens',
        'Maximum tokens must be positive.',
      );
    }
  }

  final int maxChars;
  final int maxTokens;
}

final class StopControl extends ResponseControl {
  StopControl(String marker) : marker = marker.trim() {
    if (this.marker.isEmpty) {
      throw ArgumentError.value(
        marker,
        'marker',
        'Stop marker must not be empty.',
      );
    }
  }

  final String marker;
}

final class AgentInput {
  AgentInput(
    String text, {
    this.thinking = ThinkingMode.enabled,
    this.control,
    this.temperature,
  }) : text = text.trim() {
    if (this.text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Prompt must not be empty.');
    }
    final temperature = this.temperature;
    if (temperature != null &&
        (!temperature.isFinite || temperature < 0.0 || temperature > 2.0)) {
      throw ArgumentError.value(
        temperature,
        'temperature',
        'Temperature must be a finite value from 0.0 through 2.0.',
      );
    }
  }

  final String text;
  final ThinkingMode thinking;
  final ResponseControl? control;
  final double? temperature;

  bool get isUnrestricted => control == null;
}

abstract interface class Agent {
  Stream<AgentEvent> prompt(AgentInput input);
}

sealed class AgentEvent {
  const AgentEvent();
}

final class AgentReasoningDelta extends AgentEvent {
  const AgentReasoningDelta(this.text);

  final String text;
}

final class AgentAnswerDelta extends AgentEvent {
  const AgentAnswerDelta(this.text);

  final String text;
}

final class AgentCompleted extends AgentEvent {
  const AgentCompleted({this.finishReason, this.usage});

  final AgentFinishReason? finishReason;
  final AgentTokenUsage? usage;
}

final class AgentFailed extends AgentEvent {
  const AgentFailed(this.failure);

  final AgentFailure failure;
}

final class AgentFailure {
  const AgentFailure({required this.kind, required this.message});

  final AgentFailureKind kind;
  final String message;

  bool get isMissingCredential => kind == AgentFailureKind.configuration;
}

String agentFinishReasonLabel(AgentFinishReason? reason) => switch (reason) {
  AgentFinishReason.stop => 'stop',
  AgentFinishReason.length => 'length',
  AgentFinishReason.contentFilter => 'content_filter',
  AgentFinishReason.toolCalls => 'tool_calls',
  AgentFinishReason.insufficientSystemResource =>
    'insufficient_system_resource',
  AgentFinishReason.unknown => 'unknown',
  null => '—',
};

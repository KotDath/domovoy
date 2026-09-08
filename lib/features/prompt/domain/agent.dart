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

final class AgentInput {
  AgentInput(String text, {this.thinking = ThinkingMode.enabled})
    : text = text.trim() {
    if (this.text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Prompt must not be empty.');
    }
  }

  final String text;
  final ThinkingMode thinking;
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

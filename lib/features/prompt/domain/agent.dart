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

final class AgentInput {
  AgentInput(String text) : text = text.trim() {
    if (this.text.isEmpty) {
      throw ArgumentError.value(text, 'text', 'Prompt must not be empty.');
    }
  }

  final String text;
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
  const AgentCompleted();
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

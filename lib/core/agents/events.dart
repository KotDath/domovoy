import '../llm/errors.dart';
import '../llm/identifiers.dart';
import '../llm/messages.dart';
import '../llm/usage.dart';
import 'errors.dart';
import 'ids.dart';
import 'policies.dart';

enum AgentStopReason {
  modelTurnLimit,
  toolCallLimit,
  durationLimit,
  idleTimeout,
  noProgress,
  inputBudget,
  outputBudget,
  totalBudget,
}

enum AgentSessionLifecycle { idle, running, closing, closed }

sealed class AgentRunEvent {
  const AgentRunEvent();

  bool get isTerminal =>
      this is AgentRunCompleted ||
      this is AgentRunStopped ||
      this is AgentRunFailed ||
      this is AgentRunCancelled;
}

final class AgentRunStarted extends AgentRunEvent {
  const AgentRunStarted({required this.runId, required this.sessionId});

  final RunId runId;
  final AgentSessionId sessionId;
}

final class AgentInboundMessageConsumed extends AgentRunEvent {
  const AgentInboundMessageConsumed({
    required this.source,
    required this.message,
    this.correlationId,
    this.replyTo,
  });

  final AgentSessionId source;
  final LlmMessage message;
  final CorrelationId? correlationId;
  final MessageId? replyTo;
}

final class AgentReasoningDelta extends AgentRunEvent {
  const AgentReasoningDelta(this.text);

  final String text;
}

final class AgentAnswerDelta extends AgentRunEvent {
  const AgentAnswerDelta(this.text);

  final String text;
}

final class AgentToolAssembled extends AgentRunEvent {
  AgentToolAssembled(List<LlmToolCallPart> calls)
    : calls = List<LlmToolCallPart>.unmodifiable(
        List<LlmToolCallPart>.from(calls),
      );

  final List<LlmToolCallPart> calls;
}

final class AgentPermissionDecision extends AgentRunEvent {
  const AgentPermissionDecision({
    required this.callId,
    required this.permission,
  });

  final ToolCallId callId;
  final ToolPermission permission;
}

final class AgentToolStarted extends AgentRunEvent {
  const AgentToolStarted({required this.callId, required this.name});

  final ToolCallId callId;
  final String name;
}

final class AgentToolProgress extends AgentRunEvent {
  const AgentToolProgress({required this.callId, this.detail});

  final ToolCallId callId;
  final String? detail;
}

final class AgentToolFinished extends AgentRunEvent {
  const AgentToolFinished({required this.callId, required this.success});

  final ToolCallId callId;
  final bool success;
}

final class AgentUsageUpdated extends AgentRunEvent {
  const AgentUsageUpdated(this.usage);

  final LlmUsage usage;
}

final class AgentNoProgressWarning extends AgentRunEvent {
  const AgentNoProgressWarning(this.consecutiveCycles);

  final int consecutiveCycles;
}

final class AgentRunCompleted extends AgentRunEvent {
  const AgentRunCompleted({this.finishReason, this.usage});

  final LlmFinishReason? finishReason;
  final LlmUsage? usage;
}

final class AgentRunStopped extends AgentRunEvent {
  const AgentRunStopped(this.reason, {this.usage});

  final AgentStopReason reason;
  final LlmUsage? usage;
}

final class AgentRunFailed extends AgentRunEvent {
  const AgentRunFailed(this.error);

  final AgentError error;
}

final class AgentRunCancelled extends AgentRunEvent {
  const AgentRunCancelled();
}

AgentError agentErrorFromLlm(LlmError error) {
  final kind = switch (error.kind) {
    LlmErrorKind.configuration => AgentErrorKind.configuration,
    LlmErrorKind.protocol => AgentErrorKind.protocol,
    LlmErrorKind.provider ||
    LlmErrorKind.authentication ||
    LlmErrorKind.rateLimit ||
    LlmErrorKind.network ||
    LlmErrorKind.interrupted => AgentErrorKind.provider,
    LlmErrorKind.unknown => AgentErrorKind.unknown,
  };
  return AgentError(kind: kind, message: error.message);
}

import '../llm/errors.dart';
import '../llm/identifiers.dart';
import '../llm/messages.dart';
import '../llm/usage.dart';
import 'compaction.dart';
import 'errors.dart';
import 'ids.dart';
import 'policies.dart';
import 'token_accounting.dart';

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

enum AgentSessionLifecycle {
  idle,
  running,
  compacting,
  switchingModel,
  closing,
  closed,
}

sealed class AgentCompactionEvent {
  const AgentCompactionEvent({
    required this.operationId,
    required this.sessionId,
    this.runId,
    required this.reason,
    this.triggerId,
    this.triggerVersion,
    required this.strategyId,
    required this.strategyVersion,
    required this.estimatorId,
    required this.estimatorVersion,
    required this.beforeEstimate,
    this.targetEstimate,
  });

  final AgentCompactionOperationId operationId;
  final AgentSessionId sessionId;
  final RunId? runId;
  final AgentCompactionReason reason;
  final String? triggerId;
  final int? triggerVersion;
  final String strategyId;
  final int strategyVersion;
  final String estimatorId;
  final int estimatorVersion;
  final int beforeEstimate;
  final int? targetEstimate;

  bool get isTerminal =>
      this is AgentCompactionSucceeded ||
      this is AgentCompactionNoChangeEvent ||
      this is AgentCompactionFailed ||
      this is AgentCompactionCancelled;
}

final class AgentCompactionStarted extends AgentCompactionEvent {
  const AgentCompactionStarted({
    required super.operationId,
    required super.sessionId,
    super.runId,
    required super.reason,
    super.triggerId,
    super.triggerVersion,
    required super.strategyId,
    required super.strategyVersion,
    required super.estimatorId,
    required super.estimatorVersion,
    required super.beforeEstimate,
    super.targetEstimate,
  });
}

final class AgentCompactionSucceeded extends AgentCompactionEvent {
  AgentCompactionSucceeded({
    required super.operationId,
    required super.sessionId,
    super.runId,
    required super.reason,
    super.triggerId,
    super.triggerVersion,
    required super.strategyId,
    required super.strategyVersion,
    required super.estimatorId,
    required super.estimatorVersion,
    required super.beforeEstimate,
    super.targetEstimate,
    required this.afterEstimate,
    required this.generation,
    List<AgentCompactionInvocationReport> reports =
        const <AgentCompactionInvocationReport>[],
  }) : reports = List<AgentCompactionInvocationReport>.unmodifiable(reports);

  final int afterEstimate;
  final int generation;
  final List<AgentCompactionInvocationReport> reports;
  LlmUsage? get usage => aggregateAgentCompactionUsage(reports);
}

final class AgentCompactionNoChangeEvent extends AgentCompactionEvent {
  AgentCompactionNoChangeEvent({
    required super.operationId,
    required super.sessionId,
    super.runId,
    required super.reason,
    super.triggerId,
    super.triggerVersion,
    required super.strategyId,
    required super.strategyVersion,
    required super.estimatorId,
    required super.estimatorVersion,
    required super.beforeEstimate,
    super.targetEstimate,
    List<AgentCompactionInvocationReport> reports =
        const <AgentCompactionInvocationReport>[],
  }) : reports = List<AgentCompactionInvocationReport>.unmodifiable(reports);

  final List<AgentCompactionInvocationReport> reports;
  LlmUsage? get usage => aggregateAgentCompactionUsage(reports);
}

final class AgentCompactionFailed extends AgentCompactionEvent {
  AgentCompactionFailed({
    required super.operationId,
    required super.sessionId,
    super.runId,
    required super.reason,
    super.triggerId,
    super.triggerVersion,
    required super.strategyId,
    required super.strategyVersion,
    required super.estimatorId,
    required super.estimatorVersion,
    required super.beforeEstimate,
    super.targetEstimate,
    required this.error,
    List<AgentCompactionInvocationReport> reports =
        const <AgentCompactionInvocationReport>[],
  }) : reports = List<AgentCompactionInvocationReport>.unmodifiable(reports);

  final AgentError error;
  final List<AgentCompactionInvocationReport> reports;
  LlmUsage? get usage => aggregateAgentCompactionUsage(reports);
}

final class AgentCompactionCancelled extends AgentCompactionEvent {
  AgentCompactionCancelled({
    required super.operationId,
    required super.sessionId,
    super.runId,
    required super.reason,
    super.triggerId,
    super.triggerVersion,
    required super.strategyId,
    required super.strategyVersion,
    required super.estimatorId,
    required super.estimatorVersion,
    required super.beforeEstimate,
    super.targetEstimate,
    List<AgentCompactionInvocationReport> reports =
        const <AgentCompactionInvocationReport>[],
  }) : reports = List<AgentCompactionInvocationReport>.unmodifiable(reports);

  final List<AgentCompactionInvocationReport> reports;
  LlmUsage? get usage => aggregateAgentCompactionUsage(reports);
}

sealed class AgentRunEvent {
  const AgentRunEvent();

  bool get isTerminal =>
      this is AgentRunCompleted ||
      this is AgentRunStopped ||
      this is AgentRunFailed ||
      this is AgentRunCancelled;
}

final class AgentAutomaticCompactionEvent extends AgentRunEvent {
  const AgentAutomaticCompactionEvent(this.compaction);

  final AgentCompactionEvent compaction;
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
  const AgentUsageUpdated(this.usage, {this.tokenAccounting});

  final LlmUsage usage;
  final AgentTokenAccountingSnapshot? tokenAccounting;
}

final class AgentNoProgressWarning extends AgentRunEvent {
  const AgentNoProgressWarning(this.consecutiveCycles);

  final int consecutiveCycles;
}

final class AgentRunCompleted extends AgentRunEvent {
  const AgentRunCompleted({
    this.finishReason,
    this.usage,
    this.tokenAccounting,
  });

  final LlmFinishReason? finishReason;
  final LlmUsage? usage;
  final AgentTokenAccountingSnapshot? tokenAccounting;
}

final class AgentRunStopped extends AgentRunEvent {
  const AgentRunStopped(this.reason, {this.usage, this.tokenAccounting});

  final AgentStopReason reason;
  final LlmUsage? usage;
  final AgentTokenAccountingSnapshot? tokenAccounting;
}

final class AgentRunFailed extends AgentRunEvent {
  const AgentRunFailed(this.error, {this.tokenAccounting});

  final AgentError error;
  final AgentTokenAccountingSnapshot? tokenAccounting;
}

final class AgentRunCancelled extends AgentRunEvent {
  const AgentRunCancelled({this.tokenAccounting});

  final AgentTokenAccountingSnapshot? tokenAccounting;
}

AgentError agentErrorFromLlm(LlmError error) {
  final kind = switch (error.kind) {
    LlmErrorKind.configuration => AgentErrorKind.configuration,
    LlmErrorKind.protocol => AgentErrorKind.protocol,
    LlmErrorKind.provider ||
    LlmErrorKind.authentication ||
    LlmErrorKind.rateLimit ||
    LlmErrorKind.contextOverflow ||
    LlmErrorKind.network ||
    LlmErrorKind.interrupted => AgentErrorKind.provider,
    LlmErrorKind.unknown => AgentErrorKind.unknown,
  };
  return AgentError(kind: kind, message: error.message);
}

import '../llm/cancellation.dart';
import '../llm/usage.dart';
import '../llm/request.dart';

/// Optional host policy for a buffered final answer. Drafts are never emitted
/// or admitted to the transcript before this policy accepts their replacement.
/// Opaque provider continuation state is discarded: it describes the raw draft,
/// rather than the host-approved replacement. Gated final turns have no tools.
abstract interface class AgentFinalAnswerGate {
  Future<AgentFinalAnswerDecision> evaluate(
    AgentFinalAnswerDraft draft,
    CancellationToken cancellation,
  );
}

final class AgentFinalAnswerDraft {
  const AgentFinalAnswerDraft({
    required this.text,
    required this.request,
    required this.finishReason,
    required this.repairAttempt,
  });
  final String text;
  final LlmRequestSnapshot request;
  final LlmFinishReason? finishReason;
  final bool repairAttempt;
}

sealed class AgentFinalAnswerDecision {
  const AgentFinalAnswerDecision();
}

final class AgentFinalAnswerAccepted extends AgentFinalAnswerDecision {
  AgentFinalAnswerAccepted(String text) : text = text.trim() {
    if (this.text.isEmpty) throw ArgumentError('Accepted answer is empty');
  }
  final String text;
}

/// The runtime permits at most one isolated repair request. A second rejection
/// fails the run without appending either draft. Usage remains accounted for.
final class AgentFinalAnswerRejected extends AgentFinalAnswerDecision {
  const AgentFinalAnswerRejected({required this.reason, this.repairRequest});
  final String reason;
  final LlmRequest? repairRequest;
}

/// An app-authored response to an admitted user message. The runtime persists
/// both messages, emits the answer and completes without a provider invocation.
final class AgentRespondWithoutModel {
  AgentRespondWithoutModel(String text) : text = text.trim() {
    if (this.text.isEmpty) throw ArgumentError('Host response is empty');
  }
  final String text;
}

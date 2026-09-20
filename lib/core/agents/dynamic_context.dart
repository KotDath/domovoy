import '../projects/ids.dart';
import 'ids.dart';

/// Extra, non-transcript provider context resolved for one model turn.
///
/// [systemPromptText] is appended to the agent definition's dynamic system
/// prompt for provider requests only. It is never appended to the transcript,
/// continuation state, or compaction input. [audit] carries the exact
/// retrieval trace for inspection without entering the request.
final class AgentDynamicContext {
  AgentDynamicContext({required String systemPromptText, this.audit})
    : systemPromptText = systemPromptText.trim();

  final String systemPromptText;
  final Object? audit;

  bool get isEmpty => systemPromptText.isEmpty;
}

/// Deterministic input for resolving one turn's dynamic context.
final class AgentDynamicContextRequest {
  const AgentDynamicContextRequest({
    required this.sessionId,
    required this.projectId,
    required this.query,
  });

  final AgentSessionId sessionId;
  final ProjectId? projectId;
  final String query;
}

/// Resolves optional extra system-prompt context for a provider request.
abstract interface class AgentDynamicContextProvider {
  Future<AgentDynamicContext?> provide(AgentDynamicContextRequest request);
}

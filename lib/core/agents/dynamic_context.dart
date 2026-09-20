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

/// Audit wrapper for independently resolved dynamic-context contributions.
final class CompositeAgentDynamicContextAudit {
  CompositeAgentDynamicContextAudit(Iterable<Object> contributions)
    : contributions = List<Object>.unmodifiable(contributions);

  final List<Object> contributions;

  T? firstOfType<T>() {
    for (final contribution in contributions) {
      if (contribution is T) return contribution as T;
    }
    return null;
  }
}

/// Resolves multiple context sources in a stable order and joins their prompt
/// blocks without exposing one source to another.
final class CompositeAgentDynamicContextProvider
    implements AgentDynamicContextProvider {
  CompositeAgentDynamicContextProvider(
    Iterable<AgentDynamicContextProvider> providers,
  ) : providers = List<AgentDynamicContextProvider>.unmodifiable(providers);

  final List<AgentDynamicContextProvider> providers;

  @override
  Future<AgentDynamicContext?> provide(
    AgentDynamicContextRequest request,
  ) async {
    final promptParts = <String>[];
    final audits = <Object>[];
    for (final provider in providers) {
      final contribution = await provider.provide(request);
      if (contribution == null || contribution.isEmpty) continue;
      promptParts.add(contribution.systemPromptText);
      final audit = contribution.audit;
      if (audit != null) audits.add(audit);
    }
    if (promptParts.isEmpty) return null;
    return AgentDynamicContext(
      systemPromptText: promptParts.join('\n\n'),
      audit: audits.isEmpty ? null : CompositeAgentDynamicContextAudit(audits),
    );
  }
}

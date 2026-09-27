import '../llm/identifiers.dart';

/// Opaque, app-owned context attached to exactly one agent run.
///
/// The runtime copies this value into every [ToolInvocation] of the run; the
/// model never sees or authors it. The composition registers the pinned model
/// for [scopeKey] when the run starts and releases it when the run settles, so
/// a `tools/call` that carries the key can only resolve a model of a live run.
///
/// [scopeKey] is a capability: it must be unpredictable, must not be derived
/// from user or model input, and must not be shown in UI, logs or transcripts.
final class AgentRunToolContext {
  AgentRunToolContext({required String scopeKey, this.bindLibraryRunId = false})
    : scopeKey = _requireScopeKey(scopeKey);

  /// Capability key of the run; never sent as a tool argument.
  final String scopeKey;

  /// When true, this run is a Domovoy-owned scheduled run: the runtime run id
  /// is bound to local `library.save_digest` calls for idempotent retries.
  final bool bindLibraryRunId;

  @override
  String toString() =>
      'AgentRunToolContext(${scopeKey.hashCode.toRadixString(16)}, '
      'bindLibraryRunId: $bindLibraryRunId)';
}

/// Issuer of per-run tool contexts, owned by the production composition.
///
/// [begin] registers any run-scoped resource (for example a digest model pin)
/// and returns the context handed to the runtime through `AgentRunOptions`.
/// [end] releases it; it must be called for every issued context once the run
/// settles, including cancellation and failure paths.
abstract interface class AgentRunToolContextFactory {
  AgentRunToolContext begin({
    required ModelRef model,
    bool bindLibraryRunId = false,
  });

  void end(AgentRunToolContext context);
}

String _requireScopeKey(String value) {
  final candidate = value.trim();
  if (candidate.isEmpty || candidate.length > 256) {
    throw ArgumentError.value(value, 'scopeKey', 'must be 1-256 characters');
  }
  return candidate;
}

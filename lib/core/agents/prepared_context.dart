import '../llm/cancellation.dart';
import '../llm/request.dart';
import 'dynamic_context.dart';

/// App-owned immutable context prepared once before admitting a run. Never
/// enters the retained transcript or compaction input. The observer settles
/// before each physical provider attempt, including an overflow retry.
final class AgentPreparedContext {
  const AgentPreparedContext({
    this.contribution,
    this.systemPromptOverride,
    this.suppressDynamicContext = false,
    this.disableTools = false,
    this.maxRequestBytes,
    this.beforeRequest,
  });

  final AgentDynamicContext? contribution;
  final String? systemPromptOverride;
  final bool suppressDynamicContext;
  final bool disableTools;

  /// Conservative UTF-8 request envelope after reserving output and framing.
  /// This is a byte bound, not a claim to have the provider's exact tokenizer.
  final int? maxRequestBytes;
  final Future<void> Function(
    LlmRequestSnapshot request,
    CancellationToken cancellation,
  )?
  beforeRequest;
}

import '../llm/cancellation.dart';
import '../llm/generation.dart';
import '../llm/request.dart';
import 'dynamic_context.dart';
import 'final_answer_gate.dart';

/// App-owned immutable context prepared once before admitting a run. Never
/// enters the retained transcript or compaction input. The observer settles
/// before each physical provider attempt, including an overflow retry.
final class AgentPreparedContext {
  const AgentPreparedContext({
    this.contribution,
    this.systemPromptOverride,
    this.suppressDynamicContext = false,
    this.disableTools = false,
    this.allowedToolIds,
    this.isolateCurrentUser = false,
    this.isolateCurrentRun = false,
    this.responseFormat,
    this.maxRequestBytes,
    this.beforeRequest,
    this.beforeFinalAnswer,
  });

  final AgentDynamicContext? contribution;
  final String? systemPromptOverride;
  final bool suppressDynamicContext;
  final bool disableTools;

  /// Additional deny-by-default ceiling, checked by the runtime at execution.
  final Set<String>? allowedToolIds;

  /// Send only the latest real user message to the provider. Retained history
  /// and compaction input are unchanged. Requires tools disabled.
  final bool isolateCurrentUser;

  /// Offer only the current user turn and subsequent tool exchanges. Retained
  /// history, summaries and old provider continuations never cross this seam.
  /// Automatic compaction is disabled, including on pressure and overflow; an
  /// overflowing current turn fails without summarizing/mutating old history.
  final bool isolateCurrentRun;

  /// Ephemeral output syntax for this run, including isolated repair attempts.
  final LlmResponseFormat? responseFormat;

  /// Conservative UTF-8 request envelope after reserving output and framing.
  /// This is a byte bound, not a claim to have the provider's exact tokenizer.
  final int? maxRequestBytes;
  final Future<void> Function(
    LlmRequestSnapshot request,
    CancellationToken cancellation,
  )?
  beforeRequest;

  /// Optional non-rewriting precondition for a tool-free final candidate.
  /// Unlike [AgentFinalAnswerGate], this preserves the ordinary tool loop.
  /// Text/reasoning are buffered until this turn's protocol and precondition
  /// pass. Tool-turn prose is released at its commit boundary; this does not
  /// claim semantic validation of intermediate prose. A failure never admits
  /// the rejected final draft to the transcript, but usage/tools remain.
  /// The runtime races this await with run cancellation; no repair is issued.
  final Future<void> Function(
    AgentFinalAnswerDraft draft,
    CancellationToken cancellation,
  )?
  beforeFinalAnswer;
}

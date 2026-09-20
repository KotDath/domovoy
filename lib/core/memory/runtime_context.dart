import '../agents/dynamic_context.dart';
import 'context.dart';
import 'render.dart';
import 'service.dart';

/// Trusted host capability text supplied independently of stored memory.
///
/// Without this protocol the chat model can incorrectly claim that persistent
/// memory is unavailable even though the host records candidates after the
/// response completes.
const memoryHostProtocol =
    'Domovoy provides host-managed memory. When the user explicitly asks you '
    'to remember a fact, acknowledge the request and explain that Domovoy will '
    'place it in the Memory panel under Candidates for user confirmation after '
    'this response. Never claim that persistent memory or a memory tool is '
    'unavailable. An unqualified remember request targets project working '
    'memory; an explicitly global, cross-chat, permanent, or long-term request '
    'targets global long-term memory. Do not claim the fact is already saved '
    'until the user has confirmed its candidate. Domovoy deduplicates against '
    'active memory, so no new candidate appears when the same fact is already '
    'stored; in that case explain that it is already present.';

/// Live read toggles resolved for every retrieval plan.
abstract interface class MemoryReadToggles {
  bool get includeWorking;

  bool get includeLongTerm;
}

/// Adapts deterministic memory retrieval to the agent runtime's dynamic
/// system-prompt hook.
///
/// The rendered block is supplied to provider requests only; the exact
/// [MemoryContextTrace] travels back as the runtime audit record instead of
/// entering the transcript, continuations, or compaction input.
final class MemoryDynamicContextProvider
    implements AgentDynamicContextProvider {
  MemoryDynamicContextProvider({
    required this.retrieval,
    this.toggles,
    this.characterBudget = defaultMemoryCharacterBudget,
    this.maxLongTermRecords = defaultMaxLongTermRecords,
    this.includeWorking = true,
    this.includeLongTerm = true,
  });

  final MemoryRetrievalService retrieval;
  final MemoryReadToggles? toggles;
  final int characterBudget;
  final int maxLongTermRecords;
  final bool includeWorking;
  final bool includeLongTerm;

  @override
  Future<AgentDynamicContext?> provide(
    AgentDynamicContextRequest request,
  ) async {
    final projectId = request.projectId;
    if (projectId == null) {
      return AgentDynamicContext(systemPromptText: memoryHostProtocol);
    }
    final plan = await retrieval.planRead(
      MemoryReadRequest(
        projectId: projectId,
        query: request.query,
        characterBudget: characterBudget,
        maxLongTermRecords: maxLongTermRecords,
        includeWorking: toggles?.includeWorking ?? includeWorking,
        includeLongTerm: toggles?.includeLongTerm ?? includeLongTerm,
      ),
    );
    if (plan.items.isEmpty) {
      return AgentDynamicContext(systemPromptText: memoryHostProtocol);
    }
    final rendered = renderMemoryBlock(plan);
    final systemPrompt = '$memoryHostProtocol\n\n$rendered';
    return AgentDynamicContext(
      systemPromptText: systemPrompt,
      audit: MemoryContextTrace(
        records: plan.trace,
        renderedCharacters: rendered.runes.length,
        budgetCharacters: plan.budgetCharacters,
        truncated: plan.truncated,
      ),
    );
  }
}

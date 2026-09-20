import '../agents/dynamic_context.dart';
import 'context.dart';
import 'render.dart';
import 'service.dart';

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
    this.characterBudget = defaultMemoryCharacterBudget,
    this.maxLongTermRecords = defaultMaxLongTermRecords,
    this.includeWorking = true,
    this.includeLongTerm = true,
  });

  final MemoryRetrievalService retrieval;
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
      return null;
    }
    final plan = await retrieval.planRead(
      MemoryReadRequest(
        projectId: projectId,
        query: request.query,
        characterBudget: characterBudget,
        maxLongTermRecords: maxLongTermRecords,
        includeWorking: includeWorking,
        includeLongTerm: includeLongTerm,
      ),
    );
    if (plan.items.isEmpty) {
      return null;
    }
    final rendered = renderMemoryBlock(plan);
    return AgentDynamicContext(
      systemPromptText: rendered,
      audit: MemoryContextTrace(
        records: plan.trace,
        renderedCharacters: rendered.runes.length,
        budgetCharacters: plan.budgetCharacters,
        truncated: plan.truncated,
      ),
    );
  }
}

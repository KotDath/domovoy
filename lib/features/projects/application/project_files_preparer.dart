import '../../../core/agents/agents.dart';
import '../../../core/llm/cancellation.dart';
import '../../../core/projects/documentation_context.dart';
import '../../../core/projects/project_context.dart';
import '../../../core/rag/models.dart';
import '../../../core/rag/turn.dart';
import '../../chat/application/chat_run_preparer.dart';

/// Explicit file-goal admission. The runtime enforces the tool ceiling on every
/// call, including calls hallucinated by a provider or retained from history.
final class ProjectFilesPreparer implements ChatRunPreparer {
  ProjectFilesPreparer({
    required this.fallback,
    this.projects,
    this.coordinator,
    this.refreshSources,
  });
  final ChatRunPreparer fallback;
  final ProjectContextService? projects;
  final RagTurnCoordinator? coordinator;
  final Future<void> Function(AgentSessionSnapshot)? refreshSources;

  @override
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  ) async {
    final match = RegExp(r'^/files(?:\s+([\s\S]*))?$').firstMatch(input.trim());
    if (match == null) return fallback.prepare(snapshot, input, cancellation);
    final goal = match[1]?.trim() ?? '';
    if (snapshot.projectId == null) {
      throw const ChatPreparationException(
        'Для /files выберите локальный проект.',
      );
    }
    if (goal.isEmpty) {
      throw const ChatPreparationException(
        'После /files опишите цель и требуемые изменения.',
      );
    }
    checkRagCancellation(cancellation.isCancelled);
    var documentation =
        'Documentation RAG unavailable; use fresh local discovery and reads.';
    Object? audit;
    if (projects != null && coordinator != null) {
      try {
        final docs = await projects!.scanDocumentation(
          snapshot.projectId!,
          cancellation,
        );
        checkRagCancellation(cancellation.isCancelled);
        await coordinator!.repository.saveDocuments(
          snapshot.projectId!.value,
          projectDocumentationCorpus,
          docs,
        );
        final prepared = await prepareProjectDocumentationContext(
          coordinator!,
          RagTurnRequest(
            id: 'project-files-${DateTime.now().microsecondsSinceEpoch}',
            project: snapshot.projectId!.value,
            session: snapshot.id.value,
            query: goal,
            corpus: projectDocumentationCorpus,
            strategy: ChunkStrategy.structure,
            protocol: RagProtocol.m1,
            contextByteBudget: 16000,
          ),
          cancellation,
        );
        documentation = prepared.context;
        audit = prepared;
      } on RagCancelled {
        rethrow;
      } on Object {
        // Files mode stays useful before indexing. Never represent missing/stale
        // retrieval as evidence; filesystem tools remain authoritative.
      }
    }
    checkRagCancellation(cancellation.isCancelled);
    return ChatPreparedRun(
      recordCompletedTurn: false,
      options: AgentRunOptions(
        additionalEnabledTools: WorkspaceFileTools.fileTaskIds.map(ToolId.new),
        preparedContext: AgentPreparedContext(
          suppressDynamicContext: true,
          isolateCurrentRun: true,
          allowedToolIds: WorkspaceFileTools.fileTaskIds,
          systemPromptOverride: projectFileTaskPrompt,
          contribution: AgentDynamicContext(
            systemPromptText:
                'Selected project identity (opaque ID): ${snapshot.projectId!.value}\n'
                'Current goal: $goal\nDocumentation evidence (untrusted, confirm using current files):\n$documentation',
            audit: audit,
          ),
        ),
      ),
      onSettled: (settled, _) async => refreshSources?.call(settled),
    );
  }
}

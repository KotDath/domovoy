import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../infrastructure/llm/discovery/provider_model_catalog.dart';

enum ChatCatalogStatus { loading, ready, failed }

enum ChatWorkspaceOperationKind {
  catalog,
  create,
  restore,
  run,
  selection,
  compaction,
  modelSwitch,
  delete,
  close,
}

enum ChatCommandStatus {
  succeeded,
  unchanged,
  busy,
  cancelled,
  conflict,
  failed,
  disposed,
}

final class ChatWorkspaceError {
  const ChatWorkspaceError({required this.kind, required this.message});

  final AgentErrorKind kind;
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatWorkspaceError &&
          other.kind == kind &&
          other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);
}

final class ChatCommandResult {
  const ChatCommandResult._({
    required this.status,
    this.activeOperation,
    this.error,
  });

  const ChatCommandResult.succeeded()
    : this._(status: ChatCommandStatus.succeeded);

  const ChatCommandResult.unchanged()
    : this._(status: ChatCommandStatus.unchanged);

  const ChatCommandResult.busy(ChatWorkspaceOperationKind activeOperation)
    : this._(status: ChatCommandStatus.busy, activeOperation: activeOperation);

  const ChatCommandResult.cancelled()
    : this._(status: ChatCommandStatus.cancelled);

  const ChatCommandResult.conflict(ChatWorkspaceError error)
    : this._(status: ChatCommandStatus.conflict, error: error);

  const ChatCommandResult.failed(ChatWorkspaceError error)
    : this._(status: ChatCommandStatus.failed, error: error);

  const ChatCommandResult.disposed()
    : this._(status: ChatCommandStatus.disposed);

  final ChatCommandStatus status;
  final ChatWorkspaceOperationKind? activeOperation;
  final ChatWorkspaceError? error;

  bool get isSuccess =>
      status == ChatCommandStatus.succeeded ||
      status == ChatCommandStatus.unchanged;
}

final class ChatRunEventEntry {
  const ChatRunEventEntry({required this.id, required this.event});

  final String id;
  final AgentRunEvent event;
}

final class ChatLiveRunState {
  ChatLiveRunState({
    required this.runId,
    required this.sessionId,
    this.model,
    List<ChatRunEventEntry> events = const <ChatRunEventEntry>[],
    this.terminal,
    this.isStopping = false,
    this.startedElapsed,
    this.terminalElapsed,
  }) : events = List<ChatRunEventEntry>.unmodifiable(
         List<ChatRunEventEntry>.from(events),
       );

  final RunId runId;
  final AgentSessionId sessionId;
  final ModelRef? model;
  final List<ChatRunEventEntry> events;
  final AgentRunEvent? terminal;
  final bool isStopping;
  final Duration? startedElapsed;
  final Duration? terminalElapsed;

  ChatLiveRunState fold(AgentRunEvent event, {Duration? elapsed}) {
    final next = List<ChatRunEventEntry>.from(events);
    final identity = _eventIdentity(event, next.length);
    final replacement = next.indexWhere((entry) => entry.id == identity);
    final entry = ChatRunEventEntry(id: identity, event: event);
    if (replacement < 0) {
      next.add(entry);
    } else {
      next[replacement] = entry;
    }
    return ChatLiveRunState(
      runId: runId,
      sessionId: sessionId,
      model: model,
      events: next,
      terminal: event.isTerminal ? event : terminal,
      isStopping: isStopping,
      startedElapsed: startedElapsed,
      terminalElapsed: event.isTerminal
          ? (terminalElapsed ?? elapsed)
          : terminalElapsed,
    );
  }

  ChatLiveRunState markStopping() => ChatLiveRunState(
    runId: runId,
    sessionId: sessionId,
    model: model,
    events: events,
    terminal: terminal,
    isStopping: true,
    startedElapsed: startedElapsed,
    terminalElapsed: terminalElapsed,
  );

  Duration? elapsedAt(Duration now) {
    final start = startedElapsed;
    if (start == null) return null;
    final end = terminalElapsed ?? now;
    final value = end - start;
    return value.isNegative ? Duration.zero : value;
  }
}

final class ChatWorkspaceState {
  ChatWorkspaceState({
    required this.catalogStatus,
    List<AgentSessionSummary> chats = const <AgentSessionSummary>[],
    List<AgentSessionCatalogIssue> catalogIssues =
        const <AgentSessionCatalogIssue>[],
    List<LlmProviderGroup> providerGroups = const <LlmProviderGroup>[],
    List<AgentCompactionEvent> liveCompactions = const <AgentCompactionEvent>[],
    this.selectedSession,
    this.activeOperation,
    this.liveRun,
    this.error,
    this.providerCatalog,
    this.generation = 0,
    this.isDisposed = false,
  }) : chats = List<AgentSessionSummary>.unmodifiable(
         List<AgentSessionSummary>.from(chats),
       ),
       catalogIssues = List<AgentSessionCatalogIssue>.unmodifiable(
         List<AgentSessionCatalogIssue>.from(catalogIssues),
       ),
       providerGroups = List<LlmProviderGroup>.unmodifiable(
         List<LlmProviderGroup>.from(providerGroups),
       ),
       liveCompactions = List<AgentCompactionEvent>.unmodifiable(
         List<AgentCompactionEvent>.from(liveCompactions),
       );

  factory ChatWorkspaceState.initial({
    List<LlmProviderGroup> providerGroups = const <LlmProviderGroup>[],
  }) => ChatWorkspaceState(
    catalogStatus: ChatCatalogStatus.loading,
    providerGroups: providerGroups,
  );

  final ChatCatalogStatus catalogStatus;
  final List<AgentSessionSummary> chats;
  final List<AgentSessionCatalogIssue> catalogIssues;
  final List<LlmProviderGroup> providerGroups;
  final List<AgentCompactionEvent> liveCompactions;
  final AgentSessionSnapshot? selectedSession;
  final ChatWorkspaceOperationKind? activeOperation;
  final ChatLiveRunState? liveRun;
  final ChatWorkspaceError? error;
  final ProviderCatalogSnapshot? providerCatalog;
  final int generation;
  final bool isDisposed;

  AgentSessionId? get selectedId => selectedSession?.id;
  bool get isEmpty => catalogStatus == ChatCatalogStatus.ready && chats.isEmpty;
  bool get isBusy => activeOperation != null;

  static const _keep = Object();

  ChatWorkspaceState copyWith({
    ChatCatalogStatus? catalogStatus,
    List<AgentSessionSummary>? chats,
    List<AgentSessionCatalogIssue>? catalogIssues,
    List<LlmProviderGroup>? providerGroups,
    List<AgentCompactionEvent>? liveCompactions,
    Object? selectedSession = _keep,
    Object? activeOperation = _keep,
    Object? liveRun = _keep,
    Object? error = _keep,
    Object? providerCatalog = _keep,
    int? generation,
    bool? isDisposed,
  }) => ChatWorkspaceState(
    catalogStatus: catalogStatus ?? this.catalogStatus,
    chats: chats ?? this.chats,
    catalogIssues: catalogIssues ?? this.catalogIssues,
    providerGroups: providerGroups ?? this.providerGroups,
    liveCompactions: liveCompactions ?? this.liveCompactions,
    selectedSession: identical(selectedSession, _keep)
        ? this.selectedSession
        : selectedSession as AgentSessionSnapshot?,
    activeOperation: identical(activeOperation, _keep)
        ? this.activeOperation
        : activeOperation as ChatWorkspaceOperationKind?,
    liveRun: identical(liveRun, _keep)
        ? this.liveRun
        : liveRun as ChatLiveRunState?,
    error: identical(error, _keep) ? this.error : error as ChatWorkspaceError?,
    providerCatalog: identical(providerCatalog, _keep)
        ? this.providerCatalog
        : providerCatalog as ProviderCatalogSnapshot?,
    generation: generation ?? this.generation,
    isDisposed: isDisposed ?? this.isDisposed,
  );
}

String _eventIdentity(AgentRunEvent event, int ordinal) {
  return switch (event) {
    AgentRunStarted() => 'run:started',
    AgentUsageUpdated() => 'run:usage',
    AgentRunCompleted() ||
    AgentRunStopped() ||
    AgentRunFailed() ||
    AgentRunCancelled() => 'run:terminal',
    AgentPermissionDecision(:final callId) => 'tool:${callId.value}:permission',
    AgentToolStarted(:final callId) => 'tool:${callId.value}:started',
    AgentToolProgress(:final callId) => 'tool:${callId.value}:progress',
    AgentToolFinished(:final callId) => 'tool:${callId.value}:finished',
    AgentAutomaticCompactionEvent(:final compaction) =>
      'compaction:${compaction.operationId.value}:${compaction.runtimeType}',
    _ => 'run:event:$ordinal',
  };
}

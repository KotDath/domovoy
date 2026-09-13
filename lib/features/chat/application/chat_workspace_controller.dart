import 'dart:async';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../infrastructure/llm/discovery/provider_model_catalog.dart';
import '../domain/chat_deletion_intent.dart';
import 'chat_stream_pacing.dart';
import 'chat_workspace_state.dart';

abstract interface class ChatSettingsLauncher {
  Future<void> openSettings();
}

final class ChatWorkspaceController {
  ChatWorkspaceController({
    required this.runtime,
    required this.definition,
    required this.catalog,
    required this.repository,
    required this.registry,
    this.providerModelCatalog,
    AgentSessionTitlePolicy? titlePolicy,
    this.settingsLauncher,
    this.pacingPolicy = const ChatStreamPacingPolicy(),
    this.scheduler = const TimerChatStreamScheduler(),
  }) : titlePolicy = titlePolicy ?? DeterministicAgentSessionTitlePolicy(),
       _agent = runtime.agent(definition),
       _state = ChatWorkspaceState.initial(
         providerGroups: registry.providerGroups,
       );

  final AgentRuntime runtime;
  final AgentDefinition definition;
  final AgentSessionCatalog catalog;
  final AgentSessionRepository repository;
  final LlmProviderRegistry registry;
  final ProviderModelCatalog? providerModelCatalog;
  final AgentSessionTitlePolicy titlePolicy;
  final ChatSettingsLauncher? settingsLauncher;
  final ChatStreamPacingPolicy pacingPolicy;
  final ChatStreamScheduler scheduler;
  final Agent _agent;

  final StreamController<ChatWorkspaceState> _states =
      StreamController<ChatWorkspaceState>.broadcast(sync: true);
  ChatWorkspaceState _state;
  AgentSession? _session;
  AgentRun? _activeRun;
  Completer<void>? _activeRunDone;
  AgentSessionSelectionOperation? _activeSelection;
  Completer<void>? _activeSelectionDone;
  Future<ChatCommandResult>? _stopFuture;
  ChatWorkspaceOperationKind? _operation;
  var _generation = 0;
  var _disposed = false;
  Future<void>? _disposeFuture;
  StreamSubscription<ProviderCatalogSnapshot>? _providerCatalogSubscription;
  ChatScheduledNotification? _scheduledNotification;
  final Map<String, AgentSessionId> _issuedDeletionIntents =
      <String, AgentSessionId>{};
  var _deletionIntentSequence = 0;

  ChatWorkspaceState get state => _state;
  Stream<ChatWorkspaceState> get states => _states.stream;
  bool get isDisposed => _disposed;

  Future<ChatCommandResult> initialize() {
    if (_disposed) {
      return Future<ChatCommandResult>.value(
        const ChatCommandResult.disposed(),
      );
    }
    if (_operation != null) {
      return Future<ChatCommandResult>.value(
        ChatCommandResult.busy(_operation!),
      );
    }
    if (_state.catalogStatus == ChatCatalogStatus.ready) {
      return Future<ChatCommandResult>.value(
        const ChatCommandResult.unchanged(),
      );
    }
    final generation = _admit(ChatWorkspaceOperationKind.catalog);
    return _initialize(generation);
  }

  Future<ChatCommandResult> _initialize(int generation) async {
    _emit(
      _state.copyWith(catalogStatus: ChatCatalogStatus.loading, error: null),
    );
    try {
      if (providerModelCatalog != null) {
        _providerCatalogSubscription ??= providerModelCatalog!.updates.listen(
          (snapshot) => _emit(
            _state.copyWith(
              providerGroups: registry.providerGroups,
              providerCatalog: snapshot,
            ),
          ),
        );
        await providerModelCatalog!.initialize();
        unawaited(providerModelCatalog!.refresh());
      }
      final snapshot = await catalog.list();
      if (!_isCurrent(generation)) {
        return const ChatCommandResult.disposed();
      }
      _applyCatalog(snapshot);
      if (snapshot.available.isEmpty) {
        return const ChatCommandResult.succeeded();
      }
      _setOperation(ChatWorkspaceOperationKind.restore);
      return await _restoreSelected(
        snapshot.available.first.id,
        generation,
        closeCurrent: false,
      );
    } on Object catch (error) {
      if (!_isCurrent(generation)) {
        return const ChatCommandResult.disposed();
      }
      final exposed = _sanitizeWorkspaceError(error);
      _emit(
        _state.copyWith(
          catalogStatus: ChatCatalogStatus.failed,
          chats: const <AgentSessionSummary>[],
          catalogIssues: const <AgentSessionCatalogIssue>[],
          selectedSession: null,
          error: exposed,
        ),
      );
      return ChatCommandResult.failed(exposed);
    } finally {
      _finish(generation);
    }
  }

  Future<ChatCommandResult> createChat({AgentSessionId? id}) {
    final rejection = _rejectMutation();
    if (rejection != null) {
      return Future<ChatCommandResult>.value(rejection);
    }
    final generation = _admit(ChatWorkspaceOperationKind.create);
    return _createChat(generation, id);
  }

  Future<ChatCommandResult> _createChat(
    int generation,
    AgentSessionId? id,
  ) async {
    try {
      final closeResult = await _closeCurrent(generation);
      if (!closeResult.isSuccess) {
        return closeResult;
      }
      final created = await _agent.createSession(
        id: id,
        persistence: SessionPersistence.repository,
      );
      if (!_isCurrent(generation)) {
        await _safelyClose(created);
        return const ChatCommandResult.disposed();
      }
      _session = created;
      _emit(
        _state.copyWith(
          selectedSession: created.snapshot,
          liveRun: null,
          error: null,
        ),
      );
      await _refreshCatalog(generation);
      return const ChatCommandResult.succeeded();
    } on Object catch (error) {
      return _recordFailure(error, generation);
    } finally {
      _finish(generation);
    }
  }

  Future<ChatCommandResult> selectChat(AgentSessionId id) {
    final rejection = _rejectMutation();
    if (rejection != null) {
      return Future<ChatCommandResult>.value(rejection);
    }
    if (_state.selectedId == id) {
      return Future<ChatCommandResult>.value(
        const ChatCommandResult.unchanged(),
      );
    }
    if (!_state.chats.any((summary) => summary.id == id)) {
      final error = ChatWorkspaceError(
        kind: AgentErrorKind.configuration,
        message: 'Выбранный чат отсутствует в актуальном каталоге.',
      );
      return Future<ChatCommandResult>.value(ChatCommandResult.failed(error));
    }
    return restoreChat(id);
  }

  Future<ChatCommandResult> restoreChat(AgentSessionId id) {
    final rejection = _rejectMutation();
    if (rejection != null) {
      return Future<ChatCommandResult>.value(rejection);
    }
    final generation = _admit(ChatWorkspaceOperationKind.restore);
    return _restoreCommand(id, generation);
  }

  Future<ChatCommandResult> _restoreCommand(
    AgentSessionId id,
    int generation,
  ) async {
    try {
      return await _restoreSelected(id, generation, closeCurrent: true);
    } finally {
      _finish(generation);
    }
  }

  Future<ChatCommandResult> _restoreSelected(
    AgentSessionId id,
    int generation, {
    required bool closeCurrent,
  }) async {
    if (closeCurrent) {
      final closeResult = await _closeCurrent(generation);
      if (!closeResult.isSuccess) {
        return closeResult;
      }
    }
    try {
      final restored = await _agent.restoreSession(id);
      if (!_isCurrent(generation)) {
        await _safelyClose(restored);
        return const ChatCommandResult.disposed();
      }
      _session = restored;
      _emit(
        _state.copyWith(
          selectedSession: restored.snapshot,
          liveRun: null,
          error: null,
        ),
      );
      return const ChatCommandResult.succeeded();
    } on Object catch (error) {
      return _recordFailure(error, generation, clearSelection: true);
    }
  }

  Future<ChatCommandResult> closeSelected() {
    final rejection = _rejectMutation();
    if (rejection != null) {
      return Future<ChatCommandResult>.value(rejection);
    }
    if (_session == null) {
      return Future<ChatCommandResult>.value(
        const ChatCommandResult.unchanged(),
      );
    }
    final generation = _admit(ChatWorkspaceOperationKind.close);
    return _closeSelectedCommand(generation);
  }

  Future<ChatCommandResult> _closeSelectedCommand(int generation) async {
    try {
      return await _closeCurrent(generation);
    } finally {
      _finish(generation);
    }
  }

  Future<ChatCommandResult> _closeCurrent(int generation) async {
    final current = _session;
    if (current == null) {
      return const ChatCommandResult.succeeded();
    }
    try {
      await current.close();
      if (!_isCurrent(generation)) {
        return const ChatCommandResult.disposed();
      }
      if (identical(_session, current)) {
        _session = null;
        _emit(
          _state.copyWith(selectedSession: null, liveRun: null, error: null),
        );
      }
      return const ChatCommandResult.succeeded();
    } on Object catch (error) {
      return _recordFailure(error, generation);
    }
  }

  Future<ChatCommandResult> send(String input) {
    if (input.trim().isEmpty) {
      final error = ChatWorkspaceError(
        kind: AgentErrorKind.configuration,
        message: 'Введите сообщение перед отправкой.',
      );
      return Future<ChatCommandResult>.value(ChatCommandResult.failed(error));
    }
    final rejection = _rejectMutation();
    if (rejection != null) {
      return Future<ChatCommandResult>.value(rejection);
    }
    final session = _session;
    if (session == null) {
      final error = ChatWorkspaceError(
        kind: AgentErrorKind.configuration,
        message: 'Сначала создайте или выберите чат.',
      );
      return Future<ChatCommandResult>.value(ChatCommandResult.failed(error));
    }
    if (!registry.isModelAvailable(session.snapshot.selection.model)) {
      final error = ChatWorkspaceError(
        kind: AgentErrorKind.configuration,
        message: 'Модель больше недоступна у провайдера. Выберите замену.',
      );
      _emit(_state.copyWith(error: error));
      return Future<ChatCommandResult>.value(ChatCommandResult.failed(error));
    }
    final generation = _admit(ChatWorkspaceOperationKind.run);
    return _send(session, input, generation);
  }

  Future<ChatCommandResult> _send(
    AgentSession session,
    String input,
    int generation,
  ) async {
    AgentRunEvent? terminal;
    try {
      final run = session.run(input, titlePolicy: titlePolicy);
      _activeRun = run;
      final done = Completer<void>();
      _activeRunDone = done;
      _emit(
        _state.copyWith(
          selectedSession: session.snapshot,
          liveRun: ChatLiveRunState(
            runId: run.id,
            sessionId: session.id,
            model: session.snapshot.selection.model,
          ),
          error: null,
        ),
      );
      Object? streamError;
      late final StreamSubscription<AgentRunEvent> subscription;
      subscription = run.events.listen(
        (event) {
          if (!_isCurrent(generation) ||
              !identical(_activeRun, run) ||
              _state.selectedId != session.id) {
            return;
          }
          terminal = event.isTerminal ? event : terminal;
          final live = _state.liveRun;
          final next = _state.copyWith(
            selectedSession: session.snapshot,
            liveRun: live?.fold(event),
          );
          if (event is AgentReasoningDelta || event is AgentAnswerDelta) {
            _reducePaced(next, generation, run);
          } else {
            _emit(next);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          streamError = error;
        },
        onDone: () {
          if (!done.isCompleted) {
            done.complete();
          }
        },
      );
      await done.future;
      await subscription.cancel();
      if (!_isCurrent(generation)) {
        return const ChatCommandResult.disposed();
      }
      if (streamError != null) {
        return _recordFailure(streamError!, generation);
      }
      _emit(_state.copyWith(selectedSession: session.snapshot));
      final event = terminal;
      if (event is AgentRunFailed &&
          event.error.kind == AgentErrorKind.conflict) {
        await _recoverSelected(session.id, generation);
        final exposed = _sanitizeWorkspaceError(AgentException(event.error));
        _emit(_state.copyWith(error: exposed));
        return ChatCommandResult.conflict(exposed);
      }
      await _refreshCatalog(generation);
      if (event is AgentRunFailed) {
        final exposed = _sanitizeWorkspaceError(AgentException(event.error));
        _emit(_state.copyWith(error: exposed));
        return ChatCommandResult.failed(exposed);
      }
      if (event is AgentRunCancelled) {
        return const ChatCommandResult.cancelled();
      }
      return const ChatCommandResult.succeeded();
    } on Object catch (error) {
      return _recordFailure(error, generation);
    } finally {
      _activeRun = null;
      final done = _activeRunDone;
      if (done != null && !done.isCompleted) {
        done.complete();
      }
      _activeRunDone = null;
      _stopFuture = null;
      _finish(generation);
    }
  }

  Future<ChatCommandResult> stop() {
    if (_disposed) {
      return Future<ChatCommandResult>.value(
        const ChatCommandResult.disposed(),
      );
    }
    final run = _activeRun;
    final selection = _activeSelection;
    if (run == null && selection == null) {
      return Future<ChatCommandResult>.value(
        const ChatCommandResult.unchanged(),
      );
    }
    final existing = _stopFuture;
    if (existing != null) {
      return existing;
    }
    final live = _state.liveRun;
    if (live != null) {
      _emit(_state.copyWith(liveRun: live.markStopping()));
    }
    final stopping = _stopActive(run: run, selection: selection);
    _stopFuture = stopping;
    return stopping;
  }

  Future<ChatCommandResult> _stopActive({
    AgentRun? run,
    AgentSessionSelectionOperation? selection,
  }) async {
    try {
      if (run != null) await run.cancel();
      if (selection != null) await selection.cancel();
      return const ChatCommandResult.succeeded();
    } on Object catch (error) {
      final exposed = _sanitizeWorkspaceError(error);
      if (!_disposed) {
        _emit(_state.copyWith(error: exposed));
      }
      return ChatCommandResult.failed(exposed);
    }
  }

  Future<ChatCommandResult> stabilize() async {
    if (_disposed) {
      return const ChatCommandResult.disposed();
    }
    final done = _activeRunDone;
    final selectionDone = _activeSelectionDone;
    if (done == null && selectionDone == null) {
      return const ChatCommandResult.unchanged();
    }
    if (done != null) await done.future;
    if (selectionDone != null) await selectionDone.future;
    if (_disposed) {
      return const ChatCommandResult.disposed();
    }
    return const ChatCommandResult.succeeded();
  }

  Future<ChatCommandResult> changeReasoning(
    ReasoningMode mode,
    ReasoningEffort effort,
  ) {
    final session = _session;
    if (session == null) {
      final error = ChatWorkspaceError(
        kind: AgentErrorKind.configuration,
        message: 'Сначала создайте или выберите чат.',
      );
      return Future<ChatCommandResult>.value(ChatCommandResult.failed(error));
    }
    return changeSelection(
      AgentSessionSelection(
        model: session.snapshot.selection.model,
        reasoningMode: mode,
        reasoningEffort: effort,
      ),
    );
  }

  Future<ChatCommandResult> changeSelection(AgentSessionSelection selection) {
    final rejection = _rejectMutation();
    if (rejection != null) {
      return Future<ChatCommandResult>.value(rejection);
    }
    final session = _session;
    if (session == null) {
      final error = ChatWorkspaceError(
        kind: AgentErrorKind.configuration,
        message: 'Сначала создайте или выберите чат.',
      );
      return Future<ChatCommandResult>.value(ChatCommandResult.failed(error));
    }
    final generation = _admit(
      selection.model == session.snapshot.selection.model
          ? ChatWorkspaceOperationKind.selection
          : ChatWorkspaceOperationKind.modelSwitch,
    );
    return _changeSelection(session, selection, generation);
  }

  Future<ChatCommandResult> _changeSelection(
    AgentSession session,
    AgentSessionSelection selection,
    int generation,
  ) async {
    StreamSubscription<AgentSessionSelectionEvent>? subscription;
    final eventsDone = Completer<void>();
    try {
      final operation = session.changeSelectionOperation(selection);
      _activeSelection = operation;
      _activeSelectionDone = eventsDone;
      subscription = operation.events.listen(
        (event) {
          if (!_isCurrent(generation) ||
              !identical(_activeSelection, operation) ||
              _state.selectedId != session.id) {
            return;
          }
          if (event case AgentSessionSelectionCompaction(:final compaction)) {
            _recordLiveCompaction(compaction);
          }
          if (event.isTerminal) {
            _emit(_state.copyWith(selectedSession: session.snapshot));
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!eventsDone.isCompleted) eventsDone.complete();
        },
        onDone: () {
          if (!eventsDone.isCompleted) eventsDone.complete();
        },
      );
      final result = await operation.result;
      await eventsDone.future;
      if (!_isCurrent(generation)) {
        return const ChatCommandResult.disposed();
      }
      switch (result.status) {
        case AgentSessionSelectionStatus.changed:
          _emit(
            _state.copyWith(selectedSession: session.snapshot, error: null),
          );
          await _refreshCatalog(generation);
          return const ChatCommandResult.succeeded();
        case AgentSessionSelectionStatus.unchanged:
          return const ChatCommandResult.unchanged();
        case AgentSessionSelectionStatus.busy:
          return ChatCommandResult.busy(
            _chatOperationFor(result.activeOperation),
          );
        case AgentSessionSelectionStatus.error:
          final error = _sanitizeWorkspaceError(AgentException(result.error!));
          if (result.error!.kind == AgentErrorKind.cancelled) {
            _emit(
              _state.copyWith(selectedSession: session.snapshot, error: null),
            );
            return const ChatCommandResult.cancelled();
          }
          if (result.error!.kind == AgentErrorKind.conflict) {
            await _recoverSelected(session.id, generation);
            return ChatCommandResult.conflict(error);
          }
          _emit(_state.copyWith(error: error));
          return ChatCommandResult.failed(error);
      }
    } finally {
      await subscription?.cancel();
      _activeSelection = null;
      if (!eventsDone.isCompleted) eventsDone.complete();
      _activeSelectionDone = null;
      _stopFuture = null;
      _finish(generation);
    }
  }

  void _recordLiveCompaction(AgentCompactionEvent event) {
    final next = <AgentCompactionEvent>[..._state.liveCompactions];
    final index = next.indexWhere(
      (candidate) => candidate.operationId == event.operationId,
    );
    if (index < 0) {
      next.add(event);
    } else {
      next[index] = event;
    }
    _emit(
      _state.copyWith(
        liveCompactions: next,
        selectedSession: _session?.snapshot,
      ),
    );
  }

  ChatDeletionIntent? deletionIntentFor(AgentSessionId id) {
    if (_disposed) return null;
    final summary = _state.chats.where((chat) => chat.id == id).firstOrNull;
    if (summary == null) return null;
    final token = '${id.value}:${++_deletionIntentSequence}';
    _issuedDeletionIntents[token] = id;
    return ChatDeletionIntent(
      chatId: id,
      displayTitle: summary.title ?? 'Новый чат',
      token: token,
    );
  }

  void discardDeletionIntent(ChatDeletionIntent intent) {
    if (_issuedDeletionIntents[intent.token] == intent.chatId) {
      _issuedDeletionIntents.remove(intent.token);
    }
  }

  Future<ChatCommandResult> deleteChat(ChatDeletionIntent intent) {
    if (_disposed) {
      return Future<ChatCommandResult>.value(
        const ChatCommandResult.disposed(),
      );
    }
    final issuedFor = _issuedDeletionIntents.remove(intent.token);
    if (issuedFor != intent.chatId) {
      return Future<ChatCommandResult>.value(
        ChatCommandResult.failed(
          ChatWorkspaceError(
            kind: AgentErrorKind.configuration,
            message: 'Подтверждение удаления устарело.',
          ),
        ),
      );
    }
    final exists = _state.chats.any((chat) => chat.id == intent.chatId);
    if (!exists) {
      return Future<ChatCommandResult>.value(
        const ChatCommandResult.unchanged(),
      );
    }
    final active = _operation;
    final deletingSelected = _state.selectedId == intent.chatId;
    final mayStopSelected =
        deletingSelected &&
        (active == ChatWorkspaceOperationKind.run ||
            active == ChatWorkspaceOperationKind.selection ||
            active == ChatWorkspaceOperationKind.modelSwitch ||
            active == ChatWorkspaceOperationKind.compaction);
    if (active != null && !mayStopSelected) {
      return Future<ChatCommandResult>.value(ChatCommandResult.busy(active));
    }
    final orderedIds = _state.chats.map((chat) => chat.id).toList();
    final generation = ++_generation;
    _cancelScheduledNotification();
    _operation = ChatWorkspaceOperationKind.delete;
    _emit(
      _state.copyWith(
        activeOperation: ChatWorkspaceOperationKind.delete,
        generation: generation,
        error: null,
      ),
    );
    return _deleteChat(
      intent,
      generation,
      orderedIds,
      deletingSelected: deletingSelected,
    );
  }

  Future<ChatCommandResult> _deleteChat(
    ChatDeletionIntent intent,
    int generation,
    List<AgentSessionId> orderedIds, {
    required bool deletingSelected,
  }) async {
    final run = _activeRun;
    final runDone = _activeRunDone;
    final selection = _activeSelection;
    final selectionDone = _activeSelectionDone;
    var selectedWasClosed = false;
    try {
      if (run != null || selection != null) {
        final stopped = await _stopActive(run: run, selection: selection);
        if (!stopped.isSuccess) return stopped;
      }
      if (runDone != null) await runDone.future;
      if (selectionDone != null) await selectionDone.future;
      if (!_isCurrent(generation)) {
        return const ChatCommandResult.disposed();
      }

      late final int expectedRevision;
      if (deletingSelected) {
        final current = _session;
        if (current == null || current.id != intent.chatId) {
          throwAgent(
            AgentErrorKind.conflict,
            'Selected chat identity changed before deletion.',
          );
        }
        // close() is terminal even when its durable flush reports failure.
        // Mark ownership before awaiting so the recovery path never leaves a
        // closed selected session bound to the controller.
        selectedWasClosed = true;
        await current.close();
        expectedRevision = current.snapshot.revision;
        if (identical(_session, current)) _session = null;
      } else {
        final record = await repository.load(intent.chatId);
        if (record == null) {
          throwAgent(AgentErrorKind.conflict, 'The chat no longer exists.');
        }
        expectedRevision = record.revision;
      }
      await repository.delete(
        intent.chatId,
        expectedRevision: expectedRevision,
        cancellation: CancellationSource().token,
      );
      if (!_isCurrent(generation)) {
        return const ChatCommandResult.disposed();
      }
      final catalogSnapshot = await catalog.list();
      if (!_isCurrent(generation)) {
        return const ChatCommandResult.disposed();
      }
      _applyCatalog(catalogSnapshot);
      if (deletingSelected) {
        final neighbor = _deletionNeighbor(
          deleted: intent.chatId,
          before: orderedIds,
          after: catalogSnapshot.available.map((chat) => chat.id).toList(),
        );
        if (neighbor == null) {
          _emit(
            _state.copyWith(
              selectedSession: null,
              liveRun: null,
              liveCompactions: const <AgentCompactionEvent>[],
              error: null,
            ),
          );
        } else {
          final restored = await _agent.restoreSession(neighbor);
          if (!_isCurrent(generation)) {
            await _safelyClose(restored);
            return const ChatCommandResult.disposed();
          }
          _session = restored;
          _emit(
            _state.copyWith(
              selectedSession: restored.snapshot,
              liveRun: null,
              liveCompactions: const <AgentCompactionEvent>[],
              error: null,
            ),
          );
        }
      }
      return const ChatCommandResult.succeeded();
    } on Object catch (error) {
      final result = _recordFailure(error, generation);
      if (deletingSelected && selectedWasClosed && _isCurrent(generation)) {
        await _recoverSelected(intent.chatId, generation);
      } else if (_isCurrent(generation)) {
        await _refreshCatalog(generation);
      }
      return result;
    } finally {
      _stopFuture = null;
      _finish(generation);
    }
  }

  Future<ChatCommandResult> openSettings() async {
    if (_disposed) {
      return const ChatCommandResult.disposed();
    }
    final launcher = settingsLauncher;
    if (launcher == null) {
      final error = ChatWorkspaceError(
        kind: AgentErrorKind.configuration,
        message: 'Настройки сейчас недоступны.',
      );
      return ChatCommandResult.failed(error);
    }
    try {
      await launcher.openSettings();
      return const ChatCommandResult.succeeded();
    } on Object {
      return ChatCommandResult.failed(
        ChatWorkspaceError(
          kind: AgentErrorKind.runtime,
          message: 'Не удалось открыть настройки.',
        ),
      );
    }
  }

  Future<void> dispose() => _disposeFuture ??= _performDispose();

  Future<void> _performDispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    _cancelScheduledNotification();
    await _providerCatalogSubscription?.cancel();
    _emit(
      _state.copyWith(
        activeOperation: ChatWorkspaceOperationKind.close,
        generation: _generation,
        isDisposed: true,
      ),
      allowDisposed: true,
    );
    final run = _activeRun;
    if (run != null) {
      try {
        await run.cancel();
      } on Object {
        // Session close below remains the authoritative cleanup boundary.
      }
    }
    final selection = _activeSelection;
    if (selection != null) {
      try {
        await selection.cancel();
      } on Object {
        // Session close below remains the authoritative cleanup boundary.
      }
    }
    final session = _session;
    _session = null;
    if (session != null) {
      await _safelyClose(session);
    }
    await _states.close();
  }

  Future<ProviderCatalogSnapshot?> refreshProviderModels() async {
    if (_disposed || providerModelCatalog == null) return null;
    return providerModelCatalog!.refresh();
  }

  Future<void> _recoverSelected(AgentSessionId id, int generation) async {
    final prior = _session;
    _session = null;
    if (prior != null) {
      await _safelyClose(prior);
    }
    if (!_isCurrent(generation)) {
      return;
    }
    try {
      final restored = await _agent.restoreSession(id);
      if (!_isCurrent(generation)) {
        await _safelyClose(restored);
        return;
      }
      _session = restored;
      _emit(_state.copyWith(selectedSession: restored.snapshot));
    } on Object catch (error) {
      _recordFailure(error, generation, clearSelection: true);
    }
    await _refreshCatalog(generation);
  }

  Future<void> _refreshCatalog(int generation) async {
    try {
      final snapshot = await catalog.list();
      if (_isCurrent(generation)) {
        _applyCatalog(snapshot);
      }
    } on Object catch (error) {
      if (_isCurrent(generation)) {
        _emit(
          _state.copyWith(
            catalogStatus: ChatCatalogStatus.failed,
            error: _sanitizeWorkspaceError(error),
          ),
        );
      }
    }
  }

  void _applyCatalog(AgentSessionCatalogSnapshot snapshot) {
    _emit(
      _state.copyWith(
        catalogStatus: ChatCatalogStatus.ready,
        chats: snapshot.available,
        catalogIssues: snapshot.issues,
        error: null,
      ),
    );
  }

  ChatCommandResult? _rejectMutation() {
    if (_disposed) {
      return const ChatCommandResult.disposed();
    }
    final operation = _operation;
    if (operation != null) {
      return ChatCommandResult.busy(operation);
    }
    return null;
  }

  int _admit(ChatWorkspaceOperationKind operation) {
    _cancelScheduledNotification();
    _operation = operation;
    final generation = ++_generation;
    _emit(
      _state.copyWith(
        activeOperation: operation,
        generation: generation,
        error: null,
        liveCompactions: const <AgentCompactionEvent>[],
      ),
    );
    return generation;
  }

  void _setOperation(ChatWorkspaceOperationKind operation) {
    _operation = operation;
    _emit(_state.copyWith(activeOperation: operation));
  }

  void _finish(int generation) {
    if (!_isCurrent(generation)) {
      return;
    }
    _operation = null;
    _emit(_state.copyWith(activeOperation: null));
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  ChatCommandResult _recordFailure(
    Object error,
    int generation, {
    bool clearSelection = false,
  }) {
    final exposed = _sanitizeWorkspaceError(error);
    if (_isCurrent(generation)) {
      if (clearSelection) {
        _session = null;
      }
      _emit(
        _state.copyWith(
          selectedSession: clearSelection ? null : _state.selectedSession,
          error: exposed,
        ),
      );
    }
    return exposed.kind == AgentErrorKind.conflict
        ? ChatCommandResult.conflict(exposed)
        : ChatCommandResult.failed(exposed);
  }

  void _emit(ChatWorkspaceState next, {bool allowDisposed = false}) {
    if (_disposed && !allowDisposed) {
      return;
    }
    _cancelScheduledNotification();
    _state = next;
    _publishState();
  }

  void _reducePaced(ChatWorkspaceState next, int generation, AgentRun run) {
    if (_disposed) return;
    _state = next;
    if (_scheduledNotification != null) return;
    _scheduledNotification = scheduler.schedule(
      pacingPolicy.notificationInterval,
      () {
        _scheduledNotification = null;
        if (_isCurrent(generation) && identical(_activeRun, run)) {
          _publishState();
        }
      },
    );
  }

  void _publishState() {
    if (!_states.isClosed) {
      _states.add(_state);
    }
  }

  void _cancelScheduledNotification() {
    _scheduledNotification?.cancel();
    _scheduledNotification = null;
  }

  Future<void> _safelyClose(AgentSession session) async {
    try {
      await session.close();
    } on Object {
      // Cleanup cannot expose infrastructure details or replace the command result.
    }
  }
}

ChatWorkspaceError _sanitizeWorkspaceError(Object error) {
  final kind = error is AgentException
      ? error.error.kind
      : AgentErrorKind.runtime;
  final message = switch (kind) {
    AgentErrorKind.configuration =>
      'Конфигурация чата недоступна. Проверьте модель и настройки.',
    AgentErrorKind.persistence =>
      'Не удалось прочитать или сохранить состояние чата.',
    AgentErrorKind.conflict =>
      'Чат был изменён в другом процессе. Показано актуальное состояние.',
    AgentErrorKind.busy => 'Чат занят другой операцией.',
    AgentErrorKind.compaction => 'Не удалось безопасно подготовить контекст.',
    AgentErrorKind.protocol => 'Провайдер не смог завершить запрос.',
    AgentErrorKind.provider =>
      error is AgentException && error.error.safeProviderMessage
          ? error.error.message
          : 'Провайдер не смог завершить запрос.',
    AgentErrorKind.budgetUnverifiable =>
      'Не удалось подтвердить лимит токенов для запроса.',
    AgentErrorKind.cancelled => 'Операция остановлена.',
    AgentErrorKind.runtime ||
    AgentErrorKind.unknown => 'Операция чата завершилась внутренней ошибкой.',
  };
  return ChatWorkspaceError(kind: kind, message: message);
}

ChatWorkspaceOperationKind _chatOperationFor(
  AgentSessionOperationKind? operation,
) => switch (operation) {
  AgentSessionOperationKind.run => ChatWorkspaceOperationKind.run,
  AgentSessionOperationKind.compaction => ChatWorkspaceOperationKind.compaction,
  AgentSessionOperationKind.selection => ChatWorkspaceOperationKind.modelSwitch,
  AgentSessionOperationKind.close || null => ChatWorkspaceOperationKind.close,
};

AgentSessionId? _deletionNeighbor({
  required AgentSessionId deleted,
  required List<AgentSessionId> before,
  required List<AgentSessionId> after,
}) {
  final deletedIndex = before.indexOf(deleted);
  if (deletedIndex < 0 || after.isEmpty) return null;
  if (deletedIndex < after.length) return after[deletedIndex];
  return after[deletedIndex - 1];
}

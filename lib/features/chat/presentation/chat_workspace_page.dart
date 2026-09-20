import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../design_system/design_system.dart';
import '../../projects/application/project_workspace_controller.dart';
import '../../projects/application/project_workspace_state.dart';
import '../../projects/presentation/project_sidebar_section.dart';
import '../../memory/application/memory_inspector_controller.dart';
import '../../memory/presentation/memory_inspector_panel.dart';
import '../../memory/presentation/memory_inspector_sheet.dart';
import '../application/chat_workspace_controller.dart';
import '../application/chat_workspace_state.dart';
import '../application/chat_timeline_projector.dart';
import '../application/chat_token_presenter.dart';
import 'chat_composer.dart';
import 'chat_timeline.dart';
import 'model_selector.dart';
import 'delete_chat_dialog.dart';
import 'token_details.dart';
import 'usage_view.dart';
import 'workspace_shell.dart';

enum WorkspacePane { chat, providers, usage }

class ChatWorkspacePage extends StatefulWidget {
  const ChatWorkspacePage({
    required this.controller,
    this.projects,
    this.memory,
    this.themeMode,
    this.onThemeModeChanged,
    this.providersView,
    super.key,
  });

  final ChatWorkspaceController controller;
  final ProjectWorkspaceController? projects;
  final MemoryInspectorController? memory;
  final ThemeMode? themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final Widget? providersView;

  @override
  State<ChatWorkspacePage> createState() => _ChatWorkspacePageState();
}

class _ChatWorkspacePageState extends State<ChatWorkspacePage> {
  static const _timelineProjector = ChatTimelineProjector();
  static const _tokenPresenter = ChatTokenPresenter();
  late ChatWorkspaceState _state;
  StreamSubscription<ChatWorkspaceState>? _subscription;
  StreamSubscription<ProjectWorkspaceState>? _projectSubscription;
  ProjectWorkspaceState? _projects;
  final _deleteFocusNode = FocusNode(debugLabel: 'chat-delete');
  final _newChatFocusNode = FocusNode(debugLabel: 'chat-new');
  var _pane = WorkspacePane.chat;
  Timer? _durationTimer;

  @override
  void initState() {
    super.initState();
    _bind(widget.controller, widget.projects);
    _syncMemory();
    if (widget.projects == null) {
      unawaited(widget.controller.initialize());
    } else {
      unawaited(widget.projects!.initialize());
    }
  }

  @override
  void didUpdateWidget(covariant ChatWorkspacePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.projects, widget.projects)) {
      unawaited(_subscription?.cancel());
      unawaited(_projectSubscription?.cancel());
      _bind(widget.controller, widget.projects);
      if (widget.projects == null) {
        unawaited(widget.controller.initialize());
      }
    }
  }

  void _bind(
    ChatWorkspaceController controller,
    ProjectWorkspaceController? projects,
  ) {
    _state = controller.state;
    _subscription = controller.states.listen((state) {
      if (mounted) {
        setState(() => _state = state);
        _syncDurationTimer();
        _syncMemory();
      }
    });
    _projects = projects?.state;
    _projectSubscription = projects?.states.listen((state) {
      if (mounted) {
        setState(() => _projects = state);
        _syncMemory();
      }
    });
  }

  void _syncMemory() {
    final memory = widget.memory;
    if (memory == null) {
      return;
    }
    final session = _visibleSelectedSession;
    final group = _projects?.selectedGroup;
    final projectId =
        session?.projectId ??
        (group?.kind == ProjectSelectionKind.project ? group?.projectId : null);
    unawaited(memory.attachSession(session: session, projectId: projectId));
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_projectSubscription?.cancel());
    _durationTimer?.cancel();
    _deleteFocusNode.dispose();
    _newChatFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _visibleSelectedSession;
    final enabled = !_state.isBusy && !_state.isDisposed;
    final projects = widget.projects;
    final projectState = _projects;
    final visibleChats = projectState?.selectedGroup?.chats ?? _state.chats;
    final group = projectState?.selectedGroup;
    return WorkspaceShell(
      key: const ValueKey('chat-workspace-destination'),
      chats: visibleChats,
      selectedId: _state.selectedId,
      title: switch (_pane) {
        WorkspacePane.providers => 'Провайдеры',
        WorkspacePane.usage => 'Использование',
        WorkspacePane.chat => selected?.title ?? 'Новый чат',
      },
      modelLabel: selected == null
          ? 'Модель не выбрана'
          : _modelLabel(selected.selection.model),
      modelLabelFor: (summary) => _modelLabel(summary.selection.model),
      body: switch (_pane) {
        WorkspacePane.providers => widget.providersView ?? _body(context),
        WorkspacePane.usage => UsageView(projection: _tokenProjection()),
        WorkspacePane.chat => _body(context),
      },
      composer: _composer(),
      showComposer: _pane == WorkspacePane.chat,
      onNewChat: enabled ? _createChat : null,
      onSelectChat: enabled
          ? (id) {
              setState(() => _pane = WorkspacePane.chat);
              _selectChat(id);
            }
          : null,
      onOpenSettings: _openSettings,
      onOpenUsage: () => setState(() => _pane = WorkspacePane.usage),
      enabled: enabled,
      issueCount: _state.catalogIssues.length,
      tokenProjection: _tokenProjection(),
      onOpenTokens: selected == null ? null : _openTokens,
      onDeleteChat:
          _pane != WorkspacePane.chat || selected == null || _state.isDisposed
          ? null
          : _deleteChat,
      deleteFocusNode: _deleteFocusNode,
      newChatFocusNode: _newChatFocusNode,
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
      usageSelected: _pane == WorkspacePane.usage,
      providersSelected: _pane == WorkspacePane.providers,
      projectName: group?.kind == ProjectSelectionKind.unassigned
          ? unassignedProjectLabel
          : group?.title,
      projectRoot: '—',
      aboveChats: projects == null || projectState == null
          ? null
          : ProjectSidebarSection(
              controller: projects,
              state: projectState,
              selectedChatId: _state.selectedId,
              onSelectChat: enabled
                  ? (id) {
                      setState(() => _pane = WorkspacePane.chat);
                      _selectChat(id);
                    }
                  : null,
              onNewChat: enabled ? _createChat : null,
            ),
      memoryPanel: widget.memory == null
          ? null
          : MemoryInspectorPanel(controller: widget.memory!),
      onOpenMemory: widget.memory == null
          ? null
          : () => unawaited(showMemoryInspectorSheet(context, widget.memory!)),
    );
  }

  Widget _body(BuildContext context) {
    if (_state.catalogStatus == ChatCatalogStatus.loading) {
      return Center(
        key: const ValueKey('workspace-loading'),
        child: Text('Загрузка…', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    if (_state.catalogStatus == ChatCatalogStatus.failed) {
      return _WorkspaceNotice(
        key: const ValueKey('workspace-error'),
        icon: Icons.cloud_off_outlined,
        title: 'Не удалось загрузить чаты',
        message: _state.error?.message ?? 'Хранилище временно недоступно.',
        actionLabel: 'Открыть настройки',
        onAction: _openSettings,
      );
    }
    if (_visibleSelectedSession == null) {
      return _WorkspaceNotice(
        key: const ValueKey('workspace-empty'),
        icon: Icons.chat_bubble_outline_rounded,
        title: 'Начните новый чат',
        message: 'История будет сохраняться после подтверждённых операций.',
        actionLabel: 'Новый чат',
        onAction: _state.isBusy ? null : _createChat,
      );
    }
    final snapshot = _visibleSelectedSession!;
    final projection = _timelineProjector.project(
      snapshot: snapshot,
      liveRun: _state.liveRun,
      operationCompactions: _state.liveCompactions,
      workspaceError: _state.error,
    );
    if (projection.items.isEmpty) {
      return const _WorkspaceNotice(
        key: ValueKey('workspace-selected'),
        icon: Icons.forum_outlined,
        title: 'Чат готов',
        message: 'Напишите сообщение — подтверждённая история появится здесь.',
      );
    }
    return ChatTimeline(
      projection: projection,
      announcement: _announcement(),
      onOpenSettings: _openSettings,
      durationLabel: _durationLabel(),
    );
  }

  Widget _composer() {
    final snapshot = _visibleSelectedSession;
    if (snapshot == null) return const ChatUnavailableComposer();
    return ChatComposer(
      providerGroups: _state.providerGroups,
      selection: snapshot.selection,
      onSend: widget.controller.send,
      onStop: widget.controller.stop,
      onSelectionChanged: widget.controller.changeSelection,
      running:
          _state.activeOperation == ChatWorkspaceOperationKind.run ||
          _state.activeOperation == ChatWorkspaceOperationKind.modelSwitch ||
          _state.activeOperation == ChatWorkspaceOperationKind.compaction,
      enabled: !_state.isDisposed,
      providerCatalog: _state.providerCatalog,
      onRefreshModels: widget.controller.refreshProviderModels,
      tokenProjection: _tokenProjection(),
      onOpenTokens: _openTokens,
      onOpenProviders: _openSettings,
      selectedModel: _selectedModel(snapshot),
    );
  }

  String? _announcement() {
    final live = _state.liveRun;
    if (live == null) return null;
    final terminal = live.terminal;
    if (terminal is AgentRunCompleted) return 'Ответ готов';
    if (terminal is AgentRunCancelled) return 'Ответ остановлен';
    if (terminal is AgentRunStopped) return 'Ответ прерван';
    if (terminal is AgentRunFailed) return 'Не удалось завершить ответ';
    for (final entry in live.events.reversed) {
      final event = entry.event;
      if (event is AgentToolFinished) {
        return event.success
            ? 'Инструмент завершён успешно'
            : 'Инструмент завершился ошибкой';
      }
      if (event is AgentAutomaticCompactionEvent &&
          event.compaction.isTerminal) {
        return 'Подготовка контекста завершена';
      }
    }
    return 'Ответ формируется';
  }

  String _modelLabel(ModelRef model) {
    for (final group in _state.providerGroups) {
      for (final entry in group.models) {
        if (entry.ref == model) return entry.name;
      }
    }
    return 'Недоступная модель';
  }

  void _createChat() {
    final projects = widget.projects;
    if (projects != null) {
      unawaited(projects.createChat());
      return;
    }
    unawaited(widget.controller.createChat());
  }

  void _selectChat(AgentSessionId id) {
    final projects = widget.projects;
    unawaited(
      projects == null
          ? widget.controller.selectChat(id)
          : projects.selectChat(id),
    );
  }

  void _openSettings() {
    if (widget.providersView != null) {
      setState(() => _pane = WorkspacePane.providers);
      return;
    }
    unawaited(widget.controller.openSettings());
  }

  void _syncDurationTimer() {
    final live = _state.liveRun;
    final running = live != null && live.terminal == null;
    if (running) {
      _durationTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _durationTimer?.cancel();
      _durationTimer = null;
    }
  }

  String? _durationLabel() {
    final live = _state.liveRun;
    if (live == null) return null;
    final elapsed = live.elapsedAt(widget.controller.clock.elapsed);
    if (elapsed == null) return null;
    final seconds = elapsed.inSeconds;
    return live.terminal == null ? 'Работает $seconds с' : 'Работал $seconds с';
  }

  LlmModel? _selectedModel(AgentSessionSnapshot snapshot) {
    try {
      return widget.controller.registry.requireModel(snapshot.selection.model);
    } on Object {
      return modelForSelection(_state.providerGroups, snapshot.selection);
    }
  }

  ChatTokenProjection? _tokenProjection() {
    final snapshot = _visibleSelectedSession;
    if (snapshot == null) return null;
    return _tokenPresenter.present(
      accounting: snapshot.tokenAccounting,
      selectedModel: widget.controller.registry.requireModel(
        snapshot.selection.model,
      ),
    );
  }

  void _openTokens() {
    final projection = _tokenProjection();
    if (projection == null) return;
    unawaited(
      showChatTokenDetails(
        context: context,
        projection: projection,
        model: _visibleSelectedSession == null
            ? null
            : _selectedModel(_visibleSelectedSession!),
      ),
    );
  }

  void _deleteChat() => unawaited(_confirmDelete());

  Future<void> _confirmDelete() async {
    final id = _visibleSelectedSession?.id;
    if (id == null) return;
    final projects = widget.projects;
    final intent = projects == null
        ? widget.controller.deletionIntentFor(id)
        : projects.deletionIntentFor(id);
    if (intent == null) return;
    final confirmed = await showDeleteChatConfirmation(
      context: context,
      intent: intent,
    );
    if (!mounted) return;
    if (!confirmed) {
      if (projects == null) {
        widget.controller.discardDeletionIntent(intent);
      } else {
        projects.discardDeletionIntent(intent);
      }
      _deleteFocusNode.requestFocus();
      return;
    }
    if (projects == null) {
      await widget.controller.deleteChat(intent);
    } else {
      await projects.deleteChat(intent);
    }
    if (!mounted) return;
    if (widget.controller.state.selectedId == null) {
      _newChatFocusNode.requestFocus();
    } else {
      _deleteFocusNode.requestFocus();
    }
  }

  AgentSessionSnapshot? get _visibleSelectedSession {
    final selected = _state.selectedSession;
    final projects = _projects;
    if (selected == null || projects == null) return selected;
    final group = projects.selectedGroup;
    if (group == null ||
        !group.chats.any((summary) => summary.id == selected.id)) {
      return null;
    }
    return selected;
  }
}

class _WorkspaceNotice extends StatelessWidget {
  const _WorkspaceNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Center(
      child: SingleChildScrollView(
        padding: DomovoyDimensions.pageInsets,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: DomovoyDimensions.settingsDialogWidth,
          ),
          child: DomovoySurface(
            role: DomovoySurfaceRole.surface,
            border: true,
            borderRadius: BorderRadius.circular(DomovoyDimensions.radiusLarge),
            padding: DomovoyDimensions.pageInsets,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: DomovoyDimensions.space10,
                  color: tokens.accent,
                ),
                const SizedBox(height: DomovoyDimensions.space5),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: DomovoyDimensions.space3),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: tokens.textSecondary),
                ),
                if (actionLabel != null) ...[
                  const SizedBox(height: DomovoyDimensions.space6),
                  DomovoyQuietButton(
                    tone: DomovoyButtonTone.accent,
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

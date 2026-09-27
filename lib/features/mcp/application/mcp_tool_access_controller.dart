import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/agents/access.dart';
import '../../../core/agents/ids.dart';
import '../../../core/llm/cancellation.dart';
import '../../../core/mcp/mcp.dart';
import '../../../core/projects/ids.dart';
import 'mcp_tool_access_state.dart';

/// Durable, deny-by-default per-chat/project MCP tool permissions.
///
/// The controller reads the live catalog from [McpHost] and persists an
/// explicit allowlist of B2 stable tool IDs per scope in
/// [McpToolSelectionStore]. A tool that appears after the record was saved is
/// never granted implicitly, and a stored ID whose tool disappeared stays
/// visible and keeps its stored state instead of being dropped silently.
final class McpToolAccessController extends ChangeNotifier {
  McpToolAccessController({
    required McpHost host,
    required McpToolSelectionStore store,
    Listenable? hostChanges,
    Map<String, String> Function()? unavailableReasons,
  }) : _host = host,
       _store = store,
       _hostChanges = hostChanges,
       _unavailableReasons = unavailableReasons;

  final McpHost _host;
  final McpToolSelectionStore _store;
  final Listenable? _hostChanges;

  /// Optional per-tool reasons (for example schema projections that cannot be
  /// represented for the provider) keyed by model-facing tool name.
  final Map<String, String> Function()? _unavailableReasons;

  final Map<String, McpToolSelectionRecord> _records =
      <String, McpToolSelectionRecord>{};
  StreamSubscription<McpHostEvent>? _hostEvents;
  AgentSessionId? _chatId;
  ProjectId? _projectId;
  McpToolAccessTargetKind _scopePreference = McpToolAccessTargetKind.chat;
  Future<void> _persistQueue = Future<void>.value();
  var _state = const McpToolAccessState();
  var _initialized = false;
  var _disposed = false;

  McpToolAccessState get state => _state;

  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    _hostChanges?.addListener(_syncFromHost);
    _hostEvents = _host.events.listen((_) => _syncFromHost());
    await _loadRecords();
  }

  /// Binds the visible chat and project and rebuilds the permission view.
  Future<void> attachScope({
    required AgentSessionId? chatId,
    required ProjectId? projectId,
  }) async {
    final changed =
        _chatId?.value != chatId?.value ||
        _projectId?.value != projectId?.value;
    _chatId = chatId;
    _projectId = projectId;
    if (changed) {
      // A different chat/project starts from the chat scope again.
      _scopePreference = McpToolAccessTargetKind.chat;
      await _loadRecords();
    } else {
      _rebuild();
    }
  }

  /// Switches between the chat scope and the project scope.
  void setScope(McpToolAccessTargetKind scope) {
    final available = switch (scope) {
      McpToolAccessTargetKind.chat => _chatId != null,
      McpToolAccessTargetKind.project => _projectId != null,
    };
    if (!available || _state.scope == scope) {
      return;
    }
    _scopePreference = scope;
    _rebuild(scope: scope);
  }

  bool isSelected(String toolId) => _state.selectedToolIds.contains(toolId);

  /// Explicit allowlist for the current scope target.
  Set<String> get selectedToolIds =>
      Set<String>.unmodifiable(_state.selectedToolIds);

  /// Effective allowlist for a chat: the chat record when one exists (even an
  /// explicit empty one), otherwise the project record, otherwise nothing.
  List<String> effectiveToolIds({
    AgentSessionId? chatId,
    ProjectId? projectId,
  }) {
    final chat = chatId == null
        ? null
        : _records[McpToolAccessTarget.chat(chatId.value).storeKey];
    if (chat != null) {
      return List<String>.unmodifiable(chat.toolIds);
    }
    final project = projectId == null
        ? null
        : _records[McpToolAccessTarget.project(projectId.value).storeKey];
    return List<String>.unmodifiable(project?.toolIds ?? const <String>[]);
  }

  /// Reads the stored allowlist for a target without binding the UI.
  Future<List<String>> storedToolIdsFor(McpToolAccessTarget target) async {
    final record = _records[target.storeKey] ?? await _store.load(target);
    return List<String>.unmodifiable(record?.toolIds ?? const <String>[]);
  }

  /// Explicit B2 grant built from the current live catalog.
  ///
  /// Rights never widen on their own: only the stored IDs are allowed, and the
  /// runtime re-checks the live route before every call.
  ToolAccessGrant buildGrant({
    AgentSessionId? chatId,
    ProjectId? projectId,
    bool askOnDestructive = true,
  }) {
    return ToolAccessGrant.forMcpCatalog(
      catalog: _host.snapshot.catalog,
      allowedToolIds: effectiveToolIds(chatId: chatId, projectId: projectId),
      askOnDestructive: askOnDestructive,
    );
  }

  Future<void> toggleTool(String toolId, bool selected) async {
    final target = _state.target;
    if (target == null || _disposed) {
      return;
    }
    final next = Set<String>.of(_state.selectedToolIds);
    if (selected) {
      next.add(toolId);
    } else {
      next.remove(toolId);
    }
    _rebuild(selectedOverride: next);
    await _schedulePersist(target, next);
  }

  /// Grants every tool of one connection as currently announced.
  Future<void> setConnectionSelected(
    McpConnectionId connectionId,
    bool selected,
  ) async {
    final target = _state.target;
    if (target == null || _disposed) {
      return;
    }
    final next = Set<String>.of(_state.selectedToolIds);
    for (final connection in _state.connections) {
      if (connection.connectionId != connectionId) {
        continue;
      }
      for (final tool in connection.tools) {
        if (selected) {
          next.add(tool.toolId);
        } else {
          next.remove(tool.toolId);
        }
      }
    }
    _rebuild(selectedOverride: next);
    await _schedulePersist(target, next);
  }

  Future<void> selectAll() async {
    final target = _state.target;
    if (target == null || _disposed) {
      return;
    }
    final next = <String>{
      for (final connection in _state.connections)
        for (final tool in connection.tools) tool.toolId,
    };
    _rebuild(selectedOverride: next);
    await _schedulePersist(target, next);
  }

  Future<void> clearSelection() async {
    final target = _state.target;
    if (target == null || _disposed) {
      return;
    }
    _rebuild(selectedOverride: const <String>{});
    await _schedulePersist(target, const <String>{});
  }

  Future<void> _schedulePersist(
    McpToolAccessTarget target,
    Set<String> toolIds,
  ) {
    _persistQueue = _persistQueue.then((_) => _persist(target, toolIds));
    return _persistQueue;
  }

  Future<void> _persist(McpToolAccessTarget target, Set<String> toolIds) async {
    if (_disposed) {
      return;
    }
    final existing = _records[target.storeKey];
    final record = McpToolSelectionRecord(
      target: target,
      toolIds: toolIds,
      revision: (existing?.revision ?? 0) + (existing == null ? 0 : 1),
    );
    try {
      await _store.save(
        record,
        expectedRevision: existing?.revision ?? 0,
        cancellation: CancellationSource().token,
      );
      _records[target.storeKey] = record;
      _emit(
        _state.copyWith(
          selectedToolIds: Set<String>.unmodifiable(record.toolIds),
          clearError: true,
          busy: false,
        ),
      );
    } on McpException catch (error) {
      await _loadRecords();
      _emit(
        _state.copyWith(
          error: sanitizeMcpText(
            error.error.message,
            fallback: sanitizedMcpPersistenceMessage(),
          ),
          busy: false,
        ),
      );
    } on Object {
      await _loadRecords();
      _emit(
        _state.copyWith(error: sanitizedMcpPersistenceMessage(), busy: false),
      );
    }
  }

  Future<void> _loadRecords() async {
    if (_disposed) {
      return;
    }
    try {
      final records = await _store.loadAll();
      if (_disposed) {
        return;
      }
      _records
        ..clear()
        ..addEntries(
          records.map((record) => MapEntry(record.target.storeKey, record)),
        );
      _rebuild(clearError: true);
    } on McpException catch (error) {
      if (_disposed) {
        return;
      }
      _emit(
        _state.copyWith(
          status: McpToolAccessStatus.failed,
          error: sanitizeMcpText(
            error.error.message,
            fallback: sanitizedMcpPersistenceMessage(),
          ),
        ),
      );
    } on Object {
      if (_disposed) {
        return;
      }
      _emit(
        _state.copyWith(
          status: McpToolAccessStatus.failed,
          error: sanitizedMcpPersistenceMessage(),
        ),
      );
    }
  }

  void _syncFromHost() {
    if (_disposed || !_initialized) {
      return;
    }
    _rebuild();
  }

  McpToolAccessTarget? get _target {
    final chatId = _chatId;
    final projectId = _projectId;
    if (chatId != null && projectId != null) {
      return switch (_state.scope) {
        McpToolAccessTargetKind.chat => McpToolAccessTarget.chat(chatId.value),
        McpToolAccessTargetKind.project => McpToolAccessTarget.project(
          projectId.value,
        ),
      };
    }
    if (chatId != null) {
      return McpToolAccessTarget.chat(chatId.value);
    }
    if (projectId != null) {
      return McpToolAccessTarget.project(projectId.value);
    }
    return null;
  }

  /// Current scope target, rebuilt from the bound chat/project and scope.
  McpToolAccessTarget? get target => _target;

  void _rebuild({
    McpToolAccessTargetKind? scope,
    Set<String>? selectedOverride,
    bool clearError = false,
  }) {
    if (_disposed) {
      return;
    }
    var effectiveScope = scope ?? _scopePreference;
    if (_chatId == null) {
      effectiveScope = McpToolAccessTargetKind.project;
    } else if (_projectId == null) {
      effectiveScope = McpToolAccessTargetKind.chat;
    }
    final target = _targetForScope(effectiveScope);
    final record = target == null ? null : _records[target.storeKey];
    final selected =
        selectedOverride ??
        (record == null ? const <String>{} : record.toolIds.toSet());
    final connections = _buildConnections(selected);
    final catalogIds = <String>{
      for (final connection in connections)
        for (final tool in connection.tools) tool.toolId,
    };
    final missing = selected.where((id) => !catalogIds.contains(id)).toList()
      ..sort();
    _emit(
      _state.copyWith(
        status: McpToolAccessStatus.ready,
        target: target,
        scope: effectiveScope,
        hasChat: _chatId != null,
        hasProject: _projectId != null,
        connections: List<McpToolAccessConnection>.unmodifiable(connections),
        selectedToolIds: Set<String>.unmodifiable(selected),
        missingSelectedToolIds: List<String>.unmodifiable(missing),
        busy: selectedOverride == null ? null : true,
        clearError: clearError,
      ),
    );
  }

  McpToolAccessTarget? _targetForScope(McpToolAccessTargetKind scope) {
    final chatId = _chatId;
    final projectId = _projectId;
    return switch (scope) {
      McpToolAccessTargetKind.chat =>
        chatId == null ? null : McpToolAccessTarget.chat(chatId.value),
      McpToolAccessTargetKind.project =>
        projectId == null ? null : McpToolAccessTarget.project(projectId.value),
    };
  }

  List<McpToolAccessConnection> _buildConnections(Set<String> selected) {
    final snapshot = _host.snapshot;
    final statuses = <String, McpConnectionStatus>{
      for (final status in snapshot.connections) status.id.value: status,
    };
    final grouped = <String, List<McpToolRoute>>{};
    for (final route in snapshot.catalog.routes) {
      grouped
          .putIfAbsent(route.connectionId.value, () => <McpToolRoute>[])
          .add(route);
    }
    final unavailable = _unavailableReasons?.call() ?? const <String, String>{};
    final keys = grouped.keys.toList()..sort();
    final connections = <McpToolAccessConnection>[];
    for (final key in keys) {
      final routes = grouped[key]!
        ..sort((a, b) => a.originalToolName.compareTo(b.originalToolName));
      final status = statuses[key];
      final connectionReason = _connectionReason(status);
      final tools = <McpToolAccessTool>[];
      for (final route in routes) {
        final toolId = route.modelToolName.value;
        tools.add(
          McpToolAccessTool(
            toolId: toolId,
            originalName: route.originalToolName,
            selected: selected.contains(toolId),
            inCatalog: true,
            title: route.descriptor.title,
            description: route.descriptor.description,
            destructive:
                route.descriptor.annotations?['destructiveHint'] == true,
            unavailableReason: unavailable[toolId],
            connectionUnavailableReason: connectionReason,
          ),
        );
      }
      connections.add(
        McpToolAccessConnection(
          connectionId: McpConnectionId(key),
          alias: status?.alias ?? key,
          tools: List<McpToolAccessTool>.unmodifiable(tools),
          enabled: status?.phase != McpConnectionPhase.disabled,
          connected: status?.phase == McpConnectionPhase.ready,
          unavailableReason: connectionReason,
        ),
      );
    }
    return connections;
  }

  String? _connectionReason(McpConnectionStatus? status) {
    if (status == null) {
      return 'Сервер не подключён в этой сессии.';
    }
    if (status.phase == McpConnectionPhase.disabled) {
      return 'Сервер отключён в настройках.';
    }
    // A failed refresh keeps the previous catalog; the error is still shown
    // so the user knows the list may be stale.
    if (status.lastError != null) {
      return status.lastError;
    }
    return switch (status.phase) {
      McpConnectionPhase.disabled => 'Сервер отключён в настройках.',
      McpConnectionPhase.stopped => 'Сервер не подключён.',
      McpConnectionPhase.connecting => 'Идёт подключение…',
      McpConnectionPhase.failed =>
        status.lastError ?? 'Не удалось подключиться к серверу.',
      McpConnectionPhase.ready => null,
    };
  }

  void _emit(McpToolAccessState next) {
    if (_disposed) {
      return;
    }
    _state = next.copyWith(revision: _state.revision + 1);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_hostEvents?.cancel());
    _hostEvents = null;
    _hostChanges?.removeListener(_syncFromHost);
    super.dispose();
  }
}

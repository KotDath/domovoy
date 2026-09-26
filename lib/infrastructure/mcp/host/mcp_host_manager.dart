import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/llm/cancellation.dart';
import '../../../core/mcp/mcp.dart';
import '../mcp_diagnostics.dart';

/// Bounded automatic reconnect policy for failed connections.
final class McpReconnectPolicy {
  const McpReconnectPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(seconds: 30),
  }) : assert(maxAttempts >= 0);

  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;

  Duration delayFor(int attempt) {
    var delay = initialDelay;
    for (var index = 1; index < attempt; index += 1) {
      delay *= 2;
      if (delay >= maxDelay) {
        return maxDelay;
      }
    }
    return delay > maxDelay ? maxDelay : delay;
  }
}

/// Owns MCP connections, the atomic tool catalog and call routing.
///
/// One instance is composed explicitly in `lib/app.dart` by the B9 integrator.
/// It exposes [ChangeNotifier] notifications for the UI and a broadcast event
/// stream with human-readable lifecycle and call traces.
final class McpHostManager extends ChangeNotifier implements McpHost {
  McpHostManager({
    required McpTransportFactory transports,
    required McpConnectionRepository repository,
    required McpSecretResolver secrets,
    McpTimeouts timeouts = const McpTimeouts(),
    McpReconnectPolicy reconnectPolicy = const McpReconnectPolicy(),
    McpDiagnosticsSink diagnostics = const NoopMcpDiagnosticsSink(),
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : _transports = transports,
       _repository = repository,
       _secrets = secrets,
       _timeouts = timeouts,
       _reconnectPolicy = reconnectPolicy,
       _diagnostics = diagnostics,
       _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  static const maxCatalogPages = 64;

  final McpTransportFactory _transports;
  final McpConnectionRepository _repository;
  final McpSecretResolver _secrets;
  final McpTimeouts _timeouts;
  final McpReconnectPolicy _reconnectPolicy;
  final McpDiagnosticsSink _diagnostics;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  final Map<String, McpConnectionConfig> _configs =
      <String, McpConnectionConfig>{};
  final Map<String, McpConnectionStatus> _statuses =
      <String, McpConnectionStatus>{};
  final Map<String, McpTransportConnection> _connections =
      <String, McpTransportConnection>{};
  final Map<String, List<McpToolDescriptor>> _tools =
      <String, List<McpToolDescriptor>>{};
  final Map<String, int> _deletedRevisions = <String, int>{};
  final Map<String, int> _reconnectGenerations = <String, int>{};
  final Map<String, int> _reconnectAttempts = <String, int>{};
  final Set<String> _refreshing = <String>{};

  final StreamController<McpHostEvent> _events =
      StreamController<McpHostEvent>.broadcast(sync: true);
  CancellationSource _stopSource = CancellationSource();
  final CancellationToken _neverCancelled = CancellationSource().token;

  McpCatalog _catalog = McpCatalog.empty;
  var _revision = 0;
  var _started = false;
  var _stopped = false;

  @override
  McpHostSnapshot get snapshot {
    final statuses = _statuses.values.toList()
      ..sort((a, b) => a.id.value.compareTo(b.id.value));
    return McpHostSnapshot(
      revision: _revision,
      connections: List<McpConnectionStatus>.unmodifiable(statuses),
      catalog: _catalog,
    );
  }

  @override
  Stream<McpHostEvent> get events => _events.stream;

  bool get isStarted => _started && !_stopped;

  @override
  Future<void> start({CancellationToken? cancellation}) async {
    if (_started && !_stopped) {
      return;
    }
    _started = true;
    _stopped = false;
    _stopSource = CancellationSource();
    final token = cancellation ?? _neverCancelled;
    List<McpConnectionConfig> configs;
    try {
      configs = await _repository.loadAll();
    } on McpException catch (error) {
      _diagnostics.log('mcp configuration load failed: ${error.error.message}');
      configs = const <McpConnectionConfig>[];
    }
    for (final config in configs) {
      _configs[config.connectionId.value] = config;
      _statuses[config.connectionId.value] = McpConnectionStatus(
        id: config.connectionId,
        alias: config.alias,
        phase: config.enabled
            ? McpConnectionPhase.stopped
            : McpConnectionPhase.disabled,
        updatedAt: _now(),
      );
    }
    notifyListeners();
    await Future.wait(<Future<void>>[
      for (final config in configs)
        if (config.enabled) _connectAndSettle(config, token),
    ]);
  }

  @override
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _stopSource.cancel();
    _cancelReconnectTimers();
    final connections = _connections.values.toList(growable: false);
    _connections.clear();
    _tools.clear();
    for (final connection in connections) {
      try {
        await connection.close();
      } on Object {
        // Shutdown is best effort.
      }
    }
    for (final entry in _statuses.entries.toList(growable: false)) {
      final config = _configs[entry.key];
      _statuses[entry.key] = entry.value.copyWith(
        phase: config != null && !config.enabled
            ? McpConnectionPhase.disabled
            : McpConnectionPhase.stopped,
        clearHandshake: true,
        toolCount: 0,
        clearError: true,
        updatedAt: _now(),
      );
    }
    _rebuildCatalog(changed: _configs.keys.map(McpConnectionId.new).toList());
    notifyListeners();
  }

  @override
  Future<void> upsertConnection(
    McpConnectionConfig config, {
    bool connect = true,
  }) async {
    final id = config.connectionId;
    final existing = _configs[id.value];
    final expectedRevision =
        existing?.revision ?? _deletedRevisions[id.value] ?? 0;
    final normalized = config.copyWith(revision: expectedRevision + 1);
    await _repository.save(
      normalized,
      expectedRevision: expectedRevision,
      cancellation: _stopSource.token,
    );
    _configs[id.value] = normalized;
    _deletedRevisions.remove(id.value);
    _reconnectAttempts.remove(id.value);
    await _disconnectInternal(id);
    if (normalized.enabled && connect) {
      await _connectAndSettle(normalized, _stopSource.token);
    } else {
      _statuses[id.value] = McpConnectionStatus(
        id: id,
        alias: normalized.alias,
        phase: normalized.enabled
            ? McpConnectionPhase.stopped
            : McpConnectionPhase.disabled,
        updatedAt: _now(),
      );
      _rebuildCatalog(changed: <McpConnectionId>[id]);
      notifyListeners();
    }
  }

  @override
  Future<void> removeConnection(McpConnectionId id) async {
    final existing = _configs[id.value];
    if (existing == null) {
      throwMcp(
        McpErrorKind.configuration,
        'Unknown MCP connection "${id.value}".',
      );
    }
    await _repository.delete(
      id,
      expectedRevision: existing.revision,
      cancellation: _stopSource.token,
    );
    _deletedRevisions[id.value] = existing.revision;
    _configs.remove(id.value);
    _statuses.remove(id.value);
    _reconnectAttempts.remove(id.value);
    await _disconnectInternal(id);
    _rebuildCatalog(changed: <McpConnectionId>[id]);
    notifyListeners();
  }

  @override
  Future<void> connect(McpConnectionId id) async {
    final config = _configs[id.value];
    if (config == null) {
      throwMcp(
        McpErrorKind.configuration,
        'Unknown MCP connection "${id.value}".',
      );
    }
    _reconnectAttempts.remove(id.value);
    _cancelReconnectTimer(id);
    await _connectAndSettle(config, _stopSource.token);
  }

  @override
  Future<void> disconnect(McpConnectionId id) async {
    final config = _configs[id.value];
    if (config == null) {
      throwMcp(
        McpErrorKind.configuration,
        'Unknown MCP connection "${id.value}".',
      );
    }
    _reconnectAttempts.remove(id.value);
    _cancelReconnectTimer(id);
    await _disconnectInternal(id);
    _statuses[id.value] = (_statuses[id.value] ?? _statusFor(config)).copyWith(
      phase: config.enabled
          ? McpConnectionPhase.stopped
          : McpConnectionPhase.disabled,
      clearHandshake: true,
      toolCount: 0,
      clearError: true,
      updatedAt: _now(),
    );
    _rebuildCatalog(changed: <McpConnectionId>[id]);
    notifyListeners();
  }

  @override
  Future<void> restart(McpConnectionId id) async {
    await disconnect(id);
    await connect(id);
  }

  @override
  Future<void> refreshCatalog([McpConnectionId? id]) async {
    final ids = id == null
        ? _connections.keys.map(McpConnectionId.new).toList(growable: false)
        : <McpConnectionId>[id];
    final changed = <McpConnectionId>[];
    for (final connectionId in ids) {
      final connection = _connections[connectionId.value];
      if (connection == null) {
        continue;
      }
      try {
        final tools = await _listAllTools(connection, _stopSource.token);
        _tools[connectionId.value] = tools;
        _statuses[connectionId.value] =
            (_statuses[connectionId.value] ??
                    _statusFor(_configs[connectionId.value]!))
                .copyWith(
                  phase: McpConnectionPhase.ready,
                  toolCount: tools.length,
                  clearError: true,
                  updatedAt: _now(),
                );
      } on McpException catch (error) {
        // A failed refresh keeps the previous catalog: the connection may
        // still serve its old tools, and any removed tool fails explicitly at
        // call time. The error is surfaced in the status and diagnostics.
        _statuses[connectionId.value] =
            (_statuses[connectionId.value] ??
                    _statusFor(_configs[connectionId.value]!))
                .copyWith(lastError: error.error.message, updatedAt: _now());
        _diagnostics.log(
          'mcp catalog refresh failed for ${connectionId.value}: '
          '${error.error.message}',
        );
      }
      changed.add(connectionId);
    }
    if (changed.isNotEmpty) {
      _rebuildCatalog(changed: changed);
      notifyListeners();
    }
  }

  @override
  Future<McpToolCallResult> callTool({
    required String modelToolName,
    required Map<String, Object?> arguments,
    Duration? timeout,
    CancellationToken? cancellation,
    void Function(double progress)? onProgress,
  }) async {
    final route = _catalog.lookup(modelToolName);
    if (route == null) {
      throwMcp(McpErrorKind.toolNotFound, sanitizedMcpToolMissingMessage());
    }
    final connection = _connections[route.connectionId.value];
    if (connection == null || !connection.isConnected) {
      throwMcp(McpErrorKind.unavailable, sanitizedMcpUnavailableMessage());
    }
    final started = _now();
    try {
      final result = await connection.callTool(
        originalToolName: route.originalToolName,
        arguments: arguments,
        timeout: timeout ?? _timeouts.call,
        cancellation: cancellation ?? _neverCancelled,
        onProgress: onProgress,
      );
      _emitCallCompleted(route, isError: result.isError, started: started);
      return result;
    } on McpException {
      _emitCallCompleted(route, isError: true, started: started);
      rethrow;
    }
  }

  @override
  void dispose() {
    _stopped = true;
    _stopSource.cancel();
    _cancelReconnectTimers();
    for (final connection in _connections.values) {
      unawaited(connection.close());
    }
    _connections.clear();
    _tools.clear();
    unawaited(_events.close());
    super.dispose();
  }

  Future<void> _connectAndSettle(
    McpConnectionConfig config,
    CancellationToken token,
  ) async {
    final id = config.connectionId;
    await _disconnectInternal(id);
    _setStatus(
      id,
      (_statuses[id.value] ?? _statusFor(config)).copyWith(
        alias: config.alias,
        phase: McpConnectionPhase.connecting,
        clearError: true,
        updatedAt: _now(),
      ),
    );
    McpTransportConnection? connection;
    try {
      connection = await _transports.create(config, secrets: _secrets);
      connection.onUnexpectedClose = () {
        _handleUnexpectedClose(id);
      };
      connection.onToolsChanged = () {
        _handleToolsChanged(id);
      };
      final handshake = await connection.connect(
        timeout: _timeouts.connect,
        cancellation: token,
      );
      final tools = await _listAllTools(connection, token);
      if (_stopped) {
        await connection.close();
        return;
      }
      _connections[id.value] = connection;
      _tools[id.value] = tools;
      _reconnectAttempts.remove(id.value);
      _setStatus(
        id,
        (_statuses[id.value] ?? _statusFor(config)).copyWith(
          phase: McpConnectionPhase.ready,
          handshake: handshake,
          toolCount: tools.length,
          clearError: true,
          updatedAt: _now(),
        ),
      );
      _diagnostics.log(
        'mcp connection ${id.value} ready: '
        '${handshake.serverName} ${handshake.serverVersion} '
        '(protocol ${handshake.protocolVersion}), ${tools.length} tools',
      );
      _rebuildCatalog(changed: <McpConnectionId>[id]);
      notifyListeners();
    } on Object catch (error) {
      await connection?.close();
      final message = _describeFailure(error);
      _statuses[id.value] = (_statuses[id.value] ?? _statusFor(config))
          .copyWith(
            phase: McpConnectionPhase.failed,
            clearHandshake: true,
            toolCount: 0,
            lastError: message,
            updatedAt: _now(),
          );
      _diagnostics.log('mcp connection ${id.value} failed: $message');
      _emit(
        McpConnectionPhaseChanged(
          at: _now(),
          connectionId: id,
          phase: McpConnectionPhase.failed,
          error: message,
        ),
      );
      _rebuildCatalog(changed: <McpConnectionId>[id]);
      notifyListeners();
      _scheduleReconnect(id);
    }
  }

  Future<void> _disconnectInternal(McpConnectionId id) async {
    _cancelReconnectTimer(id);
    final connection = _connections.remove(id.value);
    _tools.remove(id.value);
    if (connection != null) {
      try {
        await connection.close();
      } on Object {
        // The session may already be gone.
      }
    }
  }

  void _handleToolsChanged(McpConnectionId id) {
    if (_stopped || _refreshing.contains(id.value)) {
      return;
    }
    final connection = _connections[id.value];
    if (connection == null) {
      return;
    }
    _refreshing.add(id.value);
    unawaited(
      refreshCatalog(id).whenComplete(() {
        _refreshing.remove(id.value);
      }),
    );
  }

  void _handleUnexpectedClose(McpConnectionId id) {
    final status = _statuses[id.value];
    if (status == null || status.phase != McpConnectionPhase.ready) {
      return;
    }
    _connections.remove(id.value);
    _tools.remove(id.value);
    final message = sanitizedMcpUnavailableMessage();
    _statuses[id.value] = status.copyWith(
      phase: McpConnectionPhase.failed,
      clearHandshake: true,
      toolCount: 0,
      lastError: message,
      updatedAt: _now(),
    );
    _emit(
      McpConnectionPhaseChanged(
        at: _now(),
        connectionId: id,
        phase: McpConnectionPhase.failed,
        error: message,
      ),
    );
    _rebuildCatalog(changed: <McpConnectionId>[id]);
    notifyListeners();
    _scheduleReconnect(id);
  }

  void _scheduleReconnect(McpConnectionId id) {
    if (_stopped || _reconnectPolicy.maxAttempts <= 0) {
      return;
    }
    final config = _configs[id.value];
    if (config == null || !config.enabled) {
      return;
    }
    final attempt = (_reconnectAttempts[id.value] ?? 0) + 1;
    _reconnectAttempts[id.value] = attempt;
    if (attempt > _reconnectPolicy.maxAttempts) {
      _reconnectAttempts.remove(id.value);
      return;
    }
    final generation = (_reconnectGenerations[id.value] ?? 0) + 1;
    _reconnectGenerations[id.value] = generation;
    unawaited(
      _delayedReconnect(config, _reconnectPolicy.delayFor(attempt), generation),
    );
  }

  Future<void> _delayedReconnect(
    McpConnectionConfig config,
    Duration delay,
    int generation,
  ) async {
    await _delay(delay);
    if (_stopped ||
        _reconnectGenerations[config.connectionId.value] != generation) {
      return;
    }
    _reconnectGenerations.remove(config.connectionId.value);
    await _reconnect(config);
  }

  Future<void> _reconnect(McpConnectionConfig config) async {
    if (_stopped) {
      return;
    }
    final id = config.connectionId;
    final current = _configs[id.value];
    if (current == null || !current.enabled) {
      return;
    }
    await _connectAndSettle(current, _stopSource.token);
    if (_statuses[id.value]?.phase == McpConnectionPhase.ready) {
      _reconnectAttempts.remove(id.value);
    } else if (_reconnectAttempts[id.value] == null ||
        _reconnectAttempts[id.value]! <= _reconnectPolicy.maxAttempts) {
      _scheduleReconnect(id);
    }
  }

  Future<List<McpToolDescriptor>> _listAllTools(
    McpTransportConnection connection,
    CancellationToken token,
  ) async {
    final tools = <McpToolDescriptor>[];
    final seenCursors = <String>{};
    String? cursor;
    for (var page = 0; page < maxCatalogPages; page += 1) {
      final result = await connection.listTools(
        cursor: cursor,
        timeout: _timeouts.catalog,
        cancellation: token,
      );
      tools.addAll(result.tools);
      final next = result.nextCursor;
      if (next == null) {
        return _dedupeTools(tools);
      }
      if (!seenCursors.add(next)) {
        throwMcp(
          McpErrorKind.protocol,
          'MCP tools/list repeated a pagination cursor.',
        );
      }
      cursor = next;
    }
    throwMcp(McpErrorKind.protocol, 'MCP tools/list exceeded the page limit.');
  }

  List<McpToolDescriptor> _dedupeTools(List<McpToolDescriptor> tools) {
    final seen = <String>{};
    final result = <McpToolDescriptor>[];
    for (final tool in tools) {
      if (seen.add(tool.originalName)) {
        result.add(tool);
      }
    }
    return List<McpToolDescriptor>.unmodifiable(result);
  }

  void _rebuildCatalog({required List<McpConnectionId> changed}) {
    final builder = McpCatalogBuilder(revision: _revision + 1);
    for (final entry in _tools.entries) {
      builder.addConnection(McpConnectionId(entry.key), entry.value);
    }
    final candidate = builder.build();
    if (_signature(candidate) == _signature(_catalog)) {
      return;
    }
    _revision += 1;
    _catalog = McpCatalog(revision: _revision, routes: candidate.routes);
    _emit(
      McpCatalogChanged(
        at: _now(),
        revision: _revision,
        toolCount: _catalog.length,
        changedConnections: List<McpConnectionId>.unmodifiable(changed),
      ),
    );
  }

  String _signature(McpCatalog catalog) => catalog.routes
      .map(
        (route) =>
            '${route.connectionId.value}\u0000'
            '${route.originalToolName}\u0000${route.modelToolName.value}',
      )
      .join('|');

  McpConnectionStatus _statusFor(McpConnectionConfig config) =>
      McpConnectionStatus(
        id: config.connectionId,
        alias: config.alias,
        phase: McpConnectionPhase.stopped,
      );

  void _setStatus(McpConnectionId id, McpConnectionStatus status) {
    _statuses[id.value] = status;
    _emit(
      McpConnectionPhaseChanged(
        at: _now(),
        connectionId: id,
        phase: status.phase,
        error: status.lastError,
      ),
    );
    notifyListeners();
  }

  void _emitCallCompleted(
    McpToolRoute route, {
    required bool isError,
    required DateTime started,
  }) {
    _emit(
      McpToolCallCompleted(
        at: _now(),
        modelToolName: route.modelToolName.value,
        connectionId: route.connectionId,
        originalToolName: route.originalToolName,
        isError: isError,
        duration: _now().difference(started),
      ),
    );
  }

  void _cancelReconnectTimers() {
    _reconnectGenerations.clear();
  }

  void _cancelReconnectTimer(McpConnectionId id) {
    _reconnectGenerations.remove(id.value);
  }

  void _emit(McpHostEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  String _describeFailure(Object error) {
    if (error is McpException) {
      return error.error.message;
    }
    return sanitizeMcpText(
      error.toString(),
      fallback: sanitizedMcpUnavailableMessage(),
    );
  }
}

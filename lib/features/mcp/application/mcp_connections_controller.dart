import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/llm/cancellation.dart';
import '../../../core/mcp/mcp.dart';
import '../domain/connection_draft.dart';
import '../domain/platform_capabilities.dart';
import 'mcp_connection_probe.dart';
import 'mcp_connections_state.dart';

/// Application controller behind the MCP connections screen and editor.
///
/// Owns the device-local CRUD flow, explicit handshake/catalog checks and
/// credential handling. Secrets are written to the injected [McpSecretVault]
/// and never returned to the UI: the editor only learns that a value exists.
///
/// Edits are compare-and-update against [McpConnectionRepository]: a form
/// opened at revision `r` is rejected with a visible conflict when the stored
/// connection has moved on, so the host's revision computation can never
/// silently overwrite a newer change with a stale form snapshot.
final class McpConnectionsController extends ChangeNotifier {
  McpConnectionsController({
    required McpHost host,
    required McpConnectionRepository repository,
    required McpSecretVault secrets,
    required McpPlatformCapabilities capabilities,
    required McpConnectionProbe probe,
    Listenable? hostChanges,
    Set<String> builtInConnectionIds = const <String>{},
  }) : _host = host,
       _repository = repository,
       _secrets = secrets,
       _capabilities = capabilities,
       _probe = probe,
       _hostChanges = hostChanges,
       _builtInConnectionIds = Set<String>.unmodifiable(builtInConnectionIds);

  final McpHost _host;
  final McpConnectionRepository _repository;
  final McpSecretVault _secrets;
  final McpPlatformCapabilities _capabilities;
  final McpConnectionProbe _probe;
  final Listenable? _hostChanges;
  final Set<String> _builtInConnectionIds;

  final Map<String, McpConnectionConfig> _configs =
      <String, McpConnectionConfig>{};
  final Map<String, List<McpSecretReference>> _pendingSecretCleanup =
      <String, List<McpSecretReference>>{};
  StreamSubscription<McpHostEvent>? _hostEvents;
  CancellationSource? _probeCancellation;
  var _state = const McpConnectionsState();
  var _initialized = false;
  var _disposed = false;
  var _configReloadScheduled = false;

  McpConnectionsState get state => _state;

  McpPlatformCapabilities get capabilities => _capabilities;

  bool get isInitialized => _initialized;

  /// Loads stored connections and starts tracking live host state.
  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }
    _initialized = true;
    _hostChanges?.addListener(_syncFromHost);
    _hostEvents = _host.events.listen((_) => _syncFromHost());
    await refresh();
  }

  /// Re-reads persisted configuration and merges host statuses.
  Future<void> refresh() async {
    if (_disposed) {
      return;
    }
    _emit(_state.copyWith(status: McpConnectionsStatus.loading));
    try {
      final configs = await _repository.loadAll();
      if (_disposed) {
        return;
      }
      _applyConfigs(configs);
      _publishFromHost(
        status: McpConnectionsStatus.ready,
        clearConfigurationError: true,
        clearError: true,
      );
    } on McpException catch (error) {
      if (_disposed) {
        return;
      }
      _emit(
        _state.copyWith(
          status: McpConnectionsStatus.failed,
          error: sanitizeMcpText(
            error.error.message,
            fallback: sanitizedMcpPersistenceMessage(),
          ),
          configurationError: error.error,
        ),
      );
    } on Object {
      if (_disposed) {
        return;
      }
      _emit(
        _state.copyWith(
          status: McpConnectionsStatus.failed,
          error: sanitizedMcpPersistenceMessage(),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------
  // Editor
  // ---------------------------------------------------------------------

  /// Opens an empty editor. The default transport is the first one the
  /// injected platform capabilities allow.
  void beginCreate({McpConnectionTransportChoice? transport}) {
    final choice =
        transport ??
        (_capabilities.supportsRemoteHttp
            ? McpConnectionTransportChoice.streamableHttp
            : McpConnectionTransportChoice.stdio);
    _emit(
      _state.copyWith(
        draft: McpConnectionDraft.create(transport: choice),
        probeStatus: McpProbeStatus.idle,
        clearProbeResult: true,
        clearEditorError: true,
      ),
    );
  }

  /// Opens the editor for one stored external connection.
  ///
  /// Returns `false` (and records a visible error) for unknown or built-in
  /// connections, which are owned by the composition. The configuration is
  /// read from the repository so an edit always starts from the latest
  /// revision, even when another writer changed it after the list was drawn.
  Future<bool> beginEdit(String connectionId) async {
    final config = await _loadConfig(connectionId) ?? _configs[connectionId];
    if (config == null) {
      _emit(
        _state.copyWith(
          editorError: 'Подключение не найдено. Обновите список.',
        ),
      );
      return false;
    }
    if (_isBuiltIn(config)) {
      _emit(
        _state.copyWith(
          editorError:
              'Встроенный сервер настраивается приложением и не редактируется.',
        ),
      );
      return false;
    }
    try {
      final draft = McpConnectionDraft.fromConfig(config);
      _emit(
        _state.copyWith(
          draft: draft,
          probeStatus: McpProbeStatus.idle,
          clearProbeResult: true,
          clearEditorError: true,
        ),
      );
      return true;
    } on McpException catch (error) {
      _emit(
        _state.copyWith(
          editorError: sanitizeMcpText(
            error.error.message,
            fallback: 'Это подключение нельзя изменить.',
          ),
        ),
      );
      return false;
    }
  }

  void closeEditor() {
    _probeCancellation?.cancel();
    _probeCancellation = null;
    _emit(
      _state.copyWith(
        clearDraft: true,
        probeStatus: McpProbeStatus.idle,
        clearProbeResult: true,
        clearEditorError: true,
      ),
    );
  }

  /// Applies a transformation to the open draft.
  void updateDraft(
    McpConnectionDraft Function(McpConnectionDraft draft) change,
  ) {
    final draft = _state.draft;
    if (draft == null) {
      return;
    }
    _emit(_state.copyWith(draft: change(draft), clearEditorError: true));
  }

  void setDraftArgsText(String text) {
    final args = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    updateDraft((draft) => draft.copyWith(args: args));
  }

  void setEnvironmentVariable(String name, String value) {
    updateDraft((draft) {
      final environment = Map<String, String>.of(draft.environment);
      final trimmed = name.trim();
      if (trimmed.isEmpty) {
        return draft;
      }
      environment[trimmed] = value;
      return draft.copyWith(environment: environment);
    });
  }

  void removeEnvironmentVariable(String name) {
    updateDraft((draft) {
      final environment = Map<String, String>.of(draft.environment)
        ..remove(name);
      return draft.copyWith(environment: environment);
    });
  }

  void setSecretEnvironmentVariable(String name, String value) {
    updateDraft((draft) {
      final trimmed = name.trim();
      if (trimmed.isEmpty) {
        return draft;
      }
      final secretEnvironment = Map<String, String>.of(draft.secretEnvironment)
        ..[trimmed] = value;
      final removed = Set<String>.of(draft.removedSecretEnvironment)
        ..remove(trimmed);
      return draft.copyWith(
        secretEnvironment: secretEnvironment,
        removedSecretEnvironment: removed,
      );
    });
  }

  void removeSecretEnvironmentVariable(String name) {
    updateDraft((draft) {
      final secretEnvironment = Map<String, String>.of(draft.secretEnvironment)
        ..remove(name);
      final removed = Set<String>.of(draft.removedSecretEnvironment);
      if (draft.secretEnvironmentStored.contains(name)) {
        removed.add(name);
      }
      return draft.copyWith(
        secretEnvironment: secretEnvironment,
        removedSecretEnvironment: removed,
      );
    });
  }

  /// Runs handshake plus complete `tools/list` for the current form values.
  ///
  /// Works before the connection is saved; draft secret inputs are resolved
  /// locally and never leave the process.
  Future<void> checkDraft() async {
    final draft = _state.draft;
    if (draft == null || _state.isProbing || _disposed) {
      return;
    }
    final cancellation = CancellationSource();
    _probeCancellation = cancellation;
    _emit(
      _state.copyWith(
        probeStatus: McpProbeStatus.running,
        clearProbeResult: true,
        clearEditorError: true,
      ),
    );
    try {
      final capabilityError = _capabilityError(draft);
      if (capabilityError != null) {
        _emit(
          _state.copyWith(
            probeStatus: McpProbeStatus.failure,
            probeResult: McpProbeResult.failure(
              errorKind: McpErrorKind.unsupported,
              error: capabilityError,
            ),
          ),
        );
        return;
      }
      final config = _composeConfig(draft, revision: draft.baseRevision ?? 0);
      // Draft values plus every value the resolver actually reads are the
      // redaction set for any server/transport error text.
      final redactions = <String>{..._draftSecretValues(draft)};
      final result = await _probe.run(
        config,
        secrets: McpRecordingSecretResolver(
          inner: _draftResolver(draft),
          redactions: redactions,
        ),
        redactions: redactions,
        cancellation: cancellation.token,
      );
      if (!identical(_probeCancellation, cancellation) || _disposed) {
        return;
      }
      _emit(
        _state.copyWith(
          probeStatus: result.ok
              ? McpProbeStatus.success
              : McpProbeStatus.failure,
          probeResult: result,
        ),
      );
    } on McpException catch (error) {
      if (!identical(_probeCancellation, cancellation) || _disposed) {
        return;
      }
      _emit(
        _state.copyWith(
          probeStatus: McpProbeStatus.failure,
          probeResult: McpProbeResult.failure(
            errorKind: error.error.kind,
            error: sanitizeMcpFailureForUi(
              error.error.message,
              secretValues: _draftSecretValues(draft),
              fallback: sanitizedMcpUnavailableMessage(),
            ),
          ),
        ),
      );
    } finally {
      if (identical(_probeCancellation, cancellation)) {
        _probeCancellation = null;
      }
      cancellation.cancel();
    }
  }

  void cancelCheck() {
    _probeCancellation?.cancel();
    _probeCancellation = null;
    if (_state.probeStatus == McpProbeStatus.running) {
      _emit(_state.copyWith(probeStatus: McpProbeStatus.idle));
    }
  }

  /// Persists the open draft.
  ///
  /// Returns `false` and leaves the editor open with [McpConnectionsState
  /// .editorError] set for validation, conflict and persistence failures.
  ///
  /// Secret sequencing is fail-safe: values this save is about to overwrite
  /// are snapshotted first, and any failure after a vault write (stale
  /// revision, host save failure) restores the previous values or removes
  /// values written for a create that never landed. A value another writer
  /// changed after our write is left untouched, and rollback failures are
  /// reported without echoing any secret.
  Future<bool> saveDraft() async {
    final draft = _state.draft;
    if (draft == null || _state.saving || _disposed) {
      return false;
    }
    _emit(_state.copyWith(saving: true, clearEditorError: true));
    var previousSecrets = <McpSecretReference, String?>{};
    final writtenSecrets = <McpSecretReference, String>{};
    try {
      final capabilityError = _capabilityError(draft);
      if (capabilityError != null) {
        _setEditorError(capabilityError);
        return false;
      }
      final id = McpConnectionId(draft.effectiveConnectionId);
      final initial = await _repository.load(id);
      final initialConflict = _editConflict(draft, initial);
      if (initialConflict != null) {
        _setEditorError(initialConflict);
        return false;
      }
      final writes = _draftSecretWrites(id, draft);
      // Read the previous values before overwriting: when the vault cannot be
      // read, the save aborts before any value is touched.
      previousSecrets = await _snapshotSecrets(writes.keys);
      // Write new secret values before the configuration that references
      // them, so a failed save never leaves a dangling reference.
      await _writeDraftSecrets(writes, writtenSecrets);
      // Re-check immediately before the host captures the live revision:
      // with no await in between, a writer that landed during the vault write
      // is either already visible here (rejected) or fails the host's own
      // revision check instead of silently overwriting the change.
      final current = await _repository.load(id);
      final conflict = _editConflict(draft, current);
      if (conflict != null) {
        final note = await _rollbackWrittenSecrets(
          previousSecrets,
          writtenSecrets,
        );
        writtenSecrets.clear();
        _setEditorError(conflict + note);
        return false;
      }
      final config = _composeConfig(draft, revision: draft.baseRevision ?? 0);
      await _host.upsertConnection(config);
      // The new configuration is stored; never roll back from here.
      writtenSecrets.clear();
      final cleanupFailures = await _deleteRemovedSecrets(id, draft);
      if (_disposed) {
        return true;
      }
      _emit(
        _state.copyWith(
          saving: false,
          clearDraft: true,
          probeStatus: McpProbeStatus.idle,
          clearProbeResult: true,
          clearEditorError: true,
        ),
      );
      await refresh();
      if (cleanupFailures.isNotEmpty) {
        _showSecretCleanupFailure(id.value, cleanupFailures);
      }
      return true;
    } on McpException catch (error) {
      final note = await _rollbackWrittenSecrets(
        previousSecrets,
        writtenSecrets,
      );
      writtenSecrets.clear();
      _setEditorError(
        sanitizeMcpFailureForUi(
              error.error.message,
              secretValues: _draftSecretValues(draft),
              fallback: sanitizedMcpPersistenceMessage(),
            ) +
            note,
      );
      return false;
    } on Object {
      final note = await _rollbackWrittenSecrets(
        previousSecrets,
        writtenSecrets,
      );
      writtenSecrets.clear();
      _setEditorError(sanitizedMcpPersistenceMessage() + note);
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Lifecycle actions
  // ---------------------------------------------------------------------

  Future<void> setEnabled(String connectionId, bool enabled) async {
    final config = await _loadConfig(connectionId) ?? _configs[connectionId];
    if (config == null || _disposed) {
      return;
    }
    await _runBusy(connectionId, () async {
      await _host.upsertConnection(config.copyWith(enabled: enabled));
    });
    await refresh();
  }

  /// Removes a stored external connection and its vault entries.
  Future<bool> removeConnection(String connectionId) async {
    final config = await _loadConfig(connectionId) ?? _configs[connectionId];
    if (config == null || _disposed) {
      return false;
    }
    if (_isBuiltIn(config)) {
      _emit(
        _state.copyWith(
          error: 'Встроенный сервер нельзя удалить из этого раздела.',
        ),
      );
      return false;
    }
    var removed = false;
    await _runBusy(connectionId, () async {
      await _host.removeConnection(config.connectionId);
      removed = true;
    });
    if (!removed) {
      return false;
    }
    await refresh();
    final cleanupFailures = await _deleteSecrets(config.secretReferences);
    if (cleanupFailures.isNotEmpty) {
      // The connection is gone, but the user must not believe the sensitive
      // values were erased when the vault rejected the deletion.
      _showSecretCleanupFailure(connectionId, cleanupFailures);
    }
    return true;
  }

  /// Retries deleting secure values that a previous removal could not erase.
  ///
  /// Returns `true` when every pending reference is gone.
  Future<bool> retrySecretCleanup(String connectionId) async {
    final pending = _pendingSecretCleanup[connectionId];
    if (pending == null || pending.isEmpty || _disposed) {
      return false;
    }
    final failures = await _deleteSecrets(pending);
    if (failures.isEmpty) {
      _pendingSecretCleanup.remove(connectionId);
      final remaining = <String, int>{..._state.secretCleanupFailures}
        ..remove(connectionId);
      _emit(
        _state.copyWith(secretCleanupFailures: remaining, clearError: true),
      );
      return true;
    }
    _pendingSecretCleanup[connectionId] = List<McpSecretReference>.unmodifiable(
      failures,
    );
    _emit(
      _state.copyWith(
        secretCleanupFailures: <String, int>{
          ..._state.secretCleanupFailures,
          connectionId: failures.length,
        },
        error:
            'Не удалось удалить сохранённые секреты подключения '
            '«$connectionId» (${failures.length}). Повторите очистку позже.',
      ),
    );
    return false;
  }

  /// Tears the connection down and connects again (handshake plus catalog).
  Future<void> reconnect(String connectionId) async {
    if (await _loadConfig(connectionId) == null || _disposed) {
      return;
    }
    await _runBusy(
      connectionId,
      () => _host.restart(McpConnectionId(connectionId)),
    );
  }

  /// Refreshes one connection's tool catalog.
  Future<void> refreshTools(String connectionId) async {
    if (await _loadConfig(connectionId) == null || _disposed) {
      return;
    }
    await _runBusy(
      connectionId,
      () => _host.refreshCatalog(McpConnectionId(connectionId)),
    );
  }

  /// Explicit check of a stored connection: reconnect and re-list tools.
  Future<void> checkConnection(String connectionId) => reconnect(connectionId);

  void selectConnection(String? connectionId) {
    _emit(
      connectionId == null
          ? _state.copyWith(clearSelection: true)
          : _state.copyWith(selectedConnectionId: connectionId),
    );
  }

  void clearError() => _emit(_state.copyWith(clearError: true));

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  String? _capabilityError(McpConnectionDraft draft) {
    if (draft.transport == McpConnectionTransportChoice.stdio &&
        !_capabilities.supportsStdio) {
      return _capabilities.stdioUnavailableReason;
    }
    if (draft.transport == McpConnectionTransportChoice.streamableHttp &&
        !_capabilities.supportsRemoteHttp) {
      return _capabilities.remoteHttpUnavailableReason;
    }
    return null;
  }

  String? _editConflict(
    McpConnectionDraft draft,
    McpConnectionConfig? current,
  ) {
    if (draft.isEditing) {
      final baseRevision = draft.baseRevision;
      if (current == null) {
        return 'Подключение было удалено. Закройте редактор и обновите список.';
      }
      if (baseRevision == null || current.revision != baseRevision) {
        return 'Подключение изменено в другом месте. Закройте редактор и '
            'откройте его заново, чтобы не перезаписать свежие изменения.';
      }
      return null;
    }
    if (current != null) {
      return 'Подключение с таким ID уже существует. Выберите другой ID.';
    }
    return null;
  }

  McpConnectionConfig _composeConfig(
    McpConnectionDraft draft, {
    required int revision,
  }) {
    final id = McpConnectionId(draft.effectiveConnectionId);
    final transport = switch (draft.transport) {
      McpConnectionTransportChoice.stdio => McpStdioTransportConfig(
        command: draft.command,
        args: draft.args,
        workingDirectory: draft.workingDirectory.trim().isEmpty
            ? null
            : draft.workingDirectory,
        environment: draft.environment,
        secretEnvironment: _secretEnvironmentRefs(id, draft),
      ),
      McpConnectionTransportChoice.streamableHttp => McpHttpTransportConfig(
        url: draft.url,
        bearerSecret: _bearerReference(id, draft),
      ),
    };
    return McpConnectionConfig(
      connectionId: id,
      alias: draft.alias,
      transport: transport,
      enabled: draft.enabled,
      revision: revision,
    );
  }

  McpSecretReference? _bearerReference(
    McpConnectionId id,
    McpConnectionDraft draft,
  ) {
    if (draft.removeBearerToken) {
      return null;
    }
    if (draft.bearerToken.trim().isNotEmpty || draft.bearerTokenStored) {
      return McpSecretReference.bearer(id);
    }
    return null;
  }

  Map<String, McpSecretReference> _secretEnvironmentRefs(
    McpConnectionId id,
    McpConnectionDraft draft,
  ) {
    final refs = <String, McpSecretReference>{
      for (final name in draft.retainedSecretEnvironment)
        name: McpSecretReference.stdioEnvironment(id, name),
      for (final entry in draft.secretEnvironment.entries)
        if (entry.value.isNotEmpty)
          entry.key: McpSecretReference.stdioEnvironment(id, entry.key),
    };
    return refs;
  }

  McpSecretResolver _draftResolver(McpConnectionDraft draft) {
    final id = McpConnectionId(draft.effectiveConnectionId);
    final overrides = <McpSecretReference, String>{};
    final removed = <McpSecretReference>{};
    if (draft.removeBearerToken) {
      removed.add(McpSecretReference.bearer(id));
    } else if (draft.bearerToken.trim().isNotEmpty) {
      overrides[McpSecretReference.bearer(id)] = draft.bearerToken.trim();
    }
    for (final entry in draft.secretEnvironment.entries) {
      if (entry.value.isNotEmpty) {
        overrides[McpSecretReference.stdioEnvironment(id, entry.key)] =
            entry.value;
      }
    }
    for (final name in draft.removedSecretEnvironment) {
      removed.add(McpSecretReference.stdioEnvironment(id, name));
    }
    return McpDraftSecretResolver(
      base: _secrets,
      overrides: overrides,
      removed: removed,
    );
  }

  /// Exact draft secret values that must never appear in UI text or logs.
  Set<String> _draftSecretValues(McpConnectionDraft draft) {
    final values = <String>{};
    final bearer = draft.bearerToken.trim();
    if (bearer.isNotEmpty) {
      values.add(bearer);
    }
    for (final value in draft.secretEnvironment.values) {
      if (value.isNotEmpty) {
        values.add(value);
        final trimmed = value.trim();
        if (trimmed.isNotEmpty) {
          values.add(trimmed);
        }
      }
    }
    return values;
  }

  /// New secret values this save would store, keyed by vault reference.
  Map<McpSecretReference, String> _draftSecretWrites(
    McpConnectionId id,
    McpConnectionDraft draft,
  ) {
    final writes = <McpSecretReference, String>{};
    if (draft.transport == McpConnectionTransportChoice.streamableHttp &&
        !draft.removeBearerToken) {
      final value = draft.bearerToken.trim();
      if (value.isNotEmpty) {
        writes[McpSecretReference.bearer(id)] = value;
      }
    }
    if (draft.transport == McpConnectionTransportChoice.stdio) {
      for (final entry in draft.secretEnvironment.entries) {
        if (entry.value.isEmpty) {
          continue;
        }
        writes[McpSecretReference.stdioEnvironment(id, entry.key)] =
            entry.value;
      }
    }
    return writes;
  }

  Future<Map<McpSecretReference, String?>> _snapshotSecrets(
    Iterable<McpSecretReference> references,
  ) async {
    final snapshot = <McpSecretReference, String?>{};
    for (final reference in references) {
      snapshot[reference] = await _secrets.read(reference);
    }
    return snapshot;
  }

  /// Writes [writes], recording each completed value in [written] so a failure
  /// halfway through can still be rolled back.
  Future<void> _writeDraftSecrets(
    Map<McpSecretReference, String> writes,
    Map<McpSecretReference, String> written,
  ) async {
    for (final entry in writes.entries) {
      await _secrets.write(entry.key, entry.value);
      written[entry.key] = entry.value;
    }
  }

  /// Restores values overwritten by this save, or removes values written for a
  /// create that never landed.
  ///
  /// Returns a user-facing suffix when the vault rejected a restore. A value
  /// that no longer matches what this save wrote belongs to a newer writer and
  /// is never clobbered.
  Future<String> _rollbackWrittenSecrets(
    Map<McpSecretReference, String?> previous,
    Map<McpSecretReference, String> written,
  ) async {
    if (written.isEmpty) {
      return '';
    }
    var failures = 0;
    for (final entry in written.entries) {
      final reference = entry.key;
      final ourValue = entry.value;
      try {
        final current = await _secrets.read(reference);
        if (current != ourValue) {
          continue;
        }
        final oldValue = previous[reference];
        if (oldValue != null) {
          await _secrets.write(reference, oldValue);
        } else {
          await _secrets.delete(reference);
        }
      } on Object {
        failures += 1;
      }
    }
    if (failures == 0) {
      return '';
    }
    return ' Не удалось полностью восстановить прежние секреты; введите '
        'значение заново перед повторным сохранением.';
  }

  /// Deletes explicitly removed values and returns the references that could
  /// not be erased.
  Future<List<McpSecretReference>> _deleteRemovedSecrets(
    McpConnectionId id,
    McpConnectionDraft draft,
  ) {
    final references = <McpSecretReference>[
      if (draft.transport == McpConnectionTransportChoice.streamableHttp &&
          draft.removeBearerToken)
        McpSecretReference.bearer(id),
      if (draft.transport == McpConnectionTransportChoice.stdio)
        for (final name in draft.removedSecretEnvironment)
          McpSecretReference.stdioEnvironment(id, name),
    ];
    return _deleteSecrets(references);
  }

  Future<List<McpSecretReference>> _deleteSecrets(
    Iterable<McpSecretReference> references,
  ) async {
    final failures = <McpSecretReference>[];
    for (final reference in references) {
      try {
        await _secrets.delete(reference);
      } on Object {
        failures.add(reference);
      }
    }
    return failures;
  }

  /// Records a visible, retryable cleanup failure for [connectionId].
  void _showSecretCleanupFailure(
    String connectionId,
    List<McpSecretReference> failures,
  ) {
    _pendingSecretCleanup[connectionId] = List<McpSecretReference>.unmodifiable(
      failures,
    );
    _emit(
      _state.copyWith(
        secretCleanupFailures: <String, int>{
          ..._state.secretCleanupFailures,
          connectionId: failures.length,
        },
        error:
            'Не удалось удалить сохранённые секреты подключения '
            '«$connectionId» (${failures.length}). Повторите очистку.',
      ),
    );
  }

  Future<void> _runBusy(
    String connectionId,
    Future<void> Function() action,
  ) async {
    if (_state.busyConnectionIds.contains(connectionId)) {
      return;
    }
    _emit(
      _state.copyWith(
        busyConnectionIds: <String>{..._state.busyConnectionIds, connectionId},
      ),
    );
    try {
      await action();
    } on McpException catch (error) {
      _emit(
        _state.copyWith(
          error: sanitizeMcpText(
            error.error.message,
            fallback: sanitizedMcpUnavailableMessage(),
          ),
        ),
      );
    } on Object {
      _emit(_state.copyWith(error: sanitizedMcpUnavailableMessage()));
    } finally {
      if (!_disposed) {
        _emit(
          _state.copyWith(
            busyConnectionIds: <String>{..._state.busyConnectionIds}
              ..remove(connectionId),
          ),
        );
      }
    }
  }

  void _setEditorError(String message) {
    if (_disposed) {
      return;
    }
    _emit(_state.copyWith(saving: false, editorError: message));
  }

  bool _isBuiltIn(McpConnectionConfig config) =>
      config.transport is McpInProcessStreamTransportConfig ||
      _builtInConnectionIds.contains(config.connectionId.value);

  /// Authoritative configuration read used by editor/lifecycle actions.
  Future<McpConnectionConfig?> _loadConfig(String connectionId) async {
    try {
      return await _repository.load(McpConnectionId(connectionId));
    } on McpException {
      return _configs[connectionId];
    }
  }

  void _applyConfigs(List<McpConnectionConfig> configs) {
    _configs
      ..clear()
      ..addEntries(
        configs.map((config) => MapEntry(config.connectionId.value, config)),
      );
  }

  /// Reloads persisted configuration after a host change without flipping the
  /// page back to its loading state.
  Future<void> _reloadConfigs() async {
    try {
      final configs = await _repository.loadAll();
      if (_disposed) {
        return;
      }
      _applyConfigs(configs);
      _publishFromHost();
    } on Object {
      // refresh() reports persistence failures; keep the last known list.
    }
  }

  void _scheduleConfigReload() {
    if (_configReloadScheduled || _disposed) {
      return;
    }
    _configReloadScheduled = true;
    unawaited(
      _reloadConfigs().whenComplete(() {
        _configReloadScheduled = false;
      }),
    );
  }

  void _syncFromHost() {
    if (_disposed || !_initialized) {
      return;
    }
    _publishFromHost();
    _scheduleConfigReload();
  }

  void _publishFromHost({
    McpConnectionsStatus? status,
    bool clearConfigurationError = false,
    bool clearError = false,
  }) {
    final snapshot = _host.snapshot;
    final routesByConnection = <String, List<McpToolRoute>>{};
    for (final route in snapshot.catalog.routes) {
      routesByConnection
          .putIfAbsent(route.connectionId.value, () => <McpToolRoute>[])
          .add(route);
    }
    final statuses = <String, McpConnectionStatus>{
      for (final connectionStatus in snapshot.connections)
        connectionStatus.id.value: connectionStatus,
    };
    final entries = <McpConnectionEntry>[];
    for (final config in _configs.values) {
      entries.add(
        McpConnectionEntry(
          config: config,
          status: statuses[config.connectionId.value],
          routes: List<McpToolRoute>.unmodifiable(
            routesByConnection[config.connectionId.value] ??
                const <McpToolRoute>[],
          ),
          isBuiltIn: _isBuiltIn(config),
        ),
      );
    }
    entries.sort((a, b) => a.id.compareTo(b.id));
    _emit(
      _state.copyWith(
        status: status ?? _state.status,
        connections: List<McpConnectionEntry>.unmodifiable(entries),
        configurationError: snapshot.configurationError,
        clearConfigurationError:
            clearConfigurationError && snapshot.configurationError == null,
        clearError: clearError,
      ),
    );
  }

  void _emit(McpConnectionsState next) {
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
    _probeCancellation?.cancel();
    _probeCancellation = null;
    unawaited(_hostEvents?.cancel());
    _hostEvents = null;
    _hostChanges?.removeListener(_syncFromHost);
    super.dispose();
  }
}

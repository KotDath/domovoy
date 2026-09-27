import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/llm/cancellation.dart';
import '../../../core/llm/json.dart';
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
/// Editing a secret is append-only with respect to the vault: every newly
/// submitted value is written under a fresh, unique [McpSecretReference], the
/// stored configuration continues to reference its previous value until the
/// commit succeeds, and only then are superseded references cleaned up. A
/// failed or uncertain commit therefore never leaves the saved configuration
/// pointing at a different secret.
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
    String Function()? secretRefIds,
  }) : _host = host,
       _repository = repository,
       _secrets = secrets,
       _capabilities = capabilities,
       _probe = probe,
       _hostChanges = hostChanges,
       _builtInConnectionIds = Set<String>.unmodifiable(builtInConnectionIds),
       _secretRefIds = secretRefIds ?? _defaultSecretRefId;

  final McpHost _host;
  final McpConnectionRepository _repository;
  final McpSecretVault _secrets;
  final McpPlatformCapabilities _capabilities;
  final McpConnectionProbe _probe;
  final Listenable? _hostChanges;
  final Set<String> _builtInConnectionIds;

  /// Unique suffix factory for versioned secret references (test seam).
  final String Function() _secretRefIds;

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
  /// read authoritatively from the repository so an edit always starts from
  /// the latest revision; a failed read is surfaced instead of falling back to
  /// a cached snapshot.
  Future<bool> beginEdit(String connectionId) async {
    final McpConnectionConfig? config;
    try {
      config = await _readConfig(connectionId);
    } on McpException catch (error) {
      _emit(_state.copyWith(editorError: _readFailureMessage(error)));
      return false;
    }
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
      final id = McpConnectionId(draft.effectiveConnectionId);
      // An edit must resolve preserved references from the authoritative
      // stored configuration; a failed read is surfaced instead of probing
      // with guessed references.
      McpConnectionConfig? existing;
      if (draft.isEditing) {
        try {
          existing = await _readConfig(id.value);
        } on McpException catch (error) {
          if (!identical(_probeCancellation, cancellation) || _disposed) {
            return;
          }
          _emit(
            _state.copyWith(
              probeStatus: McpProbeStatus.failure,
              probeResult: McpProbeResult.failure(
                errorKind: error.error.kind,
                error: _readFailureMessage(error),
              ),
            ),
          );
          return;
        }
      }
      final plan = _planSecrets(id, draft, existing);
      final config = _composeConfigFromPlan(
        draft,
        plan,
        revision: draft.baseRevision ?? 0,
      );
      // Submitted values plus every value the resolver actually reads are the
      // redaction set for any server/transport error text.
      final redactions = <String>{...plan.stagedWrites.values};
      final result = await _probe.run(
        config,
        secrets: McpRecordingSecretResolver(
          inner: McpDraftSecretResolver(
            base: _secrets,
            overrides: plan.stagedWrites,
          ),
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
              secretValues: _submittedSecretValues(draft),
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
  /// Secret replacement is append-only: newly submitted values are written
  /// under fresh [McpSecretReference]s before the commit, the new
  /// configuration references them, and the previous references (and values)
  /// stay untouched until the commit is known to have landed. On rejection or
  /// an uncertain commit the staged references become visible, retryable
  /// cleanup, and the saved configuration keeps using its previous values.
  /// When a commit may have landed despite a thrown error, the persisted
  /// configuration is read back and treated as committed truth.
  Future<bool> saveDraft() async {
    final draft = _state.draft;
    if (draft == null || _state.saving || _disposed) {
      return false;
    }
    _emit(_state.copyWith(saving: true, clearEditorError: true));
    final staged = <McpSecretReference>{};
    var committed = false;
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
      final plan = _planSecrets(id, draft, initial);
      if (!await _stageSecrets(plan.stagedWrites, staged)) {
        final failures = await _deleteSecrets(staged);
        _setEditorError(sanitizedMcpPersistenceMessage());
        if (failures.isNotEmpty) {
          _showSecretCleanupFailure(id.value, failures);
        }
        return false;
      }
      // Re-check immediately before the host captures the live revision:
      // with no await in between, a writer that landed during the vault write
      // is either already visible here (rejected) or fails the host's own
      // revision check instead of silently overwriting the change.
      final current = await _repository.load(id);
      final conflict = _editConflict(draft, current);
      if (conflict != null) {
        final failures = await _deleteSecrets(staged);
        _setEditorError(conflict);
        if (failures.isNotEmpty) {
          _showSecretCleanupFailure(id.value, failures);
        }
        return false;
      }
      final config = _composeConfigFromPlan(
        draft,
        plan,
        revision: draft.baseRevision ?? 0,
      );
      McpConnectionConfig? persisted;
      try {
        await _host.upsertConnection(config);
        committed = true;
      } on Object catch (error) {
        // A config write may commit and then throw: read back the persisted
        // revision/configuration before deciding which references are active.
        var readFailed = false;
        try {
          persisted = await _repository.load(id);
        } on Object {
          readFailed = true;
        }
        committed =
            !readFailed &&
            persisted != null &&
            _matchesConfig(persisted, config);
        if (!committed) {
          if (readFailed) {
            // The read-back failed: the outcome is unknown, so staged
            // references are kept (never delete a possibly active secret).
            _setEditorError(
              '${_commitFailureMessage(draft, error)} '
              'Не удалось подтвердить результат сохранения: обновите список '
              'и проверьте подключение.',
            );
            return false;
          }
          final activeReferences =
              persisted?.secretReferences.toSet() ??
              const <McpSecretReference>{};
          final orphans = staged
              .where((reference) => !activeReferences.contains(reference))
              .toList(growable: false);
          final failures = await _deleteSecrets(orphans);
          _setEditorError(_commitFailureMessage(draft, error));
          if (failures.isNotEmpty) {
            _showSecretCleanupFailure(id.value, failures);
          }
          return false;
        }
      }
      // Committed (possibly despite a thrown error): only references that the
      // persisted configuration no longer uses are superseded.
      persisted ??= await _safeLoadConfig(id.value);
      final activeReferences =
          persisted?.secretReferences.toSet() ??
          config.secretReferences.toSet();
      final superseded = plan.previousReferences.difference(activeReferences);
      final cleanupFailures = await _deleteSecrets(superseded);
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
      if (!committed) {
        final failures = await _deleteSecrets(staged);
        if (failures.isNotEmpty) {
          _showSecretCleanupFailure(draft.effectiveConnectionId, failures);
        }
      }
      _setEditorError(
        sanitizeMcpFailureForUi(
          error.error.message,
          secretValues: _submittedSecretValues(draft),
          fallback: sanitizedMcpPersistenceMessage(),
        ),
      );
      return false;
    } on Object {
      if (!committed) {
        final failures = await _deleteSecrets(staged);
        if (failures.isNotEmpty) {
          _showSecretCleanupFailure(draft.effectiveConnectionId, failures);
        }
      }
      _setEditorError(sanitizedMcpPersistenceMessage());
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Lifecycle actions
  // ---------------------------------------------------------------------

  /// Enables or disables a stored connection without clobbering other fields.
  ///
  /// The configuration is re-read immediately before the host captures the
  /// live revision, so an edit that landed while an earlier read was in flight
  /// is preserved instead of being overwritten by a stale full-config write.
  /// A failed authoritative read is surfaced and no write is attempted.
  Future<void> setEnabled(String connectionId, bool enabled) async {
    final id = McpConnectionId(connectionId);
    final ok = await _runBusy(connectionId, () async {
      final latest = await _repository.load(id);
      if (latest == null) {
        throwMcp(
          McpErrorKind.configuration,
          'Подключение не найдено. Обновите список.',
        );
      }
      // Second, fresh read: the first one may be a stale snapshot taken while
      // another writer committed an endpoint/alias edit.
      final confirmed = await _repository.load(id) ?? latest;
      await _host.upsertConnection(confirmed.copyWith(enabled: enabled));
    });
    if (ok) {
      await refresh();
    }
  }

  /// Removes a stored external connection and its vault entries.
  Future<bool> removeConnection(String connectionId) async {
    final McpConnectionConfig? config;
    try {
      config = await _readConfig(connectionId);
    } on McpException catch (error) {
      _emit(_state.copyWith(error: _readFailureMessage(error)));
      return false;
    }
    if (config == null || _disposed) {
      return false;
    }
    final resolved = config;
    if (_isBuiltIn(resolved)) {
      _emit(
        _state.copyWith(
          error: 'Встроенный сервер нельзя удалить из этого раздела.',
        ),
      );
      return false;
    }
    var removed = false;
    await _runBusy(connectionId, () async {
      await _host.removeConnection(resolved.connectionId);
      removed = true;
    });
    if (!removed) {
      return false;
    }
    await refresh();
    final cleanupFailures = await _deleteSecrets(resolved.secretReferences);
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
            'Устаревшие секреты подключения «$connectionId» не удалены '
            '(${failures.length}). Повторите очистку позже.',
      ),
    );
    return false;
  }

  /// Tears the connection down and connects again (handshake plus catalog).
  Future<void> reconnect(String connectionId) async {
    if (!await _connectionExists(connectionId) || _disposed) {
      return;
    }
    await _runBusy(
      connectionId,
      () => _host.restart(McpConnectionId(connectionId)),
    );
  }

  /// Refreshes one connection's tool catalog.
  Future<void> refreshTools(String connectionId) async {
    if (!await _connectionExists(connectionId) || _disposed) {
      return;
    }
    await _runBusy(
      connectionId,
      () => _host.refreshCatalog(McpConnectionId(connectionId)),
    );
  }

  /// Authoritative existence check that surfaces read failures instead of
  /// trusting the in-memory cache.
  Future<bool> _connectionExists(String connectionId) async {
    try {
      return await _readConfig(connectionId) != null;
    } on McpException catch (error) {
      _emit(_state.copyWith(error: _readFailureMessage(error)));
      return false;
    }
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

  /// Plans the vault references the composed configuration will use and the
  /// fresh writes that must be staged before commit.
  ///
  /// Values the user did not replace keep their existing reference (including
  /// legacy fixed-key references); only newly submitted values receive a fresh
  /// immutable reference. Explicitly removed values simply disappear from the
  /// plan and their references become superseded after a successful commit.
  _SecretPlan _planSecrets(
    McpConnectionId id,
    McpConnectionDraft draft,
    McpConnectionConfig? existing,
  ) {
    final stagedWrites = <McpSecretReference, String>{};
    final previousReferences = existing == null
        ? const <McpSecretReference>{}
        : existing.secretReferences.toSet();
    final secretEnvironment = <String, McpSecretReference>{};
    McpSecretReference? bearerReference;
    switch (draft.transport) {
      case McpConnectionTransportChoice.streamableHttp:
        final storedRef = switch (existing?.transport) {
          McpHttpTransportConfig(:final bearerSecret) => bearerSecret,
          _ => null,
        };
        if (!draft.removeBearerToken) {
          final value = draft.bearerToken.trim();
          if (value.isNotEmpty) {
            final reference = _newSecretReference(id, 'bearer');
            stagedWrites[reference] = value;
            bearerReference = reference;
          } else if (storedRef != null) {
            bearerReference = storedRef;
          } else if (draft.bearerTokenStored) {
            bearerReference = McpSecretReference.bearer(id);
          }
        }
      case McpConnectionTransportChoice.stdio:
        final storedRefs = switch (existing?.transport) {
          McpStdioTransportConfig(:final secretEnvironment) =>
            secretEnvironment,
          _ => const <String, McpSecretReference>{},
        };
        for (final name in draft.retainedSecretEnvironment) {
          secretEnvironment[name] =
              storedRefs[name] ?? McpSecretReference.stdioEnvironment(id, name);
        }
        for (final entry in draft.secretEnvironment.entries) {
          if (entry.value.isEmpty) {
            continue;
          }
          final reference = _newSecretReference(id, 'env.${entry.key}');
          stagedWrites[reference] = entry.value;
          secretEnvironment[entry.key] = reference;
        }
    }
    return _SecretPlan(
      bearerReference: bearerReference,
      secretEnvironment: secretEnvironment,
      stagedWrites: stagedWrites,
      previousReferences: previousReferences,
    );
  }

  /// Fresh, immutable reference for one newly submitted value.
  McpSecretReference _newSecretReference(McpConnectionId id, String label) =>
      McpSecretReference('mcp.${id.value}.$label.${_secretRefIds()}');

  McpConnectionConfig _composeConfigFromPlan(
    McpConnectionDraft draft,
    _SecretPlan plan, {
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
        secretEnvironment: plan.secretEnvironment,
      ),
      McpConnectionTransportChoice.streamableHttp => McpHttpTransportConfig(
        url: draft.url,
        bearerSecret: plan.bearerReference,
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

  /// Stages freshly submitted values, tolerating a vault that commits and then
  /// throws: the value is read back before a write is declared failed.
  Future<bool> _stageSecrets(
    Map<McpSecretReference, String> writes,
    Set<McpSecretReference> staged,
  ) async {
    for (final entry in writes.entries) {
      try {
        await _secrets.write(entry.key, entry.value);
        staged.add(entry.key);
        continue;
      } on Object {
        var committed = false;
        try {
          committed = await _secrets.read(entry.key) == entry.value;
        } on Object {
          committed = false;
        }
        if (!committed) {
          return false;
        }
        staged.add(entry.key);
      }
    }
    return true;
  }

  /// Submitted values that must never appear in UI text or logs.
  Set<String> _submittedSecretValues(McpConnectionDraft draft) {
    final values = <String>{};
    final bearer = draft.bearerToken.trim();
    if (bearer.isNotEmpty) {
      values.add(bearer);
    }
    for (final value in draft.secretEnvironment.values) {
      if (value.isEmpty) {
        continue;
      }
      values.add(value);
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        values.add(trimmed);
      }
    }
    return values;
  }

  /// Authoritative configuration read used by mutations.
  ///
  /// Throws when storage cannot be read, so callers never treat a cached
  /// in-memory snapshot as a current revision for a write.
  Future<McpConnectionConfig?> _readConfig(String connectionId) =>
      _repository.load(McpConnectionId(connectionId));

  /// Post-commit read-back; `null` also means "unreadable".
  Future<McpConnectionConfig?> _safeLoadConfig(String connectionId) async {
    try {
      return await _repository.load(McpConnectionId(connectionId));
    } on Object {
      return null;
    }
  }

  /// True when the persisted record carries exactly the configuration this
  /// save attempted, so a commit that threw is still recognized as committed.
  bool _matchesConfig(
    McpConnectionConfig persisted,
    McpConnectionConfig expected,
  ) {
    return persisted.connectionId == expected.connectionId &&
        persisted.alias == expected.alias &&
        persisted.enabled == expected.enabled &&
        jsonEquals(persisted.transport.toJson(), expected.transport.toJson());
  }

  String _commitFailureMessage(McpConnectionDraft draft, Object error) {
    if (error is McpException) {
      return sanitizeMcpFailureForUi(
        error.error.message,
        secretValues: _submittedSecretValues(draft),
        fallback: sanitizedMcpPersistenceMessage(),
      );
    }
    return sanitizedMcpPersistenceMessage();
  }

  String _readFailureMessage(McpException error) => sanitizeMcpFailureForUi(
    error.error.message,
    secretValues: const <String>[],
    fallback: sanitizedMcpPersistenceMessage(),
  );

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
  ///
  /// Failures merge with references already pending so a later retry cannot
  /// forget an earlier leftover.
  void _showSecretCleanupFailure(
    String connectionId,
    List<McpSecretReference> failures,
  ) {
    final pending = <McpSecretReference>{
      ...?_pendingSecretCleanup[connectionId],
      ...failures,
    };
    _pendingSecretCleanup[connectionId] = List<McpSecretReference>.unmodifiable(
      pending,
    );
    _emit(
      _state.copyWith(
        secretCleanupFailures: <String, int>{
          ..._state.secretCleanupFailures,
          connectionId: pending.length,
        },
        error:
            'Устаревшие секреты подключения «$connectionId» не удалены '
            '(${pending.length}). Повторите очистку.',
      ),
    );
  }

  /// Runs [action] with a per-connection busy marker.
  ///
  /// Returns `true` only when the action completed; callers must not refresh
  /// (which clears the error banner) after a failed action.
  Future<bool> _runBusy(
    String connectionId,
    Future<void> Function() action,
  ) async {
    if (_state.busyConnectionIds.contains(connectionId)) {
      return false;
    }
    _emit(
      _state.copyWith(
        busyConnectionIds: <String>{..._state.busyConnectionIds, connectionId},
      ),
    );
    var ok = false;
    try {
      await action();
      ok = true;
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
    return ok;
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

/// Immutable plan for one save: the references the composed configuration will
/// use, fresh staged writes, and the references the previous configuration had.
final class _SecretPlan {
  const _SecretPlan({
    required this.bearerReference,
    required this.secretEnvironment,
    required this.stagedWrites,
    required this.previousReferences,
  });

  final McpSecretReference? bearerReference;
  final Map<String, McpSecretReference> secretEnvironment;
  final Map<McpSecretReference, String> stagedWrites;
  final Set<McpSecretReference> previousReferences;
}

var _secretRefSequence = 0;

/// Unique suffix for a versioned secret reference.
String _defaultSecretRefId() {
  _secretRefSequence += 1;
  final random = Random.secure();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '-${random.nextInt(1 << 32).toRadixString(36)}'
      '-$_secretRefSequence';
}

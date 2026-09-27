import '../../../core/llm/cancellation.dart';
import '../../../core/mcp/mcp.dart';

/// Read/write repository decorator that keeps Domovoy-owned built-in MCP
/// connections out of the user JSONL configuration.
///
/// Built-in servers bind to a fresh loopback port and a short-lived bearer
/// token on every start, so their configuration is process state, not user
/// data: persisting it would leak an expired endpoint and a dead secret
/// reference into the next run. They are registered here in memory, presented
/// to the host and UI like any other connection, and can never be overwritten
/// or deleted through [save]/[delete] (the user store is bypassed).
///
/// A shadow record stored by an older build is ignored on load: the composed
/// configuration is authoritative for app-owned ids.
final class AppOwnedMcpConnectionRepository implements McpConnectionRepository {
  AppOwnedMcpConnectionRepository({
    required McpConnectionRepository userStore,
    required Set<String> appOwnedConnectionIds,
  }) : _userStore = userStore,
       _appOwnedIds = Set<String>.unmodifiable(appOwnedConnectionIds);

  final McpConnectionRepository _userStore;
  final Set<String> _appOwnedIds;
  final Map<String, McpConnectionConfig> _appOwned =
      <String, McpConnectionConfig>{};

  Set<String> get appOwnedConnectionIds => _appOwnedIds;

  /// Registers (or replaces) the in-memory configuration of a built-in server.
  void register(McpConnectionConfig config) {
    final id = config.connectionId.value;
    if (!_appOwnedIds.contains(id)) {
      throwMcp(
        McpErrorKind.configuration,
        'Connection "$id" is not an app-owned built-in connection.',
      );
    }
    _appOwned[id] = config;
  }

  /// Removes the in-memory registration of one built-in server.
  void unregister(McpConnectionId id) {
    _appOwned.remove(id.value);
  }

  bool isAppOwned(McpConnectionId id) => _appOwnedIds.contains(id.value);

  @override
  Future<McpConnectionConfig?> load(McpConnectionId id) async =>
      _appOwned[id.value] ?? _userStore.load(id);

  @override
  Future<List<McpConnectionConfig>> loadAll() async {
    final stored = (await _userStore.loadAll())
        .where((config) => !_appOwnedIds.contains(config.connectionId.value))
        .toList(growable: true);
    stored.addAll(_appOwned.values);
    stored.sort((a, b) => a.connectionId.value.compareTo(b.connectionId.value));
    return List<McpConnectionConfig>.unmodifiable(stored);
  }

  @override
  Future<Map<String, int>> loadTombstones() => _userStore.loadTombstones();

  @override
  Future<void> save(
    McpConnectionConfig config, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (_appOwnedIds.contains(config.connectionId.value)) {
      throwMcp(
        McpErrorKind.configuration,
        'Built-in MCP connection "${config.connectionId.value}" is composed '
        'by the application and cannot be redefined or disabled.',
      );
    }
    return _userStore.save(
      config,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> delete(
    McpConnectionId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    if (_appOwnedIds.contains(id.value)) {
      throwMcp(
        McpErrorKind.configuration,
        'Built-in MCP connection "${id.value}" is composed by the '
        'application and cannot be removed.',
      );
    }
    return _userStore.delete(
      id,
      expectedRevision: expectedRevision,
      cancellation: cancellation,
    );
  }
}

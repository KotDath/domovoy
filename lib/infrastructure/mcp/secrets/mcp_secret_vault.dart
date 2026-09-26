import '../../../core/mcp/mcp.dart';
import '../../credentials/secure_string_store.dart';

/// Secure-storage backed vault for MCP secrets.
///
/// Only references ([McpSecretReference]) travel through JSONL configuration;
/// values live in `flutter_secure_storage`.
final class FlutterSecureMcpSecretVault implements McpSecretVault {
  FlutterSecureMcpSecretVault(this._store);

  final SecureStringStore _store;

  @override
  Future<String?> read(McpSecretReference reference) =>
      _store.read(reference.storeKey);

  @override
  Future<void> write(McpSecretReference reference, String value) {
    if (value.isEmpty) {
      throwMcp(
        McpErrorKind.configuration,
        'MCP secret value must not be blank.',
      );
    }
    return _store.write(reference.storeKey, value);
  }

  @override
  Future<void> delete(McpSecretReference reference) =>
      _store.delete(reference.storeKey);
}

/// In-memory resolver for short-lived secrets, such as the loopback bearer
/// token of a built-in server that never reaches persistent storage.
///
/// Values are never serialized; [remove] must be called when the server stops.
final class RuntimeMcpSecretResolver implements McpSecretResolver {
  RuntimeMcpSecretResolver({McpSecretResolver? fallback})
    : _fallback = fallback;

  final Map<String, String> _values = <String, String>{};
  final McpSecretResolver? _fallback;

  void put(McpSecretReference reference, String value) {
    _values[reference.storeKey] = value;
  }

  void remove(McpSecretReference reference) {
    _values.remove(reference.storeKey);
  }

  bool contains(McpSecretReference reference) =>
      _values.containsKey(reference.storeKey);

  @override
  Future<String?> read(McpSecretReference reference) async {
    final value = _values[reference.storeKey];
    if (value != null) {
      return value;
    }
    return _fallback?.read(reference);
  }
}

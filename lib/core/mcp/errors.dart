import '../llm/json.dart';

/// Categories of MCP host failures.
///
/// The kind is stable across UI, traces and tests; the message is sanitized
/// before it leaves the infrastructure adapter.
enum McpErrorKind {
  /// The connection configuration is unusable.
  configuration,

  /// The requested transport or feature is not available on this platform.
  unsupported,

  /// Starting or talking to the transport failed (process, socket, HTTP).
  transport,

  /// The MCP handshake failed or negotiated nothing usable.
  handshake,

  /// The peer sent an invalid MCP/JSON-RPC payload.
  protocol,

  /// The response shape is understood by the protocol but not by this host.
  invalidResponse,

  /// The operation exceeded its deadline.
  timeout,

  /// The caller cancelled the operation.
  cancelled,

  /// The server or connection is not currently connected.
  unavailable,

  /// The model tool name has no route in the current catalog.
  toolNotFound,

  /// Two different server tools map to the same model-facing name.
  nameCollision,

  /// A permission policy rejected the call.
  toolDenied,

  /// The server reported a tool-domain failure (`isError`).
  toolFailure,

  /// Refreshing or atomically replacing the catalog failed.
  refresh,

  /// Reading or writing MCP JSONL configuration failed.
  persistence,
}

final class McpError implements Exception {
  McpError({required this.kind, required String message})
    : message = message.trim() {
    if (this.message.isEmpty) {
      throw ArgumentError.value(
        message,
        'message',
        'Error message must not be blank.',
      );
    }
  }

  factory McpError.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final kindName = requireNonBlankString(map, 'kind');
    final kind = McpErrorKind.values
        .where((value) => value.name == kindName)
        .firstOrNull;
    if (kind == null) {
      throwMcp(McpErrorKind.protocol, 'Unknown MCP error kind "$kindName".');
    }
    return McpError(kind: kind, message: requireNonBlankString(map, 'message'));
  }

  static const jsonType = 'mcp.error';

  final McpErrorKind kind;
  final String message;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{'kind': kind.name, 'message': message},
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpError && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'McpError($kind: $message)';
}

final class McpException implements Exception {
  McpException(this.error);

  final McpError error;

  @override
  String toString() => error.toString();
}

Never throwMcp(McpErrorKind kind, String message) {
  throw McpException(McpError(kind: kind, message: message));
}

/// Replaces a raw failure message with a safe, user-facing explanation.
///
/// MCP servers are untrusted peers: their stdout, stderr and error payloads
/// may contain tokens, prompts or stack traces. Only sanitized messages reach
/// the host snapshot, traces and UI.
String sanitizeMcpText(String? raw, {required String fallback}) {
  if (raw == null) {
    return fallback;
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return fallback;
  }
  if (_secretPattern.hasMatch(trimmed) ||
      trimmed.contains('\n') ||
      trimmed.contains('StateError') ||
      trimmed.contains('Exception') ||
      trimmed.contains('#0 ') ||
      trimmed.contains('.dart:')) {
    return fallback;
  }
  return trimmed;
}

final _secretPattern = RegExp(
  r'(sk-[A-Za-z0-9]+)|api[_-]?key|bearer\s+\S+|-----BEGIN',
  caseSensitive: false,
);

String sanitizedMcpUnavailableMessage() =>
    'MCP-сервер сейчас недоступен. Подключение не установлено.';

String sanitizedMcpToolMissingMessage() =>
    'Инструмент больше не доступен: каталог сервера изменился.';

String sanitizedMcpToolFailureMessage() =>
    'Инструмент MCP завершился с ошибкой.';

String sanitizedMcpPersistenceMessage() =>
    'Не удалось прочитать или сохранить настройки MCP.';

String sanitizedMcpRefreshMessage() =>
    'Не удалось обновить каталог инструментов MCP.';

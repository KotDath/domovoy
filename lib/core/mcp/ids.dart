import 'errors.dart';

/// Stable identity of one configured MCP server connection.
final class McpConnectionId {
  McpConnectionId(String value) : value = _validate(value);

  factory McpConnectionId.fromJson(Object? json) {
    if (json is! String) {
      throwMcp(McpErrorKind.configuration, 'Connection ID must be text.');
    }
    return McpConnectionId(json);
  }

  static const maxLength = 64;

  static final RegExp _pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  final String value;

  Map<String, Object?> toJson() => <String, Object?>{'connectionId': value};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpConnectionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

String _validate(String value) {
  final candidate = value.trim();
  if (candidate.isEmpty || candidate.length > McpConnectionId.maxLength) {
    throwMcp(
      McpErrorKind.configuration,
      'Connection ID must be 1-${McpConnectionId.maxLength} characters.',
    );
  }
  if (!McpConnectionId._pattern.hasMatch(candidate)) {
    throwMcp(
      McpErrorKind.configuration,
      'Connection ID contains unsupported characters.',
    );
  }
  return candidate;
}

/// Model-facing tool name that satisfies LLM provider constraints.
///
/// OpenAI-compatible providers accept `^[a-zA-Z0-9_-]{1,64}$`; DeepSeek and
/// OpenRouter follow the same shape. The name is derived from the connection
/// ID and the original tool name, never from a display alias, so renaming an
/// alias cannot change what the model sees.
final class McpModelToolName {
  McpModelToolName(String value) : value = _validateModelName(value);

  factory McpModelToolName.fromJson(Object? json) {
    if (json is! String) {
      throwMcp(McpErrorKind.configuration, 'Model tool name must be text.');
    }
    return McpModelToolName(json);
  }

  static const maxLength = 64;

  static final RegExp _pattern = RegExp(r'^[a-zA-Z0-9_-]+$');

  final String value;

  Map<String, Object?> toJson() => <String, Object?>{'name': value};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpModelToolName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

String _validateModelName(String value) {
  final candidate = value.trim();
  if (candidate.isEmpty ||
      candidate.length > McpModelToolName.maxLength ||
      !McpModelToolName._pattern.hasMatch(candidate)) {
    throwMcp(
      McpErrorKind.configuration,
      'Model tool name must match '
      '^[a-zA-Z0-9_-]{1,${McpModelToolName.maxLength}}\$.',
    );
  }
  return candidate;
}

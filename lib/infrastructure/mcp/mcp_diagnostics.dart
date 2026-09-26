import '../../core/mcp/mcp.dart';

/// Destination for human-readable MCP diagnostics.
///
/// Diagnostics only ever receive redacted text; raw server stderr and protocol
/// payloads must pass through [McpSecretRedactor] first.
abstract interface class McpDiagnosticsSink {
  void log(String message);
}

/// In-memory sink used by tests and by the debug UI.
final class MemoryMcpDiagnosticsSink implements McpDiagnosticsSink {
  final List<String> lines = <String>[];

  @override
  void log(String message) {
    lines.add(message);
  }
}

/// A sink that discards diagnostics; the default when none is configured.
final class NoopMcpDiagnosticsSink implements McpDiagnosticsSink {
  const NoopMcpDiagnosticsSink();

  @override
  void log(String message) {}
}

/// Replaces known secret values inside arbitrary text.
///
/// Values shorter than four characters are ignored: replacing them would
/// corrupt ordinary text without providing meaningful protection.
final class McpSecretRedactor {
  McpSecretRedactor(Iterable<String> secrets)
    : _secrets = List<String>.unmodifiable(
        secrets.where((secret) => secret.length >= 4),
      );

  const McpSecretRedactor.empty() : _secrets = const <String>[];

  final List<String> _secrets;

  bool get isEmpty => _secrets.isEmpty;

  String redact(String text) {
    var result = text;
    for (final secret in _secrets) {
      if (result.contains(secret)) {
        result = result.replaceAll(secret, '[redacted]');
      }
    }
    return result;
  }
}

/// Formats one host event for diagnostics with the given redactor applied.
String describeMcpHostEvent(McpHostEvent event, McpSecretRedactor redactor) {
  return redactor.redact(switch (event) {
    McpConnectionPhaseChanged(
      :final connectionId,
      :final phase,
      :final error,
    ) =>
      'mcp connection ${connectionId.value} -> ${phase.name}'
          '${error == null ? '' : ': $error'}',
    McpCatalogChanged(:final revision, :final toolCount) =>
      'mcp catalog revision $revision with $toolCount tools',
    McpToolCallCompleted(
      :final modelToolName,
      :final connectionId,
      :final originalToolName,
      :final isError,
      :final duration,
    ) =>
      'mcp call $modelToolName -> ${connectionId.value}/$originalToolName '
          '${isError ? 'failed' : 'ok'} in ${duration.inMilliseconds}ms',
  });
}

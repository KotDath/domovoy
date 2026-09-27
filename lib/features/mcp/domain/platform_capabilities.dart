/// Platform capability facts for the MCP connections UI.
///
/// The composition (B9) injects this instead of the feature inferring
/// capabilities from Dart platform facts alone: Aurora can report itself as
/// Linux while third-party stdio servers are intentionally disabled for this
/// release, and web has neither stdio nor a built-in HTTP server.
library;

const mcpStdioUnavailableReason =
    'Локальные stdio-серверы недоступны на этом устройстве: '
    'запуск внешних процессов не поддерживается.';

const mcpStdioDisabledByPolicyReason =
    'Локальные stdio-серверы отключены политикой этой сборки.';

const mcpRemoteHttpUnavailableReason =
    'Сторонние Streamable HTTP-серверы недоступны на этом устройстве.';

final class McpPlatformCapabilities {
  const McpPlatformCapabilities({
    required this.supportsStdio,
    required this.supportsRemoteHttp,
    this.stdioUnavailableReason = mcpStdioUnavailableReason,
    this.remoteHttpUnavailableReason = mcpRemoteHttpUnavailableReason,
  });

  /// Desktop release: external processes and remote HTTPS are both offered.
  static const desktop = McpPlatformCapabilities(
    supportsStdio: true,
    supportsRemoteHttp: true,
  );

  /// Phones and tablets: only remote Streamable HTTPS is offered.
  static const mobile = McpPlatformCapabilities(
    supportsStdio: false,
    supportsRemoteHttp: true,
  );

  /// Aurora reports itself as Linux but intentionally ships without stdio.
  static const aurora = McpPlatformCapabilities(
    supportsStdio: false,
    supportsRemoteHttp: true,
    stdioUnavailableReason: mcpStdioDisabledByPolicyReason,
  );

  /// Web: no local process and no built-in HTTP server.
  static const web = McpPlatformCapabilities(
    supportsStdio: false,
    supportsRemoteHttp: false,
  );

  final bool supportsStdio;
  final bool supportsRemoteHttp;

  /// Shown whenever stdio cannot be offered, never an empty label.
  final String stdioUnavailableReason;
  final String remoteHttpUnavailableReason;

  bool get supportsAnyTransport => supportsStdio || supportsRemoteHttp;

  @override
  String toString() =>
      'McpPlatformCapabilities(stdio: $supportsStdio, http: '
      '$supportsRemoteHttp)';
}

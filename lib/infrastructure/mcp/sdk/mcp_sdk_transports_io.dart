import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../core/mcp/mcp.dart';
import '../mcp_diagnostics.dart';
import '../stdio_environment.dart';
import 'mcp_platform_policy.dart';
import 'mcp_sdk_connection.dart';
import 'mcp_sdk_transports.dart';

McpStdioLauncher createMcpStdioLauncher() => const DartIoMcpStdioLauncher();

/// Spawns a configured command with a minimal environment.
///
/// stdout is reserved for protocol frames; stderr is drained from process
/// start (not after the handshake) into diagnostics after secret redaction.
final class DartIoMcpStdioLauncher implements McpStdioLauncher {
  const DartIoMcpStdioLauncher();

  /// Third-party stdio servers are offered only on confirmed desktop
  /// platforms; Aurora and unknown platforms fall back to built-in streams.
  @override
  bool get isSupported => supportsStdioOnPlatform(
    operatingSystem: Platform.operatingSystem,
    isLinux: Platform.isLinux,
    isWindows: Platform.isWindows,
    isMacOS: Platform.isMacOS,
  );

  @override
  Future<McpTransportConnection> launch({
    required McpConnectionId connectionId,
    required McpStdioTransportConfig config,
    required Map<String, String> secretValues,
    required McpSecretRedactor redactor,
    required McpDiagnosticsSink diagnostics,
  }) async {
    final environment = buildStdioEnvironment(
      parent: Platform.environment,
      explicit: config.environment,
      secretValues: secretValues,
      windows: Platform.isWindows,
    );
    final transport = sdk.StdioClientTransport(
      sdk.StdioServerParameters(
        command: config.command,
        args: config.args,
        environment: environment,
        includeParentEnvironment: false,
        workingDirectory: config.workingDirectory,
        stderrMode: ProcessStartMode.normal,
        restartOnUnexpectedExit: false,
      ),
    );
    late final McpSdkConnection connection;
    final drainingTransport = _StderrDrainingTransport(
      transport,
      onStarted: () => connection.attachStderr(),
    );
    connection = McpSdkConnection(
      connectionId: connectionId,
      kind: McpTransportKind.stdio,
      client: sdk.McpClient(
        const sdk.Implementation(
          name: domovoyMcpClientName,
          version: domovoyMcpClientVersion,
        ),
      ),
      transport: drainingTransport,
      diagnostics: diagnostics,
      redactor: redactor,
      stderrSource: () => transport.stderr
          ?.transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
    return connection;
  }
}

/// Attaches diagnostics immediately after the wrapped transport starts.
///
/// `McpClient.connect` calls `start()` and only then begins the handshake; the
/// hook therefore drains child stderr before the first protocol request.
final class _StderrDrainingTransport
    implements sdk.Transport, sdk.SubscriptionReplayAcknowledgmentTransport {
  _StderrDrainingTransport(this._inner, {required this.onStarted});

  final sdk.Transport _inner;
  final void Function() onStarted;

  @override
  Future<void> start() async {
    await _inner.start();
    onStarted();
  }

  @override
  Future<void> send(sdk.JsonRpcMessage message, {int? relatedRequestId}) =>
      _inner.send(message, relatedRequestId: relatedRequestId);

  @override
  Future<void> close() => _inner.close();

  @override
  String? get sessionId => _inner.sessionId;

  @override
  void Function()? get onclose => _inner.onclose;

  @override
  set onclose(void Function()? callback) => _inner.onclose = callback;

  @override
  void Function(Error error)? get onerror => _inner.onerror;

  @override
  set onerror(void Function(Error error)? callback) =>
      _inner.onerror = callback;

  @override
  void Function(sdk.JsonRpcMessage message)? get onmessage => _inner.onmessage;

  @override
  set onmessage(void Function(sdk.JsonRpcMessage message)? callback) =>
      _inner.onmessage = callback;

  @override
  bool consumeSubscriptionReplayAcknowledgment(sdk.RequestId subscriptionId) {
    final inner = _inner;
    if (inner is! sdk.SubscriptionReplayAcknowledgmentTransport) {
      return false;
    }
    return (inner as sdk.SubscriptionReplayAcknowledgmentTransport)
        .consumeSubscriptionReplayAcknowledgment(subscriptionId);
  }
}

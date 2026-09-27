import 'dart:async';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';

/// Scripted [McpTransportConnection] for host-manager tests.
final class ScriptedMcpConnection implements McpTransportConnection {
  ScriptedMcpConnection({
    required this.connectionId,
    this.kind = McpTransportKind.inProcessStream,
    List<McpToolPage> pages = const <McpToolPage>[],
    this.handshake = const McpHandshake(
      serverName: 'scripted',
      serverVersion: '1.0.0',
      protocolVersion: '2026-07-28',
    ),
    this.connectError,
    this.connectDelay,
    this.listError,
    this.callDelay,
    this.callHandler,
    this.emitProgress = false,
  }) : pages = List<McpToolPage>.of(pages);

  @override
  final McpConnectionId connectionId;

  @override
  final McpTransportKind kind;

  final List<McpToolPage> pages;
  final McpHandshake handshake;
  final Object? connectError;
  final Duration? connectDelay;
  Object? listError;
  final Duration? callDelay;
  final Future<McpToolCallResult> Function(
    String originalToolName,
    Map<String, Object?> arguments,
  )?
  callHandler;

  /// Emits two progress notifications before serving a call.
  final bool emitProgress;

  final List<String?> listedCursors = <String?>[];
  final List<String> calledTools = <String>[];
  var connectCount = 0;
  var closeCount = 0;
  var connected = false;
  var _pageIndex = 0;
  Duration? lastCallTimeout;

  /// When armed, the next connect/list/close call waits for its release.
  Completer<void>? _connectGate;
  Completer<void>? _listGate;
  Completer<void>? _closeGate;

  void armConnectGate() {
    _connectGate = Completer<void>();
  }

  void releaseConnectGate() {
    final gate = _connectGate;
    _connectGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  void armListGate() {
    _listGate = Completer<void>();
  }

  void releaseListGate() {
    final gate = _listGate;
    _listGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  void armCloseGate() {
    _closeGate = Completer<void>();
  }

  void releaseCloseGate() {
    final gate = _closeGate;
    _closeGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  void Function()? get onUnexpectedClose => _onUnexpectedClose;

  @override
  set onUnexpectedClose(void Function()? callback) {
    _onUnexpectedClose = callback;
  }

  void Function()? _onUnexpectedClose;

  @override
  void Function()? get onToolsChanged => _onToolsChanged;

  @override
  set onToolsChanged(void Function()? callback) {
    _onToolsChanged = callback;
  }

  void Function()? _onToolsChanged;

  /// Replaces the scripted pages and resets pagination.
  void replacePages(List<McpToolPage> newPages) {
    pages
      ..clear()
      ..addAll(newPages);
    _pageIndex = 0;
  }

  /// Simulates a `notifications/tools/list_changed` announcement.
  void triggerToolsChanged() {
    _onToolsChanged?.call();
  }

  @override
  bool get isConnected => connected;

  /// Simulates the peer dropping the session without an explicit close.
  void triggerUnexpectedClose() {
    if (!connected) {
      return;
    }
    connected = false;
    _onUnexpectedClose?.call();
  }

  @override
  Future<McpHandshake> connect({
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    connectCount += 1;
    final gate = _connectGate;
    if (gate != null) {
      await gate.future;
    }
    final delay = connectDelay;
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    if (cancellation.isCancelled) {
      throw McpException(
        McpError(kind: McpErrorKind.cancelled, message: 'cancelled'),
      );
    }
    final error = connectError;
    if (error != null) {
      throw error;
    }
    connected = true;
    return handshake;
  }

  @override
  Future<McpToolPage> listTools({
    String? cursor,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    listedCursors.add(cursor);
    final gate = _listGate;
    if (gate != null) {
      await gate.future;
    }
    final error = listError;
    if (error != null) {
      throw error;
    }
    if (_pageIndex >= pages.length) {
      throw McpException(
        McpError(
          kind: McpErrorKind.protocol,
          message: 'unknown cursor "$cursor"',
        ),
      );
    }
    return pages[_pageIndex++];
  }

  @override
  Future<McpToolCallResult> callTool({
    required String originalToolName,
    required Map<String, Object?> arguments,
    required Duration timeout,
    required CancellationToken cancellation,
    void Function(double progress)? onProgress,
  }) async {
    calledTools.add(originalToolName);
    lastCallTimeout = timeout;
    if (emitProgress) {
      onProgress?.call(0.25);
      onProgress?.call(0.75);
    }
    final delay = callDelay;
    if (delay != null) {
      final completer = Completer<McpToolCallResult>();
      final registration = cancellation.register(() {
        if (!completer.isCompleted) {
          completer.completeError(
            McpException(
              McpError(kind: McpErrorKind.cancelled, message: 'cancelled'),
            ),
          );
        }
      });
      final timer = Timer(timeout, () {
        if (!completer.isCompleted) {
          completer.completeError(
            McpException(
              McpError(kind: McpErrorKind.timeout, message: 'timed out'),
            ),
          );
        }
      });
      try {
        return await completer.future;
      } finally {
        registration.dispose();
        timer.cancel();
      }
    }
    final handler = callHandler;
    if (handler != null) {
      return handler(originalToolName, arguments);
    }
    return McpToolCallResult(
      isError: false,
      content: <McpContentBlock>[McpTextBlock(originalToolName)],
    );
  }

  @override
  Future<void> close() async {
    closeCount += 1;
    connected = false;
    final gate = _closeGate;
    if (gate != null) {
      await gate.future;
    }
  }
}

/// Factory that hands out freshly scripted connections per configuration.
final class ScriptedMcpTransportFactory implements McpTransportFactory {
  ScriptedMcpTransportFactory(this._builders);

  final Map<String, ScriptedMcpConnection Function()> _builders;
  final List<McpConnectionId> created = <McpConnectionId>[];

  @override
  Future<McpTransportConnection> create(
    McpConnectionConfig config, {
    required McpSecretResolver secrets,
  }) async {
    created.add(config.connectionId);
    final builder = _builders[config.connectionId.value];
    if (builder == null) {
      throw McpException(
        McpError(
          kind: McpErrorKind.unavailable,
          message: 'No scripted connection for "${config.connectionId}".',
        ),
      );
    }
    return builder();
  }
}

/// Polls [predicate] until it is true or the timeout expires.
Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('waitFor timed out');
    }
    await Future<void>.delayed(interval);
  }
}

/// Minimal descriptor used by scripted connections.
McpToolDescriptor scriptedTool(
  String connectionId,
  String name, {
  String? description,
  String? title,
  Map<String, Object?>? inputSchema,
  Map<String, Object?>? outputSchema,
  Map<String, Object?>? annotations,
}) {
  return McpToolDescriptor(
    connectionId: McpConnectionId(connectionId),
    originalName: name,
    title: title,
    description: description ?? 'Tool $name',
    inputSchema:
        inputSchema ??
        const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{},
        },
    outputSchema: outputSchema,
    annotations: annotations,
  );
}

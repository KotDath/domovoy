import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../core/llm/cancellation.dart';
import '../../../core/llm/json.dart';
import '../../../core/mcp/mcp.dart';
import '../mcp_diagnostics.dart';

/// Adapter over one live `mcp_dart` client session.
///
/// All SDK types stay in this layer; the host and agent bridge only see the
/// contracts from `core/mcp`.
final class McpSdkConnection implements McpTransportConnection {
  McpSdkConnection({
    required this.connectionId,
    required this.kind,
    required sdk.McpClient client,
    required sdk.Transport transport,
    this.diagnostics = const NoopMcpDiagnosticsSink(),
    this.redactor = const McpSecretRedactor.empty(),
    void Function()? onUnexpectedClose,
    Stream<String>? Function()? stderrSource,
  }) : _client = client,
       _transport = transport,
       _onUnexpectedClose = onUnexpectedClose,
       _stderrSource = stderrSource {
    _client.onclose = _handleUnexpectedClose;
  }

  @override
  final McpConnectionId connectionId;

  @override
  final McpTransportKind kind;

  final McpDiagnosticsSink diagnostics;
  final McpSecretRedactor redactor;

  /// Called when the peer closes the session without an explicit `close()`.
  @override
  void Function()? get onUnexpectedClose => _onUnexpectedClose;

  @override
  set onUnexpectedClose(void Function()? callback) {
    _onUnexpectedClose = callback;
  }

  void Function()? _onUnexpectedClose;

  /// Called when the server announces a tool catalog change.
  @override
  void Function()? get onToolsChanged => _onToolsChanged;

  @override
  set onToolsChanged(void Function()? callback) {
    _onToolsChanged = callback;
  }

  void Function()? _onToolsChanged;

  /// Factory for the diagnostic stderr stream; the stream only exists after
  /// the transport has started, so the closure is resolved at connect time.
  final Stream<String>? Function()? _stderrSource;

  final sdk.McpClient _client;
  final sdk.Transport _transport;
  bool _connected = false;
  bool _closed = false;
  bool _closing = false;
  StreamSubscription<String>? _stderrSubscription;

  @override
  bool get isConnected => _connected && !_closed;

  @override
  Future<McpHandshake> connect({
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    if (_closed) {
      throwMcp(McpErrorKind.unavailable, sanitizedMcpUnavailableMessage());
    }
    if (cancellation.isCancelled) {
      throwMcp(McpErrorKind.cancelled, 'cancelled');
    }
    final registration = cancellation.register(() {
      unawaited(close());
    });
    try {
      await _client.connect(_transport).timeout(timeout);
      if (cancellation.isCancelled) {
        await close();
        throwMcp(McpErrorKind.cancelled, 'cancelled');
      }
      _connected = true;
      _registerCatalogChangeHandler();
      return _handshake();
    } on McpException {
      await close();
      rethrow;
    } on TimeoutException {
      await close();
      throwMcp(McpErrorKind.timeout, 'MCP handshake timed out.');
    } on Object catch (error) {
      await close();
      throw _mapError(error, fallback: McpErrorKind.handshake);
    } finally {
      _attachStderr();
      registration.dispose();
    }
  }

  void _registerCatalogChangeHandler() {
    _client.setNotificationHandler<sdk.JsonRpcToolListChangedNotification>(
      sdk.Method.notificationsToolsListChanged,
      (notification) async {
        _onToolsChanged?.call();
      },
      (params, meta) => sdk.JsonRpcToolListChangedNotification(meta: meta),
    );
  }

  /// Attaches the diagnostic stderr listener as soon as the transport exists.
  ///
  /// Safe to call multiple times; only the first call subscribes. The stdio
  /// launcher calls it from a transport-start hook so a noisy child is drained
  /// before initialize, not after the handshake.
  void attachStderr() {
    _attachStderr();
  }

  void _attachStderr() {
    if (_stderrSubscription != null || _closed) {
      return;
    }
    final source = _stderrSource;
    if (source == null) {
      return;
    }
    final stream = source();
    if (stream == null) {
      return;
    }
    _stderrSubscription = stream.listen((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        return;
      }
      diagnostics.log(
        redactor.redact('mcp ${connectionId.value} stderr: $trimmed'),
      );
    });
  }

  @override
  Future<McpToolPage> listTools({
    String? cursor,
    required Duration timeout,
    required CancellationToken cancellation,
  }) async {
    _ensureConnected();
    final controller = sdk.BasicAbortController();
    final registration = cancellation.register(controller.abort);
    try {
      final result = await _client.listTools(
        params: cursor == null ? null : sdk.ListToolsRequest(cursor: cursor),
        options: sdk.RequestOptions(
          timeout: timeout,
          signal: controller.signal,
        ),
      );
      _throwIfCancelled(cancellation);
      return McpToolPage(
        tools: <McpToolDescriptor>[
          for (final tool in result.tools) _mapTool(tool),
        ],
        nextCursor: _trimmedOrNull(result.nextCursor),
      );
    } on McpException {
      rethrow;
    } on Object catch (error) {
      _throwIfCancelled(cancellation);
      throw _mapError(error, fallback: McpErrorKind.protocol);
    } finally {
      registration.dispose();
      controller.abort();
    }
  }

  @override
  Future<McpToolCallResult> callTool({
    required String originalToolName,
    required Map<String, Object?> arguments,
    required Duration timeout,
    required CancellationToken cancellation,
    void Function(double progress)? onProgress,
    Map<String, Object?>? requestMeta,
  }) async {
    _ensureConnected();
    final controller = sdk.BasicAbortController();
    final registration = cancellation.register(controller.abort);
    try {
      final options = sdk.RequestOptions(
        timeout: timeout,
        signal: controller.signal,
        onprogress: onProgress == null
            ? null
            : (progress) => onProgress(progress.progress.toDouble()),
      );
      final sdk.CallToolResult result;
      if (requestMeta == null) {
        result = await _client.callTool(
          sdk.CallToolRequest(
            name: originalToolName,
            arguments: Map<String, dynamic>.from(arguments),
          ),
          options: options,
        );
      } else {
        // Narrow `_meta` path (B4 digest pin scope). `CallToolRequest` has no
        // meta field in mcp_dart 2.4.2, so the JSON-RPC envelope is built
        // explicitly; the public `request` still assigns the wire id, applies
        // the stateless protocol metadata and parses the result through the
        // same `CallToolResult.fromJson` contract. Request `_meta` is part of
        // the envelope, never of the model-authored arguments.
        result = await _client.request<sdk.CallToolResult>(
          sdk.JsonRpcCallToolRequest(
            id: -1,
            params: sdk.CallToolRequest(
              name: originalToolName,
              arguments: Map<String, dynamic>.from(arguments),
            ).toJson(),
            meta: Map<String, dynamic>.from(requestMeta),
          ),
          sdk.CallToolResult.fromJson,
          options,
        );
      }
      _throwIfCancelled(cancellation);
      return _mapCallResult(result);
    } on McpException {
      rethrow;
    } on Object catch (error) {
      _throwIfCancelled(cancellation);
      throw _mapError(error, fallback: McpErrorKind.protocol);
    } finally {
      registration.dispose();
      controller.abort();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _closing = true;
    _connected = false;
    try {
      await _client.close();
    } on Object {
      // Closing is best effort; the transport close below still runs.
    }
    try {
      await _transport.close();
    } on Object {
      // The session may already be gone.
    }
    await _stderrSubscription?.cancel();
    _stderrSubscription = null;
    _closing = false;
  }

  McpHandshake _handshake() {
    final serverVersion = _client.getServerVersion();
    final capabilities = _client.getServerCapabilities();
    return McpHandshake(
      serverName: serverVersion?.name ?? 'unknown',
      serverVersion: serverVersion?.version ?? 'unknown',
      protocolVersion: _client.getProtocolVersion() ?? 'unknown',
      instructions: _trimmedOrNull(_client.getInstructions()),
      capabilities: _jsonObject(capabilities?.toJson()),
    );
  }

  McpToolDescriptor _mapTool(sdk.Tool tool) {
    final raw = _jsonObject(tool.toJson());
    return McpToolDescriptor(
      connectionId: connectionId,
      originalName: tool.name,
      title: tool.title,
      description: tool.description,
      inputSchema: _jsonObject(raw['inputSchema']),
      outputSchema: _jsonObjectOrNull(raw['outputSchema']),
      annotations: _jsonObjectOrNull(raw['annotations']),
      raw: raw,
    );
  }

  McpToolCallResult _mapCallResult(sdk.CallToolResult result) {
    final blocks = <McpContentBlock>[];
    for (final content in result.content) {
      switch (content) {
        case sdk.TextContent():
          blocks.add(McpTextBlock(content.text));
        case sdk.ImageContent():
          blocks.add(
            McpMediaBlock(
              kind: McpContentKind.image,
              data: content.data,
              mimeType: content.mimeType,
            ),
          );
        case sdk.AudioContent():
          blocks.add(
            McpMediaBlock(
              kind: McpContentKind.audio,
              data: content.data,
              mimeType: content.mimeType,
            ),
          );
        case sdk.ResourceLink():
          blocks.add(
            McpResourceLinkBlock(
              uri: content.uri,
              name: content.name,
              mimeType: content.mimeType,
            ),
          );
        case sdk.EmbeddedResource():
          final resource = content.resource;
          blocks.add(switch (resource) {
            sdk.TextResourceContents() => McpEmbeddedResourceBlock(
              uri: resource.uri,
              embeddedText: resource.text,
              mimeType: resource.mimeType,
            ),
            sdk.BlobResourceContents() => McpEmbeddedResourceBlock(
              uri: resource.uri,
              data: resource.blob,
              mimeType: resource.mimeType,
            ),
            sdk.UnknownResourceContents() => McpUnsupportedBlock(
              label: 'resource:${resource.uri}',
            ),
          });
        case sdk.UnknownContent():
          blocks.add(McpUnsupportedBlock(label: content.type));
      }
    }
    Object? structured;
    if (result.hasStructuredContent) {
      structured = deepCopyJson(result.structuredContentJson?.toJson());
    } else if (result.structuredContent != null) {
      structured = deepCopyJson(result.structuredContent);
    }
    return McpToolCallResult(
      isError: result.isError,
      content: List<McpContentBlock>.unmodifiable(blocks),
      structuredContent: structured,
    );
  }

  void _handleUnexpectedClose() {
    if (_closed || _closing) {
      return;
    }
    _connected = false;
    diagnostics.log(
      'mcp connection ${connectionId.value} closed by peer'.trim(),
    );
    onUnexpectedClose?.call();
  }

  void _ensureConnected() {
    if (!isConnected) {
      throwMcp(McpErrorKind.unavailable, sanitizedMcpUnavailableMessage());
    }
  }

  void _throwIfCancelled(CancellationToken cancellation) {
    if (cancellation.isCancelled) {
      throwMcp(McpErrorKind.cancelled, 'cancelled');
    }
  }

  McpException _mapError(Object error, {required McpErrorKind fallback}) {
    if (error is TimeoutException) {
      return McpException(
        McpError(kind: McpErrorKind.timeout, message: 'MCP request timed out.'),
      );
    }
    if (error is sdk.McpError) {
      final message = redactor.redact(error.message);
      final sanitized = sanitizeMcpText(
        message,
        fallback: _fallbackMessage(fallback),
      );
      final kind = message.toLowerCase().contains('timed out')
          ? McpErrorKind.timeout
          : fallback;
      return McpException(McpError(kind: kind, message: sanitized));
    }
    final sanitized = sanitizeMcpText(
      redactor.redact(error.toString()),
      fallback: _fallbackMessage(fallback),
    );
    return McpException(McpError(kind: fallback, message: sanitized));
  }
}

String _fallbackMessage(McpErrorKind kind) => switch (kind) {
  McpErrorKind.handshake => 'MCP-сервер не завершил рукопожатие.',
  McpErrorKind.timeout => 'MCP-запрос не успел завершиться.',
  McpErrorKind.cancelled => 'MCP-запрос отменён.',
  McpErrorKind.protocol => 'MCP-сервер вернул некорректный ответ.',
  _ => sanitizedMcpUnavailableMessage(),
};

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

Map<String, Object?> _jsonObject(Object? value) {
  final object = asJsonObject(value);
  if (object == null) {
    return const <String, Object?>{};
  }
  return freezeJsonMap(object);
}

Map<String, Object?>? _jsonObjectOrNull(Object? value) {
  final object = asJsonObject(value);
  if (object == null) {
    return null;
  }
  return freezeJsonMap(object);
}

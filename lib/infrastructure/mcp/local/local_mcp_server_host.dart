import 'dart:async';
import 'dart:math';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../core/mcp/mcp.dart';
import '../mcp_diagnostics.dart';
import '../secrets/mcp_secret_vault.dart';
import 'local_http_launcher.dart';
import 'local_mcp_definition.dart';

/// Preferred local transport for `LocalMcpServerHost.start`.
enum McpLocalTransportPreference {
  /// Loopback HTTP when the platform supports it, otherwise in-process stream.
  auto,

  /// Loopback Streamable HTTP with a short-lived bearer token.
  http,

  /// In-process `IOStreamTransport` pair; works on every platform.
  stream,
}

/// Bidirectional byte streams connecting an in-process MCP server and client.
final class McpStreamPair {
  McpStreamPair._(this._clientToServer, this._serverToClient);

  factory McpStreamPair.create() {
    final clientToServer = StreamController<List<int>>();
    final serverToClient = StreamController<List<int>>();
    return McpStreamPair._(clientToServer, serverToClient);
  }

  final StreamController<List<int>> _clientToServer;
  final StreamController<List<int>> _serverToClient;

  /// Server-side incoming stream.
  Stream<List<int>> get serverInbound => _clientToServer.stream;

  /// Server-side outgoing sink.
  StreamSink<List<int>> get serverOutbound => _serverToClient.sink;

  /// Client-side incoming stream.
  Stream<List<int>> get clientInbound => _serverToClient.stream;

  /// Client-side outgoing sink.
  StreamSink<List<int>> get clientOutbound => _clientToServer.sink;

  /// Closes both directions without waiting on the peer.
  ///
  /// A single-subscription controller's `close()` future only completes once
  /// the done event is delivered; after a transport cancels its subscription
  /// that may never happen, so shutdown must not await it.
  Future<void> close() async {
    _clientToServer.close().ignore();
    _serverToClient.close().ignore();
  }
}

/// Lookup of live streams for `inProcessStream` connection configurations.
abstract interface class LocalMcpStreamRegistry {
  /// Returns a usable in-process stream session for [serverId].
  ///
  /// A single-subscription `McpStreamPair` and its server-side protocol state
  /// cannot be reused after the client disconnects, so the host creates a
  /// fresh session once the previous one was released by its client. A second
  /// acquire while a session is still reserved for a live client is rejected
  /// with a clear error instead of closing that client's session.
  Future<McpStreamPair> acquireStreams(String serverId);

  /// Marks a handed-out session as no longer used by its client.
  ///
  /// Called when the client transport closes for any reason.
  void releaseStreams(String serverId, McpStreamPair pair);
}

/// Data describing a started local server endpoint.
sealed class LocalMcpServerEndpoint {
  const LocalMcpServerEndpoint({required this.serverId, required this.kind});

  final String serverId;
  final McpTransportKind kind;
}

final class LocalMcpHttpEndpoint extends LocalMcpServerEndpoint {
  const LocalMcpHttpEndpoint({
    required super.serverId,
    required this.url,
    required this.bearerToken,
  }) : super(kind: McpTransportKind.streamableHttp);

  final Uri url;

  /// Short-lived token, kept only in memory for in-process clients.
  final String bearerToken;
}

final class LocalMcpStreamEndpoint extends LocalMcpServerEndpoint {
  const LocalMcpStreamEndpoint({required super.serverId})
    : super(kind: McpTransportKind.inProcessStream);
}

/// Owns registration, start and shutdown of built-in local MCP servers.
///
/// B3-B6 register their factories; B9 composes the host with the MCP host
/// manager. The host itself does not know any specific server.
final class LocalMcpServerHost implements LocalMcpStreamRegistry {
  LocalMcpServerHost({
    this.preference = McpLocalTransportPreference.auto,
    RuntimeMcpSecretResolver? runtimeSecrets,
    this.diagnostics = const NoopMcpDiagnosticsSink(),
    McpHttpServerLauncher? httpLauncher,
    Random? random,
  }) : _runtimeSecrets = runtimeSecrets,
       _http = httpLauncher ?? createMcpHttpServerLauncher(),
       _random = random;

  final McpLocalTransportPreference preference;
  final RuntimeMcpSecretResolver? _runtimeSecrets;
  final McpDiagnosticsSink diagnostics;
  final McpHttpServerLauncher _http;
  final Random? _random;
  final Map<String, LocalMcpServerFactory> _factories =
      <String, LocalMcpServerFactory>{};
  final Map<String, _RunningLocalServer> _running =
      <String, _RunningLocalServer>{};
  final Set<String> _streamAcquisitions = <String>{};

  bool get supportsLoopbackHttp => _http.isSupported;

  List<String> get serverIds => List<String>.unmodifiable(_factories.keys);

  /// Registers one built-in server factory; the last registration wins.
  void register(LocalMcpServerFactory factory) {
    final definition = factory.create();
    _factories[definition.id] = factory;
  }

  /// True when the server is currently started.
  bool isRunning(String serverId) => _running.containsKey(serverId);

  LocalMcpServerEndpoint? endpointFor(String serverId) =>
      _running[serverId]?.endpoint;

  @override
  Future<McpStreamPair> acquireStreams(String serverId) async {
    final running = _running[serverId];
    if (running == null) {
      throwMcp(
        McpErrorKind.unavailable,
        'Local MCP server "$serverId" is not running.',
      );
    }
    if (running.endpoint is! LocalMcpStreamEndpoint) {
      throwMcp(
        McpErrorKind.configuration,
        'Local MCP server "$serverId" is not an in-process stream endpoint.',
      );
    }
    if (running.activePair != null) {
      throwMcp(
        McpErrorKind.unavailable,
        'Local MCP server "$serverId" already has a live stream client.',
      );
    }
    if (!_streamAcquisitions.add(serverId)) {
      throwMcp(
        McpErrorKind.unavailable,
        'Local MCP server "$serverId" is already handing out a stream session.',
      );
    }
    try {
      if (!running.sessionUsable) {
        await _startStreamSession(running);
      }
      if (!identical(_running[serverId], running)) {
        // The server was stopped (or restarted) while the fresh session was
        // being created; close the detached session instead of leaking it.
        await running.closeSession();
        diagnostics.log(
          'mcp local server $serverId discarded a session started after stop',
        );
        throwMcp(
          McpErrorKind.unavailable,
          'Local MCP server "$serverId" was stopped while acquiring a stream '
          'session.',
        );
      }
      final pair = running.pair!;
      // The pair is single-subscription: it is consumed by this client and
      // must be replaced after release.
      running.sessionUsable = false;
      running.activePair = pair;
      return pair;
    } finally {
      _streamAcquisitions.remove(serverId);
    }
  }

  @override
  void releaseStreams(String serverId, McpStreamPair pair) {
    final running = _running[serverId];
    if (running == null || !identical(running.activePair, pair)) {
      return;
    }
    running.activePair = null;
    running.sessionUsable = false;
  }

  /// Starts [serverId] and returns its endpoint, reusing a running instance.
  Future<LocalMcpServerEndpoint> start(
    String serverId, {
    McpLocalTransportPreference? preference,
  }) async {
    final running = _running[serverId];
    if (running != null) {
      return running.endpoint;
    }
    final factory = _factories[serverId];
    if (factory == null) {
      throwMcp(
        McpErrorKind.configuration,
        'Unknown local MCP server "$serverId".',
      );
    }
    final definition = factory.create();
    final effective = _effectivePreference(preference ?? this.preference);
    if (effective == McpLocalTransportPreference.http) {
      final token = _generateToken();
      final handle = await _http.start(definition, bearerToken: token);
      final endpoint = LocalMcpHttpEndpoint(
        serverId: definition.id,
        url: handle.url,
        bearerToken: token,
      );
      _running[definition.id] = _RunningLocalServer(
        definition: definition,
        endpoint: endpoint,
        httpStop: handle.stop,
      );
      _runtimeSecrets?.put(_bearerReference(definition.id), token);
      diagnostics.log(
        'mcp local server ${definition.id} listening on ${handle.url}',
      );
      return endpoint;
    }
    final endpoint = LocalMcpStreamEndpoint(serverId: definition.id);
    final runningState = _RunningLocalServer(
      definition: definition,
      endpoint: endpoint,
    );
    try {
      await _startStreamSession(runningState);
    } on Object {
      // A failed start must not leave a broken endpoint behind: clean up the
      // partial session and let the caller retry.
      await runningState.closeSession();
      rethrow;
    }
    _running[definition.id] = runningState;
    diagnostics.log(
      'mcp local server ${definition.id} started in-process stream',
    );
    return endpoint;
  }

  /// Replaces the in-process session with a freshly connected pair.
  Future<void> _startStreamSession(_RunningLocalServer running) async {
    final oldServer = running.server;
    final oldPair = running.pair;
    running.server = null;
    running.pair = null;
    if (oldServer != null) {
      try {
        await oldServer.close().timeout(const Duration(seconds: 5));
      } on Object {
        // The old session may already be closed or stuck; replace it anyway.
      }
    }
    if (oldPair != null) {
      try {
        await oldPair.close();
      } on Object {
        // Streams may already be closed.
      }
    }
    final pair = McpStreamPair.create();
    sdk.McpServer? server;
    try {
      server = createLocalMcpServer(running.definition);
      await server.connect(
        sdk.IOStreamTransport(
          stream: pair.serverInbound,
          sink: pair.serverOutbound,
        ),
      );
    } on Object {
      try {
        await server?.close().timeout(const Duration(seconds: 5));
      } on Object {
        // Partial server state is discarded below.
      }
      await pair.close();
      rethrow;
    }
    running.pair = pair;
    running.server = server;
    diagnostics.log(
      'mcp local server ${running.definition.id} started fresh stream session',
    );
  }

  /// Stops one running server and releases its endpoint.
  Future<void> stop(String serverId) async {
    final running = _running.remove(serverId);
    if (running == null) {
      return;
    }
    _runtimeSecrets?.remove(_bearerReference(serverId));
    try {
      await running.httpStop?.call();
    } on Object {
      // Listener may already be closed.
    }
    await running.closeSession();
    diagnostics.log('mcp local server $serverId stopped');
  }

  /// Stops every server this host started.
  Future<void> stopAll() async {
    for (final serverId in _running.keys.toList(growable: false)) {
      await stop(serverId);
    }
  }

  /// Builds the connection configuration for a started endpoint.
  McpConnectionConfig connectionConfig(
    String serverId, {
    String? alias,
    bool enabled = true,
    int revision = 0,
  }) {
    final running = _running[serverId];
    if (running == null) {
      throwMcp(
        McpErrorKind.configuration,
        'Local MCP server "$serverId" is not started.',
      );
    }
    final endpoint = running.endpoint;
    final connectionId = McpConnectionId(serverId);
    final transport = switch (endpoint) {
      LocalMcpHttpEndpoint() => McpHttpTransportConfig(
        url: endpoint.url.toString(),
        bearerSecret: _bearerReference(serverId),
      ),
      LocalMcpStreamEndpoint() => McpInProcessStreamTransportConfig(
        serverId: serverId,
      ),
    };
    return McpConnectionConfig(
      connectionId: connectionId,
      alias: alias ?? running.definition.displayName,
      transport: transport,
      enabled: enabled,
      revision: revision,
    );
  }

  McpLocalTransportPreference _effectivePreference(
    McpLocalTransportPreference requested,
  ) {
    if (requested == McpLocalTransportPreference.auto) {
      return _http.isSupported
          ? McpLocalTransportPreference.http
          : McpLocalTransportPreference.stream;
    }
    return requested;
  }

  McpSecretReference _bearerReference(String serverId) =>
      McpSecretReference.bearer(McpConnectionId(serverId));

  String _generateToken() {
    final random = _random ?? Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

final class _RunningLocalServer {
  _RunningLocalServer({
    required this.definition,
    required this.endpoint,
    this.httpStop,
  });

  final LocalMcpServerDefinition definition;
  final LocalMcpServerEndpoint endpoint;

  /// Whether [pair] can still be handed to a client.
  var sessionUsable = true;

  /// Session currently reserved by a live client, if any.
  McpStreamPair? activePair;

  sdk.McpServer? server;
  McpStreamPair? pair;
  final Future<void> Function()? httpStop;

  /// Closes the in-process session without touching HTTP state.
  Future<void> closeSession() async {
    final server = this.server;
    final pair = this.pair;
    this.server = null;
    this.pair = null;
    activePair = null;
    sessionUsable = false;
    if (server != null) {
      try {
        await server.close().timeout(const Duration(seconds: 5));
      } on Object {
        // Session may already be gone or shutdown may be stuck; the stream
        // pair is closed below regardless.
      }
    }
    if (pair != null) {
      try {
        await pair.close();
      } on Object {
        // Streams may already be closed.
      }
    }
  }
}

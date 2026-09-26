import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';

import 'mcp_fakes.dart';

/// A started [McpHostManager] over scripted connections plus the B2 bridge
/// attached to a registry that can also hold static Pi-style tools.
final class ScriptedMcpAgentHarness {
  ScriptedMcpAgentHarness({
    required this.connections,
    McpToolResultMapper mapper = const McpToolResultMapper(),
    Duration? callTimeout,
    McpTimeouts timeouts = const McpTimeouts(),
    Iterable<AgentTool> staticTools = const <AgentTool>[],
  }) : _mapper = mapper,
       _callTimeout = callTimeout,
       _timeouts = timeouts,
       _staticTools = List<AgentTool>.of(staticTools);

  final Map<String, ScriptedMcpConnection> connections;
  final McpToolResultMapper _mapper;
  final Duration? _callTimeout;
  final McpTimeouts _timeouts;
  final List<AgentTool> _staticTools;

  late final McpHostManager host;
  late final McpAgentToolBridge bridge;
  late final AgentToolRegistry tools;
  late final ScriptedMcpTransportFactory transports;

  Future<void> start() async {
    final repository = InMemoryMcpConnectionRepository();
    final token = CancellationSource().token;
    transports = ScriptedMcpTransportFactory(
      <String, ScriptedMcpConnection Function()>{
        for (final id in connections.keys) id: () => connections[id]!,
      },
    );
    for (final id in connections.keys) {
      await repository.save(
        McpConnectionConfig(
          connectionId: McpConnectionId(id),
          alias: id,
          transport: McpInProcessStreamTransportConfig(serverId: id),
        ),
        expectedRevision: 0,
        cancellation: token,
      );
    }
    host = McpHostManager(
      transports: transports,
      repository: repository,
      secrets: InMemoryMcpSecretVault(),
      diagnostics: MemoryMcpDiagnosticsSink(),
      timeouts: _timeouts,
      reconnectPolicy: const McpReconnectPolicy(maxAttempts: 0),
    );
    await host.start();
    tools = AgentToolRegistry();
    for (final tool in _staticTools) {
      tools.register(tool);
    }
    bridge = McpAgentToolBridge(
      host: host,
      callTimeout: _callTimeout,
      mapper: _mapper,
    );
    bridge.attachTo(tools);
  }

  Future<void> dispose() async {
    bridge.dispose();
    tools.dispose();
    await host.stop();
    host.dispose();
  }
}

/// A static tool with a scripted executor, used to prove that built-in tools
/// keep working next to the dynamic MCP catalog.
AgentTool staticAgentTool(
  String name, {
  Map<String, Object?> parameters = const <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{},
  },
  Future<ToolExecutionResult> Function(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  })?
  handler,
}) {
  return AgentTool(
    descriptor: LlmToolDescriptor(name: name, parameters: parameters),
    executor: _StaticExecutor(handler),
  );
}

final class _StaticExecutor implements AgentToolExecutor {
  _StaticExecutor(this.handler);

  final Future<ToolExecutionResult> Function(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  })?
  handler;

  @override
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  }) async {
    final resolved = handler;
    if (resolved == null) {
      return ToolExecutionResult.success(<String, Object?>{'static': true});
    }
    return resolved(invocation, cancellation: cancellation, liveness: liveness);
  }
}

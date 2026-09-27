import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bridge-level rules of the app-owned run context:
/// - the digest scope travels only in the JSON-RPC `_meta` of an app-owned
///   local digest connection and never appears in arguments;
/// - the scheduled run id binding applies only to app-owned local
///   `save_digest`, and a model-supplied conflict fails closed;
/// - a user-configured connection (even one reusing a built-in id) receives
///   neither capability.
void main() {
  test('run scope and library run id bind only to app-owned routes', () async {
    final host = _RecordingHost(
      appOwned: <String>{'digest', 'library'},
      tools: <({String connectionId, String originalName})>[
        (connectionId: 'arxiv', originalName: 'search_papers'),
        (connectionId: 'digest', originalName: 'summarize_papers'),
        (connectionId: 'library', originalName: 'save_digest'),
      ],
    );
    final source = McpAgentToolSource(
      host: host,
      digestScopeConnectionIds: const <String>{'digest'},
      libraryRunIdConnectionIds: const <String>{'library'},
    );
    addTearDown(source.dispose);

    final token = CancellationSource().token;
    final liveness = _NoopLiveness();

    Future<ToolExecutionResult> call(
      String modelToolName, {
      Map<String, Object?> arguments = const <String, Object?>{},
      AgentRunToolContext? context,
      String? runId,
    }) {
      final tool = source.view.tools[modelToolName]!;
      return tool.executor.execute(
        ToolInvocation(
          callId: 'call-1',
          name: modelToolName,
          arguments: arguments,
          runId: runId == null ? null : RunId(runId),
          runContext: context,
        ),
        cancellation: token,
        liveness: liveness,
      );
    }

    final scoped = AgentRunToolContext(
      scopeKey: 'run-scope-1',
      bindLibraryRunId: true,
    );

    // Digest: the capability is carried in the envelope, never in arguments.
    final digest = await call(
      'mcp_digest__summarize_papers',
      arguments: const <String, Object?>{'topic': 'x'},
      context: scoped,
    );
    expect(digest.success, isTrue);
    expect(host.calls.single.requestMeta, <String, Object?>{
      'domovoy/runScope': 'run-scope-1',
    });
    expect(host.calls.single.arguments, isNot(contains('domovoy/runScope')));

    // A non-digest route must not receive the scope envelope.
    await call(
      'mcp_arxiv__search_papers',
      arguments: const <String, Object?>{'query': 'x'},
      context: scoped,
    );
    expect(host.calls.last.requestMeta, isNull);

    // Library: the runtime run id is bound for a scheduled run.
    final save = await call(
      'mcp_library__save_digest',
      arguments: const <String, Object?>{'topic': 'x'},
      context: scoped,
      runId: 'run-42',
    );
    expect(save.success, isTrue);
    expect(host.calls.last.arguments['runId'], 'run-42');
    expect(host.calls.last.requestMeta, isNull);

    // The same route without the scheduled binding keeps manual behavior.
    await call(
      'mcp_library__save_digest',
      arguments: const <String, Object?>{'topic': 'x'},
      context: AgentRunToolContext(scopeKey: 'run-scope-2'),
      runId: 'run-43',
    );
    expect(host.calls.last.arguments.containsKey('runId'), isFalse);

    // A conflicting model-authored value fails closed before the server.
    final callsBefore = host.calls.length;
    final conflict = await call(
      'mcp_library__save_digest',
      arguments: const <String, Object?>{'topic': 'x', 'runId': 'model-run'},
      context: scoped,
      runId: 'run-44',
    );
    expect(conflict.success, isFalse);
    expect(host.calls, hasLength(callsBefore));

    // A connection that is not app-owned receives nothing, even when it
    // reuses the built-in id.
    final foreign = _RecordingHost(
      appOwned: const <String>{},
      tools: <({String connectionId, String originalName})>[
        (connectionId: 'digest', originalName: 'summarize_papers'),
        (connectionId: 'library', originalName: 'save_digest'),
      ],
    );
    final foreignSource = McpAgentToolSource(
      host: foreign,
      digestScopeConnectionIds: const <String>{'digest'},
      libraryRunIdConnectionIds: const <String>{'library'},
    );
    addTearDown(foreignSource.dispose);
    await foreignSource.view.tools['mcp_digest__summarize_papers']!.executor
        .execute(
          ToolInvocation(
            callId: 'foreign-1',
            name: 'mcp_digest__summarize_papers',
            arguments: const <String, Object?>{},
            runContext: scoped,
          ),
          cancellation: token,
          liveness: liveness,
        );
    expect(foreign.calls.single.requestMeta, isNull);
    await foreignSource.view.tools['mcp_library__save_digest']!.executor
        .execute(
          ToolInvocation(
            callId: 'foreign-2',
            name: 'mcp_library__save_digest',
            arguments: const <String, Object?>{},
            runId: RunId('run-45'),
            runContext: scoped,
          ),
          cancellation: token,
          liveness: liveness,
        );
    expect(foreign.calls.last.arguments.containsKey('runId'), isFalse);
  });
}

final class _CallRecord {
  _CallRecord({
    required this.modelToolName,
    required this.arguments,
    required this.requestMeta,
  });

  final String modelToolName;
  final Map<String, Object?> arguments;
  final Map<String, Object?>? requestMeta;
}

final class _RecordingHost implements McpHost {
  _RecordingHost({required this.appOwned, required this.tools});

  final Set<String> appOwned;
  final List<({String connectionId, String originalName})> tools;
  final List<_CallRecord> calls = <_CallRecord>[];

  late final McpCatalog _catalog = _buildCatalog();

  McpCatalog _buildCatalog() {
    final builder = McpCatalogBuilder(revision: 1);
    for (final tool in tools) {
      builder.addConnection(McpConnectionId(tool.connectionId), [
        McpToolDescriptor(
          connectionId: McpConnectionId(tool.connectionId),
          originalName: tool.originalName,
          inputSchema: const <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{},
          },
        ),
      ]);
    }
    return builder.build();
  }

  @override
  McpHostSnapshot get snapshot => McpHostSnapshot(
    revision: 1,
    connections: const <McpConnectionStatus>[],
    catalog: _catalog,
  );

  @override
  Stream<McpHostEvent> get events => const Stream<McpHostEvent>.empty();

  @override
  bool isAppOwnedConnection(McpConnectionId id) => appOwned.contains(id.value);

  @override
  Future<McpToolCallResult> callTool({
    required String modelToolName,
    required Map<String, Object?> arguments,
    Duration? timeout,
    CancellationToken? cancellation,
    void Function(double progress)? onProgress,
    Map<String, Object?>? requestMeta,
  }) async {
    calls.add(
      _CallRecord(
        modelToolName: modelToolName,
        arguments: Map<String, Object?>.of(arguments),
        requestMeta: requestMeta,
      ),
    );
    return const McpToolCallResult(
      isError: false,
      content: <McpContentBlock>[McpTextBlock('ok')],
    );
  }

  @override
  Future<void> start({CancellationToken? cancellation}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> upsertConnection(
    McpConnectionConfig config, {
    bool connect = true,
  }) async {}

  @override
  Future<void> removeConnection(McpConnectionId id) async {}

  @override
  Future<void> connect(McpConnectionId id) async {}

  @override
  Future<void> disconnect(McpConnectionId id) async {}

  @override
  Future<void> restart(McpConnectionId id) async {}

  @override
  Future<void> refreshCatalog([McpConnectionId? id]) async {}
}

final class _NoopLiveness implements ToolExecutionLiveness {
  @override
  void reportProgress({String? detail}) {}
}

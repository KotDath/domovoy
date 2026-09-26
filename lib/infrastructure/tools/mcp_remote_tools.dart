import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../../core/agents/agents.dart';
import '../../core/llm/llm.dart';

/// A separate MCP client per server; discovered tools are routed by stable prefix.
final class McpRemoteTools {
  McpRemoteTools._(this.registry, this.enabled, this._clients);

  final AgentToolRegistry registry;
  final List<ToolId> enabled;
  final List<mcp.McpClient> _clients;

  static Map<String, Uri> parseConfiguration(String raw) {
    if (raw.trim().isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('DOMOVOY_MCP_SERVERS must be a JSON object.');
    }
    final endpoints = <String, Uri>{};
    for (final entry in decoded.entries) {
      if (!_validPrefix(entry.key) || entry.value is! String) {
        throw const FormatException('Invalid MCP server alias or endpoint.');
      }
      endpoints[entry.key] = _validateEndpoint(
        Uri.parse(entry.value as String),
      );
    }
    return endpoints;
  }

  static Future<McpRemoteTools> connect(Map<String, Uri> endpoints) async {
    final registry = AgentToolRegistry();
    final enabled = <ToolId>[];
    final clients = <mcp.McpClient>[];
    try {
      for (final entry in endpoints.entries) {
        if (!_validPrefix(entry.key)) {
          throw FormatException('Invalid MCP server alias: ${entry.key}');
        }
        _validateEndpoint(entry.value);
        final client = mcp.McpClient(
          const mcp.Implementation(name: 'domovoy', version: '1.0.0'),
          options: const mcp.McpClientOptions(protocol: mcp.McpProtocol.stable),
        );
        clients.add(client);
        await client.connect(mcp.StreamableHttpClientTransport(entry.value));
        String? cursor;
        do {
          final page = await client.listTools(
            params: cursor == null
                ? null
                : mcp.ListToolsRequest(cursor: cursor),
          );
          for (final tool in page.tools) {
            final name = '${entry.key}__${tool.name}';
            if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(name)) {
              throw FormatException('Invalid MCP tool name: $name');
            }
            final descriptor = LlmToolDescriptor(
              name: name,
              description: '${entry.key}: ${tool.description ?? tool.name}',
              parameters: _agentSchema(tool.inputSchema.toJson()),
            );
            registry.register(
              AgentTool(
                descriptor: descriptor,
                executor: _McpToolExecutor(
                  client: client,
                  remoteName: tool.name,
                ),
              ),
            );
            enabled.add(ToolId(name));
          }
          cursor = page.nextCursor;
        } while (cursor != null);
      }
      return McpRemoteTools._(registry, List.unmodifiable(enabled), clients);
    } on Object {
      for (final client in clients) {
        await client.close();
      }
      rethrow;
    }
  }

  Future<void> close() async {
    for (final client in _clients) {
      await client.close();
    }
  }
}

final class _McpToolExecutor implements AgentToolExecutor {
  const _McpToolExecutor({required this.client, required this.remoteName});

  final mcp.McpClient client;
  final String remoteName;

  @override
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  }) async {
    if (cancellation.isCancelled) {
      return ToolExecutionResult.failure('MCP call cancelled.');
    }
    final abort = mcp.BasicAbortController();
    final registration = cancellation.register(abort.abort);
    try {
      final result = await client.callTool(
        mcp.CallToolRequest(
          name: remoteName,
          arguments: Map<String, dynamic>.from(invocation.arguments),
        ),
        options: mcp.RequestOptions(
          signal: abort.signal,
          timeout: const Duration(seconds: 45),
          onprogress: (_) => liveness.reportProgress(),
        ),
      );
      if (result.isError) {
        return ToolExecutionResult.failure(
          result.content
              .whereType<mcp.TextContent>()
              .map((item) => item.text)
              .join(' '),
        );
      }
      liveness.reportProgress();
      final structured = result.structuredContent;
      if (structured != null) return ToolExecutionResult.success(structured);
      return ToolExecutionResult.success({
        'content': result.content
            .whereType<mcp.TextContent>()
            .map((item) => item.text)
            .toList(),
      });
    } on Object {
      return ToolExecutionResult.failure('MCP server is unavailable.');
    } finally {
      registration.dispose();
    }
  }
}

bool _validPrefix(String value) =>
    RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(value);

Uri _validateEndpoint(Uri uri) {
  final loopback =
      uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '[::1]';
  if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
    throw const FormatException('Remote MCP endpoints require HTTPS.');
  }
  if (uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw const FormatException(
      'MCP endpoint must not contain credentials or a query.',
    );
  }
  return uri;
}

Map<String, Object?> _agentSchema(Map<String, dynamic> original) {
  Map<String, Object?> prune(Map source) {
    final result = <String, Object?>{};
    for (final entry in source.entries) {
      if (entry.key is! String ||
          !supportedSchemaKeywords.contains(entry.key)) {
        continue;
      }
      final key = entry.key as String;
      final value = entry.value;
      if (key == 'properties' && value is Map) {
        result[key] = {
          for (final property in value.entries)
            if (property.key is String && property.value is Map)
              property.key as String: prune(property.value as Map),
        };
      } else if ((key == 'items' || key == 'additionalProperties') &&
          value is Map) {
        result[key] = prune(value);
      } else {
        result[key] = value;
      }
    }
    return result;
  }

  return prune(original);
}

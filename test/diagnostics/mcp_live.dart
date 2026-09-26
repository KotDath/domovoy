import 'dart:io';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/tools/mcp_remote_tools.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Explicit live check; not discovered by the default test suite.
/// Start both servers, then: flutter test test/diagnostics/mcp_live.dart
void main() {
  test('real DeepSeek agent chooses and chains HTTP MCP tools', () async {
    HttpOverrides.global = null;
    expect(Platform.environment['DEEPSEEK_API_KEY'], isNotEmpty);
    final archive = Uri.parse(
      Platform.environment['ARCHIVE_MCP_URL'] ?? 'http://127.0.0.1:8401/mcp',
    );
    final briefing = Uri.parse(
      Platform.environment['BRIEFING_MCP_URL'] ?? 'http://127.0.0.1:8402/mcp',
    );
    final remote = await McpRemoteTools.connect({
      'archive': archive,
      'briefing': briefing,
    });
    final client = http.Client();
    final stack = buildProductionAgentStack(
      httpClient: client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(),
        readEnvironment: (name) => Platform.environment[name],
      ),
      tools: remote.registry,
      enabledTools: remote.enabled,
      diagnosticNoCompaction: true,
    );
    final definition = AgentDefinition(
      id: AgentId('mcp-live'),
      name: 'MCP live check',
      systemPrompt:
          'Use the available tools for the user request. Do not invent tool results.',
      model: BuiltInLlmCatalog.deepSeekFlashModel.ref,
      enabledTools: remote.enabled,
      policy: PolicyId('allow'),
      limits: AgentRunLimits(maxModelTurns: 12, maxToolCalls: 12),
    );
    final session = await stack.runtime.agent(definition).createSession();
    try {
      final events = await session
          .run(
            'Use archive__archive_search to find 2 Internet Archive items matching '
            'identifier:bigbuckbunny*. Then pass the exact searchResult JSON into '
            'briefing__summarize_items and pass its digest JSON into '
            'briefing__save_digest. Tell me the saved report ID. You must call '
            'all three tools in order; do not merely describe the steps.',
          )
          .events
          .toList()
          .timeout(const Duration(minutes: 3));
      final started = events
          .whereType<AgentToolStarted>()
          .map((event) => event.name)
          .toList();
      final finished = events.whereType<AgentToolFinished>().toList();
      debugPrint('MCP live tool order: $started');
      debugPrint(
        'MCP live tool successes: ${finished.map((event) => event.success).toList()}',
      );
      expect(events.last, isA<AgentRunCompleted>());
      expect(
        started,
        containsAllInOrder([
          'archive__archive_search',
          'briefing__summarize_items',
          'briefing__save_digest',
        ]),
      );
      expect(finished.every((event) => event.success), isTrue);
    } finally {
      await session.close();
      await stack.runtime.close();
      await remote.close();
      client.close();
    }
  });
}

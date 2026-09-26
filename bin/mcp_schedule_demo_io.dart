import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';

/// Day 18 smoke: schedule, wait for the background server, read aggregate result.
Future<void> main(List<String> args) async {
  final endpoint = Uri.parse(
    Platform.environment['BRIEFING_MCP_URL'] ?? 'http://127.0.0.1:8402/mcp',
  );
  final query = args.isEmpty ? 'identifier:bigbuckbunny*' : args.join(' ');
  final client = McpClient(
    const Implementation(name: 'domovoy-schedule-demo', version: '1.0.0'),
    options: const McpClientOptions(protocol: McpProtocol.stable),
  );
  try {
    await client.connect(StreamableHttpClientTransport(endpoint));
    final scheduled = await client.callTool(
      CallToolRequest(
        name: 'schedule_digest',
        arguments: {'query': query, 'intervalSeconds': 2, 'limit': 2},
      ),
    );
    if (scheduled.isError || scheduled.structuredContent == null) {
      throw StateError('Scheduling failed.');
    }
    final id = scheduled.structuredContent!['id'] as String;
    await Future<void>.delayed(const Duration(seconds: 5));
    final reports = await client.callTool(
      CallToolRequest(name: 'list_digests', arguments: {'scheduleId': id}),
    );
    final schedules = await client.callTool(
      const CallToolRequest(name: 'list_schedules', arguments: {}),
    );
    final cancelled = await client.callTool(
      CallToolRequest(name: 'cancel_schedule', arguments: {'scheduleId': id}),
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'schedule': scheduled.structuredContent,
        'reports': reports.structuredContent,
        'schedules': schedules.structuredContent,
        'cancelled': cancelled.structuredContent,
      }),
    );
  } finally {
    await client.close();
  }
}

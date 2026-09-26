import 'dart:convert';
import 'dart:io';

import 'package:domovoy/infrastructure/mcp_servers/demo_flow_io.dart';

Future<void> main(List<String> args) async {
  final archive = Uri.parse(
    Platform.environment['ARCHIVE_MCP_URL'] ?? 'http://127.0.0.1:8401/mcp',
  );
  final briefing = Uri.parse(
    Platform.environment['BRIEFING_MCP_URL'] ?? 'http://127.0.0.1:8402/mcp',
  );
  final query = args.isEmpty
      ? 'mediatype:movies AND subject:animation'
      : args.join(' ');
  final result = await runMcpDemoFlow(
    archiveEndpoint: archive,
    briefingEndpoint: briefing,
    query: query,
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
}

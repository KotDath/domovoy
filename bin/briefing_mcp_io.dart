import 'dart:io';

import 'package:domovoy/infrastructure/mcp_servers/briefing_server_io.dart';
import 'package:domovoy/infrastructure/mcp_servers/briefing_service_io.dart';

Future<void> main() async {
  final host = Platform.environment['MCP_BIND_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(Platform.environment['MCP_PORT'] ?? '') ?? 8402;
  final allowedHosts =
      (Platform.environment['MCP_ALLOWED_HOSTS'] ?? '127.0.0.1,localhost')
          .split(',')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toSet();
  final origins = Platform.environment['MCP_ALLOWED_ORIGINS'];
  final archiveUrl = Uri.parse(
    Platform.environment['ARCHIVE_MCP_URL'] ?? 'http://127.0.0.1:8401/mcp',
  );
  final dataFile = File(
    Platform.environment['BRIEFING_JSONL_PATH'] ?? 'data/briefing.jsonl',
  );
  final source = ArchiveMcpSource(archiveUrl);
  final server = BriefingMcpServer(
    service: BriefingService(dataFile: dataFile, searchArchive: source.search),
    host: host,
    port: port,
    allowedHosts: allowedHosts,
    allowedOrigins: origins?.split(',').map((part) => part.trim()).toSet(),
  );
  await server.start();
  stdout.writeln(
    'Briefing MCP listening on http://$host:${server.boundPort}/mcp',
  );
  await ProcessSignal.sigint.watch().first;
  await server.stop();
}

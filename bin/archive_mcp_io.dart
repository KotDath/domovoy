import 'dart:io';

import 'package:domovoy/infrastructure/mcp_servers/archive_api_io.dart';
import 'package:domovoy/infrastructure/mcp_servers/archive_server_io.dart';
import 'package:domovoy/infrastructure/mcp_servers/archive_task_store_io.dart';

Future<void> main() async {
  final host = Platform.environment['MCP_BIND_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(Platform.environment['MCP_PORT'] ?? '') ?? 8401;
  final allowedHosts =
      (Platform.environment['MCP_ALLOWED_HOSTS'] ?? '127.0.0.1,localhost')
          .split(',')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toSet();
  final origins = Platform.environment['MCP_ALLOWED_ORIGINS'];
  final service = ArchiveMcpService(
    api: ArchiveApi(),
    tasks: ArchiveTaskStore(
      File(
        Platform.environment['ARCHIVE_TASKS_JSONL_PATH'] ??
            'data/archive-tasks.jsonl',
      ),
    ),
    host: host,
    port: port,
    allowedHosts: allowedHosts,
    allowedOrigins: origins?.split(',').map((part) => part.trim()).toSet(),
  );
  await service.start();
  stdout.writeln(
    'Archive MCP listening on http://$host:${service.boundPort}/mcp',
  );
  await ProcessSignal.sigint.watch().first;
  await service.stop();
}

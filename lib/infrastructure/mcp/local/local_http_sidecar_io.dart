import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A desktop MCP endpoint in its own OS process. The child owns the public
/// loopback listener and forwards MCP wire traffic to the app-owned backend.
/// Keeping the backend in the app preserves the single scheduler, secure
/// provider registry, run-scoped model pins and JSONL writer.
final class McpHttpSidecarHandle {
  const McpHttpSidecarHandle({
    required this.url,
    required this.processId,
    required this.stop,
  });

  final Uri url;
  final int processId;
  final Future<void> Function() stop;
}

Future<McpHttpSidecarHandle> launchMcpHttpSidecar({
  required String serverId,
  required Uri backendUrl,
  required String bearerToken,
}) async {
  final executable = Platform.environment['DOMOVOY_MCP_SIDECAR_EXECUTABLE'];
  final String command;
  final List<String> arguments;
  if (executable != null && executable.trim().isNotEmpty) {
    command = executable;
    arguments = const <String>[];
  } else {
    final sibling = File(
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}domovoy_mcp_sidecar'
      '${Platform.isWindows ? '.exe' : ''}',
    );
    if (await sibling.exists()) {
      command = sibling.path;
      arguments = const <String>[];
    } else {
      final script = File(
        '${Directory.current.path}${Platform.pathSeparator}tool'
        '${Platform.pathSeparator}domovoy_mcp_sidecar.dart',
      );
      if (!await script.exists()) {
        throw StateError(
          'Desktop MCP sidecar is unavailable. Put domovoy_mcp_sidecar '
          'beside the app or set DOMOVOY_MCP_SIDECAR_EXECUTABLE.',
        );
      }
      command = 'dart';
      arguments = <String>[script.path];
    }
  }
  final process = await Process.start(
    command,
    arguments,
    workingDirectory: Directory.current.path,
  );
  // The token is sent through the private pipe, never through argv or logs.
  process.stdin.writeln(
    jsonEncode(<String, String>{
      'serverId': serverId,
      'backendUrl': backendUrl.toString(),
      'bearerToken': bearerToken,
    }),
  );
  await process.stdin.flush();
  final stderrDrain = process.stderr.drain<void>();
  try {
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 15));
    final decoded = jsonDecode(line);
    if (decoded is! Map || decoded['serverId'] != serverId) {
      throw const FormatException('Invalid MCP sidecar ready message.');
    }
    final url = Uri.tryParse(decoded['url'] as String? ?? '');
    if (url == null ||
        url.scheme != 'http' ||
        url.host != '127.0.0.1' ||
        url.path != '/mcp' ||
        url.port <= 0) {
      throw const FormatException('Invalid MCP sidecar endpoint.');
    }
    return McpHttpSidecarHandle(
      url: url,
      processId: process.pid,
      stop: () async {
        await process.stdin.close();
        try {
          await process.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill();
          await process.exitCode.timeout(const Duration(seconds: 5));
        }
        await stderrDrain;
      },
    );
  } on Object {
    process.kill();
    await process.exitCode;
    await stderrDrain;
    rethrow;
  }
}

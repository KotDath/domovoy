import 'package:flutter/widgets.dart';

import 'app.dart';
import 'infrastructure/tools/mcp_remote_tools.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const rawServers = String.fromEnvironment('DOMOVOY_MCP_SERVERS');
  McpRemoteTools? remoteTools;
  if (rawServers.isNotEmpty) {
    try {
      remoteTools = await McpRemoteTools.connect(
        McpRemoteTools.parseConfiguration(rawServers),
      );
    } on Object catch (error) {
      debugPrint('MCP connection failed: $error');
    }
  }
  runApp(DomovoyApp.production(remoteTools: remoteTools));
}

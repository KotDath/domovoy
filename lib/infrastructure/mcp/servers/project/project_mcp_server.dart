import '../../../../core/projects/project_run_scope.dart';
import 'dart:convert';
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import '../../../../core/projects/project_context.dart';
import '../../local/local_mcp_definition.dart';

final class ProjectMcpServerFactory implements LocalMcpServerFactory {
  ProjectMcpServerFactory({required this.projects, required this.scopes});
  final ProjectContextService projects;
  final ProjectRunScopes scopes;
  @override
  LocalMcpServerDefinition create() => LocalMcpServerDefinition(
    serverId: 'project',
    displayName: 'Project context',
    version: '1.0.0',
    registerTools: (server) => server.registerTool(
      'git_branch',
      description:
          'Read the selected project’s actual current Git branch and commit. Null branch means detached HEAD. No writes.',
      inputSchema: sdk.ToolInputSchema(
        properties: {},
        additionalProperties: false,
      ),
      annotations: const sdk.ToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: false,
      ),
      callback: (args, extra) async {
        try {
          if (extra.signal.aborted) throw StateError('Cancelled');
          final project = scopes.resolve(
            extra.meta?['domovoy/runScope'] as String?,
          );
          if (project == null) throw StateError('No live project run scope');
          if (args.isNotEmpty) {
            throw const FormatException('No arguments allowed');
          }
          final context = await projects.gitContext(project);
          if (extra.signal.aborted ||
              scopes.resolve(extra.meta?['domovoy/runScope'] as String?) !=
                  project) {
            throw StateError('Project run ended');
          }
          final result = {'project': project.value, ...context.toJson()};
          return sdk.CallToolResult(
            content: [sdk.TextContent(text: jsonEncode(result))],
            structuredContent: result,
          );
        } on Object catch (error) {
          return sdk.CallToolResult(
            isError: true,
            content: [
              sdk.TextContent(text: 'Project Git context unavailable: $error'),
            ],
          );
        }
      },
    ),
  );
}

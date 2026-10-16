import 'dart:math';

import '../agents/run_context.dart';
import '../mcp/ids.dart';
import '../mcp/naming.dart';
import 'ids.dart';

final projectBranchToolId = McpToolNamePolicy().candidate(
  connectionId: McpConnectionId('project'),
  originalToolName: 'git_branch',
);

/// Capabilities come from host composition, never model-authored arguments.
final class ProjectRunScopes {
  final _projects = <String, ProjectId>{};
  final _random = Random.secure();
  AgentRunToolContext begin(ProjectId project) {
    final key = List.generate(
      32,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _projects[key] = project;
    return AgentRunToolContext(scopeKey: key);
  }

  ProjectId? resolve(String? key) => _projects[key];
  bool permits(AgentRunToolContext? context, ProjectId? project) =>
      context != null &&
      project != null &&
      resolve(context.scopeKey) == project;
  void end(AgentRunToolContext context) => _projects.remove(context.scopeKey);
}

import 'package:path/path.dart' as p;

import '../../core/agents/agents.dart';
import '../../core/llm/cancellation.dart';
import '../tools/local_workspace_executor_io.dart';
import 'project_sources_io.dart';

/// Enforced independently of the prompt and of the advertised tool list.
final class ReadOnlyWorkspaceExecutor implements AgentToolExecutor {
  ReadOnlyWorkspaceExecutor({required this.root, required this.allowedPaths})
    : delegate = LocalWorkspaceToolExecutor(resolveRoot: (_) async => root);
  final String root;
  final Set<String> allowedPaths;
  final LocalWorkspaceToolExecutor delegate;

  @override
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  }) async {
    final path = invocation.arguments['path'];
    if (invocation.name != 'read' ||
        path is! String ||
        !ProjectSourcePolicy.permits(path) ||
        !allowedPaths.contains(path) ||
        p.posix.normalize(path) != path) {
      return ToolExecutionResult.failure('Read-only source access denied.');
    }
    return delegate.execute(
      invocation,
      cancellation: cancellation,
      liveness: liveness,
    );
  }
}

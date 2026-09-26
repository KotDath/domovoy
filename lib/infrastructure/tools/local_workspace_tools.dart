import '../../core/agents/agents.dart';
import '../projects/project_platform_stack.dart';
import 'local_workspace_tools_stub.dart'
    if (dart.library.io) 'local_workspace_tools_io.dart'
    if (dart.library.js_interop) 'local_workspace_tools_web.dart'
    as platform;

final class LocalWorkspaceTools {
  const LocalWorkspaceTools({required this.registry, required this.enabled});

  final AgentToolRegistry registry;
  final List<ToolId> enabled;
}

LocalWorkspaceTools createLocalWorkspaceTools(ProjectPlatformStack projects) =>
    platform.createLocalWorkspaceTools(projects);

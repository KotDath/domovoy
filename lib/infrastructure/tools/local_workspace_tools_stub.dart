import '../../core/agents/agents.dart';
import '../projects/project_platform_stack.dart';
import 'local_workspace_tools.dart';

LocalWorkspaceTools createLocalWorkspaceTools(ProjectPlatformStack projects) =>
    LocalWorkspaceTools(registry: AgentToolRegistry(), enabled: const []);

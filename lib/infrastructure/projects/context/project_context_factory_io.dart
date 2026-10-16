import '../../../core/projects/project_context.dart';
import '../../tools/local_workspace_tools_io.dart';
import '../project_platform_stack.dart';
import 'local_project_context_io.dart';

ProjectContextService createProjectContextService(
  ProjectPlatformStack projects,
) => LocalProjectContextService(
  resolveRoot: ProjectWorkspaceRootResolver(projects).resolve,
);

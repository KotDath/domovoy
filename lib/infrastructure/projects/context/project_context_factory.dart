import '../../../core/projects/project_context.dart';
import '../project_platform_stack.dart';
import 'project_context_factory_stub.dart'
    if (dart.library.io) 'project_context_factory_io.dart'
    as platform;

ProjectContextService? createProjectContextService(
  ProjectPlatformStack projects,
) => platform.createProjectContextService(projects);

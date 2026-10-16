import 'dart:io';

import '../../../core/projects/project_context.dart';
import '../../../core/projects/record.dart';
import '../../tools/local_workspace_tools_io.dart';
import '../project_platform_stack.dart';
import 'local_project_context_io.dart';
import 'host_git_object_verifier_io.dart';

ProjectContextService createProjectContextService(
  ProjectPlatformStack projects,
) => LocalProjectContextService(
  resolveRoot: ProjectWorkspaceRootResolver(projects).resolve,
  selectGitVerifier: (project) async =>
      (Platform.isLinux || Platform.isMacOS || Platform.isWindows) &&
          (await projects.repository.load(project))?.root
              is ExternalGrantRootReference
      ? const HostGitObjectVerifier()
      : null,
);

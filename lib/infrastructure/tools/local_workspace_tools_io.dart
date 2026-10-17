import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/agents/agents.dart';
import '../../core/projects/enums.dart';
import '../../core/projects/ids.dart';
import '../../core/projects/record.dart';
import '../projects/grants/file_grant_store.dart';
import '../projects/project_platform_stack.dart';
import 'local_workspace_tools.dart';

import 'local_workspace_executor_io.dart';
export 'local_workspace_executor_io.dart';

LocalWorkspaceTools createLocalWorkspaceTools(ProjectPlatformStack projects) {
  final registry = AgentToolRegistry();
  if (Platform.isIOS) {
    return LocalWorkspaceTools(registry: registry, enabled: const []);
  }
  final roots = ProjectWorkspaceRootResolver(projects);
  final executor = LocalWorkspaceToolExecutor(
    resolveRoot: roots.resolve,
    resolveWritableRoot: (id) => roots.resolve(id, write: true),
  );
  for (final descriptor in WorkspaceFileTools.descriptors) {
    registry.register(AgentTool(descriptor: descriptor, executor: executor));
  }
  return LocalWorkspaceTools(
    registry: registry,
    enabled: WorkspaceFileTools.ids,
  );
}

/// Resolves a project's current local root on each invocation. A saved project
/// record or grant alone is insufficient: its access can be revoked or stale.
final class ProjectWorkspaceRootResolver {
  const ProjectWorkspaceRootResolver(this.projects);

  final ProjectPlatformStack projects;

  Future<String> resolve(ProjectId projectId, {bool write = false}) async {
    final record = await projects.repository.load(projectId);
    if (record == null || !record.isActive) {
      throw const FileSystemException('Project is not active.');
    }
    final root = record.root;
    if (root is AppSandboxRootReference) {
      final status = await projects.provisioner.revalidateRoot(
        rootId: root.rootId,
        projectId: projectId,
      );
      if (status != ProjectAccessStatus.active) {
        throw const FileSystemException('Project workspace is unavailable.');
      }
      final support = await getApplicationSupportDirectory();
      final nativePath = p.join(
        await support.resolveSymbolicLinks(),
        'project-sandbox-roots-v1',
        projectId.value,
      );
      return _requireRealDirectory(nativePath);
    }
    if (root is ExternalGrantRootReference) {
      final status = await projects.provisioner.revalidateRoot(
        grantId: root.grantId,
        projectId: projectId,
      );
      if (status != ProjectAccessStatus.active) {
        throw const FileSystemException('Project workspace is unavailable.');
      }
      final grantStore = projects.grants;
      if (grantStore is! FileProjectDirectoryGrantStore) {
        throw const FileSystemException('Project grant is unavailable.');
      }
      final descriptor = await grantStore.revalidate(root.grantId);
      if (descriptor.projectId != projectId ||
          descriptor.role != DirectoryGrantRole.root ||
          (write &&
              descriptor.requestedAccess != DirectoryGrantAccess.readWrite)) {
        throw const FileSystemException('Project root is not writable.');
      }
      final nativePath = grantStore.nativePathFor(root.grantId);
      if (nativePath == null) {
        throw const FileSystemException('Project grant is unavailable.');
      }
      return _requireRealDirectory(nativePath);
    }
    throw const FileSystemException('Project workspace is unsupported.');
  }
}

Future<String> _requireRealDirectory(String path) async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException('Project workspace is unavailable.');
  }
  final resolved = await Directory(path).resolveSymbolicLinks();
  if (p.normalize(resolved) != p.normalize(p.absolute(path))) {
    throw const FileSystemException('Project workspace is unavailable.');
  }
  return resolved;
}

import '../../../core/llm/cancellation.dart';
import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/identity.dart';
import '../../../core/projects/provisioning.dart';
import '../fs/filesystem_ops.dart';

final class WebUnsupportedProjectRootProvisioner
    implements ProjectRootProvisioner {
  WebUnsupportedProjectRootProvisioner();

  @override
  final ProjectPlatformCapabilities capabilities =
      ProjectPlatformCapabilities.web;

  final ProjectFilesystemOpLog opLog = ProjectFilesystemOpLog();
  int stageCalls = 0;
  int writeCount = 0;
  int grantStoreCalls = 0;

  @override
  Future<ProjectRootProvisionResult> stageRoot({
    DesktopRootProvisionRequest? desktop,
    MobileSandboxProvisionRequest? mobile,
    required CancellationToken cancellation,
  }) async {
    stageCalls += 1;
    return const UnsupportedRootResult();
  }

  @override
  Future<void> acknowledgeRoot(ProjectRootProvisionResult staged) async {
    throw ProjectException(sanitizedProjectUnsupportedError());
  }

  @override
  Future<ProjectAccessStatus> revalidateRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
    required ProjectId projectId,
    DirectoryGrantRole expectedRole = DirectoryGrantRole.root,
    DirectoryGrantAccess expectedAccess = DirectoryGrantAccess.readWrite,
  }) async {
    return ProjectAccessStatus.unsupported;
  }

  @override
  Future<void> retireRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
    required ProjectId projectId,
  }) async {}

  @override
  Future<OrphanCleanupResult> cleanupOrphan(
    OrphanRootCleanupRequest request,
  ) async {
    return const OrphanCleanupResult(outcome: OrphanCleanupOutcome.retained);
  }

  @override
  CanonicalDirectoryIdentity? identityForRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
  }) {
    return null;
  }
}

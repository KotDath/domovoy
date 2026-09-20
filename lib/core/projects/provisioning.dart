import '../llm/cancellation.dart';
import 'enums.dart';
import 'grants.dart';
import 'ids.dart';
import 'identity.dart';

final class ProjectPlatformCapabilities {
  const ProjectPlatformCapabilities({
    required this.platformKind,
    required this.projectCreationSupported,
    required this.desktopExternalRoots,
    required this.mobileSandboxRoots,
    required this.appManagedSandboxRoots,
    required this.additionalDirectories,
    required this.regrantSupported,
    required this.pickerSupported,
  });

  final ProjectPlatformKind platformKind;
  final bool projectCreationSupported;
  final bool desktopExternalRoots;
  final bool mobileSandboxRoots;

  /// Whether the application can create its own support-directory sandbox root
  /// for the protected default project without a user filesystem grant.
  final bool appManagedSandboxRoots;
  final bool additionalDirectories;
  final bool regrantSupported;
  final bool pickerSupported;

  static const linux = ProjectPlatformCapabilities(
    platformKind: ProjectPlatformKind.linux,
    projectCreationSupported: true,
    desktopExternalRoots: true,
    mobileSandboxRoots: false,
    appManagedSandboxRoots: true,
    additionalDirectories: true,
    regrantSupported: true,
    pickerSupported: true,
  );

  static const windows = ProjectPlatformCapabilities(
    platformKind: ProjectPlatformKind.windows,
    projectCreationSupported: true,
    desktopExternalRoots: true,
    mobileSandboxRoots: false,
    appManagedSandboxRoots: true,
    additionalDirectories: true,
    regrantSupported: true,
    pickerSupported: true,
  );

  static const macos = ProjectPlatformCapabilities(
    platformKind: ProjectPlatformKind.macos,
    projectCreationSupported: true,
    desktopExternalRoots: true,
    mobileSandboxRoots: false,
    appManagedSandboxRoots: true,
    additionalDirectories: true,
    regrantSupported: true,
    pickerSupported: true,
  );

  static const android = ProjectPlatformCapabilities(
    platformKind: ProjectPlatformKind.android,
    projectCreationSupported: true,
    desktopExternalRoots: false,
    mobileSandboxRoots: true,
    appManagedSandboxRoots: true,
    additionalDirectories: false,
    regrantSupported: false,
    pickerSupported: false,
  );

  static const ios = ProjectPlatformCapabilities(
    platformKind: ProjectPlatformKind.ios,
    projectCreationSupported: true,
    desktopExternalRoots: false,
    mobileSandboxRoots: true,
    appManagedSandboxRoots: true,
    additionalDirectories: false,
    regrantSupported: false,
    pickerSupported: false,
  );

  static const web = ProjectPlatformCapabilities(
    platformKind: ProjectPlatformKind.web,
    projectCreationSupported: false,
    desktopExternalRoots: false,
    mobileSandboxRoots: false,
    appManagedSandboxRoots: false,
    additionalDirectories: false,
    regrantSupported: false,
    pickerSupported: false,
  );
}

sealed class ProjectRootProvisionResult {
  const ProjectRootProvisionResult();
}

final class DesktopExternalRootResult extends ProjectRootProvisionResult {
  const DesktopExternalRootResult({
    required this.root,
    this.additional = const <StagedDesktopGrant>[],
  });

  final StagedDesktopGrant root;
  final List<StagedDesktopGrant> additional;
}

final class MobileSandboxRootResult extends ProjectRootProvisionResult {
  const MobileSandboxRootResult({
    required this.descriptor,
    required this.identity,
    required this.createdNewDirectory,
  });

  final SandboxRootDescriptor descriptor;
  final CanonicalDirectoryIdentity identity;
  final bool createdNewDirectory;
}

final class UnsupportedRootResult extends ProjectRootProvisionResult {
  const UnsupportedRootResult();
}

final class ProjectPickedDirectory {
  const ProjectPickedDirectory({
    required this.handleId,
    required this.safeLabel,
  });

  final String handleId;
  final String safeLabel;
}

enum ProjectPickerKind { existingRoot, parentDirectory, additionalDirectory }

abstract interface class ProjectDirectoryPicker {
  Future<ProjectPickedDirectory?> pick(ProjectPickerKind kind);
}

final class DesktopRootProvisionRequest {
  const DesktopRootProvisionRequest({
    required this.projectId,
    required this.grantId,
    required this.mode,
    required this.folderName,
    this.additionalGrantIds = const <DirectoryGrantId>[],
  });

  final ProjectId projectId;
  final DirectoryGrantId grantId;
  final ProjectDesktopRootMode mode;
  final String folderName;
  final List<DirectoryGrantId> additionalGrantIds;
}

final class MobileSandboxProvisionRequest {
  const MobileSandboxProvisionRequest({
    required this.projectId,
    required this.rootId,
  });

  final ProjectId projectId;
  final ProjectRootId rootId;
}

final class OrphanRootCleanupRequest {
  const OrphanRootCleanupRequest({
    required this.projectId,
    required this.identity,
    required this.createdNewDirectory,
  });

  final ProjectId projectId;
  final CanonicalDirectoryIdentity identity;
  final bool createdNewDirectory;
}

enum OrphanCleanupOutcome { removed, retained, quarantined }

final class OrphanCleanupResult {
  const OrphanCleanupResult({required this.outcome, this.warning = false});

  final OrphanCleanupOutcome outcome;
  final bool warning;
}

abstract interface class ProjectRootProvisioner {
  ProjectPlatformCapabilities get capabilities;

  Future<ProjectRootProvisionResult> stageRoot({
    DesktopRootProvisionRequest? desktop,
    MobileSandboxProvisionRequest? mobile,
    required CancellationToken cancellation,
  });

  Future<void> acknowledgeRoot(ProjectRootProvisionResult staged);

  Future<ProjectAccessStatus> revalidateRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
    required ProjectId projectId,
    DirectoryGrantRole expectedRole = DirectoryGrantRole.root,
    DirectoryGrantAccess expectedAccess = DirectoryGrantAccess.readWrite,
  });

  Future<void> retireRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
    required ProjectId projectId,
  });

  Future<OrphanCleanupResult> cleanupOrphan(OrphanRootCleanupRequest request);

  CanonicalDirectoryIdentity? identityForRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
  });
}

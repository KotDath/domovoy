import 'enums.dart';
import 'errors.dart';
import 'ids.dart';
import 'identity.dart';

final class DesktopGrantDescriptor {
  const DesktopGrantDescriptor({
    required this.grantId,
    required this.projectId,
    required this.role,
    required this.requestedAccess,
    required this.origin,
    required this.safeDisplayLabel,
    required this.canonicalFingerprint,
    required this.platformKind,
    required this.createdAtMicros,
    required this.updatedAtMicros,
    required this.status,
  });

  final DirectoryGrantId grantId;
  final ProjectId projectId;
  final DirectoryGrantRole role;
  final DirectoryGrantAccess requestedAccess;
  final DirectoryGrantOrigin origin;
  final String safeDisplayLabel;
  final String canonicalFingerprint;
  final ProjectPlatformKind platformKind;
  final int createdAtMicros;
  final int updatedAtMicros;
  final ProjectAccessStatus status;

  bool get isActive => status == ProjectAccessStatus.active;

  DesktopGrantDescriptor withStatus(ProjectAccessStatus next) {
    return DesktopGrantDescriptor(
      grantId: grantId,
      projectId: projectId,
      role: role,
      requestedAccess: requestedAccess,
      origin: origin,
      safeDisplayLabel: safeDisplayLabel,
      canonicalFingerprint: canonicalFingerprint,
      platformKind: platformKind,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros,
      status: next,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopGrantDescriptor &&
          other.grantId == grantId &&
          other.projectId == projectId &&
          other.role == role &&
          other.requestedAccess == requestedAccess &&
          other.origin == origin &&
          other.safeDisplayLabel == safeDisplayLabel &&
          other.canonicalFingerprint == canonicalFingerprint &&
          other.platformKind == platformKind &&
          other.createdAtMicros == createdAtMicros &&
          other.updatedAtMicros == updatedAtMicros &&
          other.status == status;

  @override
  int get hashCode => Object.hash(
    grantId,
    projectId,
    role,
    requestedAccess,
    origin,
    safeDisplayLabel,
    canonicalFingerprint,
    platformKind,
    createdAtMicros,
    updatedAtMicros,
    status,
  );
}

final class SandboxRootDescriptor {
  const SandboxRootDescriptor({
    required this.rootId,
    required this.projectId,
    required this.platformKind,
    required this.canonicalRelativeIdentity,
    required this.status,
  });

  final ProjectRootId rootId;
  final ProjectId projectId;
  final ProjectPlatformKind platformKind;
  final String canonicalRelativeIdentity;
  final ProjectAccessStatus status;

  bool get isActive => status == ProjectAccessStatus.active;

  SandboxRootDescriptor withStatus(ProjectAccessStatus next) {
    return SandboxRootDescriptor(
      rootId: rootId,
      projectId: projectId,
      platformKind: platformKind,
      canonicalRelativeIdentity: canonicalRelativeIdentity,
      status: next,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SandboxRootDescriptor &&
          other.rootId == rootId &&
          other.projectId == projectId &&
          other.platformKind == platformKind &&
          other.canonicalRelativeIdentity == canonicalRelativeIdentity &&
          other.status == status;

  @override
  int get hashCode => Object.hash(
    rootId,
    projectId,
    platformKind,
    canonicalRelativeIdentity,
    status,
  );
}

final class StagedDesktopGrant {
  const StagedDesktopGrant({
    required this.descriptor,
    required this.identity,
    required this.createdNewDirectory,
  });

  final DesktopGrantDescriptor descriptor;
  final CanonicalDirectoryIdentity identity;
  final bool createdNewDirectory;
}

final class OrphanGrantRecord {
  const OrphanGrantRecord({
    required this.grantId,
    required this.projectId,
    required this.origin,
    required this.fingerprint,
  });

  final DirectoryGrantId grantId;
  final ProjectId projectId;
  final DirectoryGrantOrigin origin;
  final String fingerprint;
}

abstract interface class ProjectDirectoryGrantStore {
  Future<void> acknowledge(StagedDesktopGrant staged);

  Future<DesktopGrantDescriptor> revalidate(DirectoryGrantId grantId);

  Future<DesktopGrantDescriptor> regrant({
    required DirectoryGrantId grantId,
    required ProjectId projectId,
    required CanonicalDirectoryIdentity expectedIdentity,
  });

  Future<void> revoke(DirectoryGrantId grantId);

  Future<List<OrphanGrantRecord>> enumerateOrphans();

  CanonicalDirectoryIdentity? identityFor(DirectoryGrantId grantId);
}

Never denyOpaqueGrantMaterial() {
  throwProject(
    ProjectErrorKind.configuration,
    'Native grant material is not available through Project contracts.',
  );
}

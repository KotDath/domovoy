import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/grants.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/identity.dart';

final class InMemoryProjectDirectoryGrantStore
    implements ProjectDirectoryGrantStore {
  InMemoryProjectDirectoryGrantStore({
    this.revalidateStatus,
    this.failClosed = false,
  });

  final Map<String, _StoredGrant> _grants = <String, _StoredGrant>{};
  ProjectAccessStatus? revalidateStatus;
  bool failClosed;
  int acknowledgeCount = 0;
  int revokeCount = 0;
  int regrantCount = 0;
  final List<String> leakedLogs = <String>[];

  void seed(StagedDesktopGrant staged, {String? opaqueMaterial}) {
    _grants[staged.descriptor.grantId.value] = _StoredGrant(
      staged: staged,
      opaqueMaterial: opaqueMaterial ?? 'opaque-not-for-codecs',
    );
  }

  @override
  Future<void> acknowledge(StagedDesktopGrant staged) async {
    acknowledgeCount += 1;
    if (failClosed) {
      throw ProjectException(sanitizedProjectPersistenceError());
    }
    _grants[staged.descriptor.grantId.value] = _StoredGrant(
      staged: staged,
      opaqueMaterial: 'opaque-not-for-codecs',
    );
  }

  @override
  Future<DesktopGrantDescriptor> revalidate(DirectoryGrantId grantId) async {
    final stored = _grants[grantId.value];
    if (stored == null) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    if (failClosed) {
      return stored.staged.descriptor.withStatus(
        ProjectAccessStatus.unverifiable,
      );
    }
    final status = revalidateStatus ?? ProjectAccessStatus.active;
    final next = stored.staged.descriptor.withStatus(status);
    _grants[grantId.value] = _StoredGrant(
      staged: StagedDesktopGrant(
        descriptor: next,
        identity: stored.staged.identity,
        createdNewDirectory: stored.staged.createdNewDirectory,
      ),
      opaqueMaterial: stored.opaqueMaterial,
    );
    return next;
  }

  @override
  Future<DesktopGrantDescriptor> regrant({
    required DirectoryGrantId grantId,
    required ProjectId projectId,
    required CanonicalDirectoryIdentity expectedIdentity,
  }) async {
    regrantCount += 1;
    final stored = _grants[grantId.value];
    if (stored == null || stored.staged.descriptor.projectId != projectId) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    if (stored.staged.identity.fingerprint != expectedIdentity.fingerprint) {
      throw ProjectException(sanitizedProjectCollisionError());
    }
    if (failClosed) {
      throw ProjectException(sanitizedProjectAccessError());
    }
    final next = stored.staged.descriptor.withStatus(
      ProjectAccessStatus.active,
    );
    _grants[grantId.value] = _StoredGrant(
      staged: StagedDesktopGrant(
        descriptor: next,
        identity: expectedIdentity,
        createdNewDirectory: stored.staged.createdNewDirectory,
      ),
      opaqueMaterial: stored.opaqueMaterial,
    );
    return next;
  }

  @override
  Future<void> revoke(DirectoryGrantId grantId) async {
    revokeCount += 1;
    _grants.remove(grantId.value);
  }

  @override
  Future<List<OrphanGrantRecord>> enumerateOrphans() async {
    return [
      for (final grant in _grants.values)
        OrphanGrantRecord(
          grantId: grant.staged.descriptor.grantId,
          projectId: grant.staged.descriptor.projectId,
          origin: grant.staged.descriptor.origin,
          fingerprint: grant.staged.identity.fingerprint,
        ),
    ];
  }

  @override
  CanonicalDirectoryIdentity? identityFor(DirectoryGrantId grantId) {
    return _grants[grantId.value]?.staged.identity;
  }

  String? debugOpaqueMaterial(DirectoryGrantId grantId) {
    return _grants[grantId.value]?.opaqueMaterial;
  }
}

final class _StoredGrant {
  const _StoredGrant({required this.staged, required this.opaqueMaterial});

  final StagedDesktopGrant staged;
  final String opaqueMaterial;
}

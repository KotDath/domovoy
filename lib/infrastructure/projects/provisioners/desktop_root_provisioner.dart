import '../../../core/llm/cancellation.dart';
import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/grants.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/identity.dart';
import '../../../core/projects/policy.dart';
import '../../../core/projects/provisioning.dart';
import '../fs/desktop_filesystem.dart';
import '../grants/macos_security_scope.dart';
import 'mobile_sandbox_provisioner.dart';

final class DesktopProjectRootProvisioner implements ProjectRootProvisioner {
  DesktopProjectRootProvisioner({
    required this.capabilities,
    required this.filesystem,
    required this.picker,
    required this.grantStore,
    this.sandbox,
    this.macosScope,
    this.nowMicros,
  }) : assert(
         capabilities.desktopExternalRoots,
         'Desktop provisioner requires desktop capabilities.',
       );

  @override
  final ProjectPlatformCapabilities capabilities;
  final DesktopFilesystem filesystem;
  final ProjectDirectoryPicker picker;
  final ProjectDirectoryGrantStore grantStore;

  /// Optional application-managed sandbox used to provision the protected
  /// default project without a user filesystem grant.
  final MobileProjectSandbox? sandbox;
  final MacosSecurityScopeBroker? macosScope;
  final int Function()? nowMicros;

  final Map<String, CanonicalDirectoryIdentity> _stagedIdentities =
      <String, CanonicalDirectoryIdentity>{};
  final Map<String, CanonicalDirectoryIdentity> _sandboxIdentities =
      <String, CanonicalDirectoryIdentity>{};
  final Map<String, String> _macosBookmarks = <String, String>{};
  int stageCount = 0;
  int acknowledgeCount = 0;
  int writeCount = 0;

  int _now() => nowMicros?.call() ?? DateTime.now().microsecondsSinceEpoch;

  @override
  Future<ProjectRootProvisionResult> stageRoot({
    DesktopRootProvisionRequest? desktop,
    MobileSandboxProvisionRequest? mobile,
    required CancellationToken cancellation,
  }) async {
    if (mobile != null) {
      if (desktop != null) {
        throwProject(
          ProjectErrorKind.configuration,
          'Desktop provisioner accepts one root request at a time.',
        );
      }
      return _stageSandbox(mobile, cancellation);
    }
    if (desktop == null) {
      throwProject(
        ProjectErrorKind.configuration,
        'Desktop root request is required.',
      );
    }
    _throwIfCancelled(cancellation);
    if (capabilities.platformKind == ProjectPlatformKind.macos) {
      final scope = macosScope;
      if (scope == null || !scope.isAvailable) {
        failClosedWithoutMacosScope();
      }
    }
    stageCount += 1;
    StagedDesktopGrant? root;
    final additional = <StagedDesktopGrant>[];
    try {
      root = await _stageOne(
        request: desktop,
        grantId: desktop.grantId,
        role: DirectoryGrantRole.root,
        access: DirectoryGrantAccess.readWrite,
        pickerKind: desktop.mode == ProjectDesktopRootMode.attachExisting
            ? ProjectPickerKind.existingRoot
            : ProjectPickerKind.parentDirectory,
        cancellation: cancellation,
      );
      final seen = <CanonicalDirectoryIdentity>[root.identity];
      for (final extraId in desktop.additionalGrantIds) {
        _throwIfCancelled(cancellation);
        final extra = await _stageOne(
          request: desktop,
          grantId: extraId,
          role: DirectoryGrantRole.additional,
          access: DirectoryGrantAccess.readOnly,
          pickerKind: ProjectPickerKind.additionalDirectory,
          cancellation: cancellation,
        );
        assertNoDesktopOverlap(candidate: extra.identity, existing: seen);
        seen.add(extra.identity);
        additional.add(extra);
      }
      return DesktopExternalRootResult(root: root, additional: additional);
    } on Object {
      if (root != null && root.createdNewDirectory) {
        try {
          await filesystem.deleteIfEmpty(root.identity);
        } on Object {
          // Conservative: retain a non-empty or unverifiable directory.
        }
      }
      rethrow;
    }
  }

  Future<ProjectRootProvisionResult> _stageSandbox(
    MobileSandboxProvisionRequest mobile,
    CancellationToken cancellation,
  ) async {
    final sandbox = this.sandbox;
    if (sandbox == null || !capabilities.appManagedSandboxRoots) {
      throw ProjectException(sanitizedProjectUnsupportedError());
    }
    _throwIfCancelled(cancellation);
    if (await sandbox.rootExists(mobile.projectId)) {
      throw ProjectException(sanitizedProjectCollisionError());
    }
    final identity = await sandbox.createRoot(mobile.projectId);
    _sandboxIdentities[mobile.rootId.value] = identity;
    return MobileSandboxRootResult(
      descriptor: SandboxRootDescriptor(
        rootId: mobile.rootId,
        projectId: mobile.projectId,
        platformKind: capabilities.platformKind,
        canonicalRelativeIdentity: mobile.projectId.value,
        status: ProjectAccessStatus.active,
      ),
      identity: identity,
      createdNewDirectory: true,
    );
  }

  Future<StagedDesktopGrant> _stageOne({
    required DesktopRootProvisionRequest request,
    required DirectoryGrantId grantId,
    required DirectoryGrantRole role,
    required DirectoryGrantAccess access,
    required ProjectPickerKind pickerKind,
    required CancellationToken cancellation,
  }) async {
    final picked = await picker.pick(pickerKind);
    _throwIfCancelled(cancellation);
    if (picked == null) {
      throwProject(ProjectErrorKind.cancelled, 'cancelled');
    }
    final path = _pathForHandle(picked.handleId);
    final inspected = await filesystem.inspect(path);
    if (!inspected.isUsableRoot) {
      throw ProjectException(sanitizedProjectDeniedError());
    }
    late final CanonicalDirectoryIdentity identity;
    late final bool created;
    if (role == DirectoryGrantRole.root &&
        request.mode == ProjectDesktopRootMode.createExclusive &&
        pickerKind == ProjectPickerKind.parentDirectory) {
      writeCount += 1;
      identity = await filesystem.createExclusiveChild(
        parent: inspected,
        folderName: request.folderName,
      );
      created = true;
    } else {
      identity = await filesystem.canonicalize(path);
      created = false;
    }
    if (!identity.isUsableRoot) {
      throw ProjectException(sanitizedProjectDeniedError());
    }
    if (capabilities.platformKind == ProjectPlatformKind.macos) {
      final scope = macosScope!;
      final bookmark = await scope.createBookmark(
        handleId: filesystem is FakeDesktopFilesystem
            ? picked.handleId
            : filesystem.pathForIdentity(identity),
        fingerprint: identity.fingerprint,
      );
      if (bookmark == null || bookmark.isEmpty) {
        failClosedWithoutMacosScope();
      }
      _macosBookmarks[grantId.value] = bookmark;
    }
    final now = _now();
    final descriptor = DesktopGrantDescriptor(
      grantId: grantId,
      projectId: request.projectId,
      role: role,
      requestedAccess: access,
      origin: created
          ? DirectoryGrantOrigin.created
          : DirectoryGrantOrigin.attached,
      safeDisplayLabel: picked.safeLabel,
      canonicalFingerprint: identity.fingerprint,
      platformKind: capabilities.platformKind,
      createdAtMicros: now,
      updatedAtMicros: now,
      status: ProjectAccessStatus.missing,
    );
    _stagedIdentities[grantId.value] = identity;
    return StagedDesktopGrant(
      descriptor: descriptor,
      identity: identity,
      createdNewDirectory: created,
    );
  }

  @override
  Future<void> acknowledgeRoot(ProjectRootProvisionResult staged) async {
    if (staged is MobileSandboxRootResult) {
      acknowledgeCount += 1;
      return;
    }
    if (staged is! DesktopExternalRootResult) {
      throwProject(
        ProjectErrorKind.configuration,
        'Desktop provisioner cannot acknowledge a non-desktop root.',
      );
    }
    acknowledgeCount += 1;
    for (final grant in <StagedDesktopGrant>[
      staged.root,
      ...staged.additional,
    ]) {
      await grantStore.acknowledge(grant);
      if (capabilities.platformKind == ProjectPlatformKind.macos) {
        final bookmark = _macosBookmarks[grant.descriptor.grantId.value];
        if (bookmark == null) {
          failClosedWithoutMacosScope();
        }
      }
    }
  }

  @override
  Future<ProjectAccessStatus> revalidateRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
    required ProjectId projectId,
    DirectoryGrantRole expectedRole = DirectoryGrantRole.root,
    DirectoryGrantAccess expectedAccess = DirectoryGrantAccess.readWrite,
  }) async {
    if (rootId != null) {
      return _revalidateSandbox(rootId: rootId, projectId: projectId);
    }
    if (grantId == null) {
      return ProjectAccessStatus.unverifiable;
    }
    try {
      final descriptor = await grantStore.revalidate(grantId);
      if (descriptor.grantId != grantId ||
          descriptor.projectId != projectId ||
          descriptor.role != expectedRole ||
          descriptor.requestedAccess != expectedAccess ||
          descriptor.platformKind != capabilities.platformKind) {
        return ProjectAccessStatus.unverifiable;
      }
      if (descriptor.status != ProjectAccessStatus.active) {
        return descriptor.status;
      }
      final identity = grantStore.identityFor(grantId);
      if (identity == null ||
          !identity.isUsableRoot ||
          descriptor.canonicalFingerprint != identity.fingerprint) {
        return ProjectAccessStatus.unverifiable;
      }
      late final CanonicalDirectoryIdentity current;
      try {
        if (capabilities.platformKind == ProjectPlatformKind.macos) {
          final scope = macosScope;
          if (scope == null || !scope.isAvailable) {
            return ProjectAccessStatus.unverifiable;
          }
          var bookmark = _macosBookmarks[grantId.value];
          bookmark ??= scope.bookmarkForFingerprint(identity.fingerprint);
          if (bookmark == null || bookmark.isEmpty) {
            return ProjectAccessStatus.missing;
          }
          final restored = await scope.restoreBookmark(bookmark);
          if (restored.status != ProjectAccessStatus.active) {
            return restored.status;
          }
          final restoredPath = restored.path;
          if (restoredPath == null || restoredPath.isEmpty) {
            return ProjectAccessStatus.unverifiable;
          }
          current = await filesystem.canonicalize(_pathForHandle(restoredPath));
        } else {
          if (!await filesystem.exists(identity)) {
            return ProjectAccessStatus.missing;
          }
          current = await filesystem.revalidateIdentity(identity);
        }
      } on ProjectException {
        return ProjectAccessStatus.unverifiable;
      }
      if (current.fingerprint != identity.fingerprint ||
          !current.isUsableRoot ||
          !await filesystem.hasAccess(current, expectedAccess)) {
        return ProjectAccessStatus.unverifiable;
      }
      return ProjectAccessStatus.active;
    } on ProjectException catch (error) {
      if (error.error.kind == ProjectErrorKind.accessUnavailable) {
        return ProjectAccessStatus.missing;
      }
      return ProjectAccessStatus.unverifiable;
    }
  }

  Future<ProjectAccessStatus> _revalidateSandbox({
    required ProjectRootId rootId,
    required ProjectId projectId,
  }) async {
    final sandbox = this.sandbox;
    if (sandbox == null || !capabilities.appManagedSandboxRoots) {
      return ProjectAccessStatus.unsupported;
    }
    final identity = await sandbox.currentRoot(projectId);
    if (identity == null) {
      return ProjectAccessStatus.missing;
    }
    final known = _sandboxIdentities[rootId.value];
    if (known != null && known.fingerprint != identity.fingerprint) {
      return ProjectAccessStatus.unverifiable;
    }
    _sandboxIdentities[rootId.value] = identity;
    return ProjectAccessStatus.active;
  }

  @override
  Future<void> retireRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
    required ProjectId projectId,
  }) async {
    if (rootId != null) {
      _sandboxIdentities.remove(rootId.value);
      return;
    }
    if (grantId == null) {
      return;
    }
    final bookmark = _macosBookmarks.remove(grantId.value);
    if (bookmark != null) {
      await macosScope?.revokeBookmark(bookmark);
    }
    await grantStore.revoke(grantId);
    _stagedIdentities.remove(grantId.value);
  }

  @override
  Future<OrphanCleanupResult> cleanupOrphan(
    OrphanRootCleanupRequest request,
  ) async {
    final sandbox = this.sandbox;
    if (sandbox != null &&
        _sandboxIdentities.values.any(
          (identity) => identity.fingerprint == request.identity.fingerprint,
        )) {
      return _cleanupSandboxOrphan(sandbox, request);
    }
    if (!request.createdNewDirectory) {
      return const OrphanCleanupResult(outcome: OrphanCleanupOutcome.retained);
    }
    try {
      if (!await filesystem.exists(request.identity)) {
        return const OrphanCleanupResult(outcome: OrphanCleanupOutcome.removed);
      }
      if (!await filesystem.isEmpty(request.identity)) {
        return const OrphanCleanupResult(
          outcome: OrphanCleanupOutcome.retained,
          warning: true,
        );
      }
      writeCount += 1;
      await filesystem.deleteIfEmpty(request.identity);
      return const OrphanCleanupResult(outcome: OrphanCleanupOutcome.removed);
    } on ProjectException {
      return const OrphanCleanupResult(
        outcome: OrphanCleanupOutcome.quarantined,
        warning: true,
      );
    }
  }

  Future<OrphanCleanupResult> _cleanupSandboxOrphan(
    MobileProjectSandbox sandbox,
    OrphanRootCleanupRequest request,
  ) async {
    if (!request.createdNewDirectory) {
      return const OrphanCleanupResult(outcome: OrphanCleanupOutcome.retained);
    }
    final current = await sandbox.currentRoot(request.projectId);
    if (current == null) {
      return const OrphanCleanupResult(outcome: OrphanCleanupOutcome.removed);
    }
    if (current.fingerprint != request.identity.fingerprint) {
      return const OrphanCleanupResult(
        outcome: OrphanCleanupOutcome.quarantined,
        warning: true,
      );
    }
    final removed = await sandbox.removeIfEmpty(
      request.projectId,
      request.identity,
    );
    return OrphanCleanupResult(
      outcome: removed
          ? OrphanCleanupOutcome.removed
          : OrphanCleanupOutcome.retained,
      warning: !removed,
    );
  }

  @override
  CanonicalDirectoryIdentity? identityForRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
  }) {
    if (rootId != null) {
      return _sandboxIdentities[rootId.value];
    }
    if (grantId == null) {
      return null;
    }
    return _stagedIdentities[grantId.value] ?? grantStore.identityFor(grantId);
  }

  String _pathForHandle(String handle) {
    if (filesystem is FakeDesktopFilesystem) {
      return (filesystem as FakeDesktopFilesystem).pathForHandle(handle);
    }
    return handle;
  }
}

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throwProject(ProjectErrorKind.cancelled, 'cancelled');
  }
}

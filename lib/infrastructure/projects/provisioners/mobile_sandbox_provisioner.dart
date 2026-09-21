import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/llm/cancellation.dart';
import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/grants.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/identity.dart';
import '../../../core/projects/provisioning.dart';
import '../fs/filesystem_ops.dart';

abstract interface class MobileProjectSandbox {
  ProjectPlatformKind get platformKind;
  ProjectFilesystemOpLog get opLog;

  Future<bool> rootExists(ProjectId projectId);
  Future<CanonicalDirectoryIdentity> createRoot(ProjectId projectId);
  Future<CanonicalDirectoryIdentity?> currentRoot(ProjectId projectId);
  Future<bool> removeIfEmpty(
    ProjectId projectId,
    CanonicalDirectoryIdentity expected,
  );
}

final class FakeMobileSandbox implements MobileProjectSandbox {
  FakeMobileSandbox({required this.platformKind, List<String>? container})
    : containerComponents = List<String>.unmodifiable(
        container ?? const <String>['app', 'projects'],
      );

  @override
  final ProjectPlatformKind platformKind;
  final List<String> containerComponents;
  final Map<String, CanonicalDirectoryIdentity> roots =
      <String, CanonicalDirectoryIdentity>{};
  @override
  final ProjectFilesystemOpLog opLog = ProjectFilesystemOpLog();
  int pickerCalls = 0;
  int grantStoreCalls = 0;
  int writeCount = 0;

  CanonicalDirectoryIdentity get containerIdentity {
    return CanonicalDirectoryIdentity(
      components: containerComponents,
      platformKind: platformKind,
      fingerprint: fingerprintForComponents(
        containerComponents,
        platformKind: platformKind,
      ),
    );
  }

  void seedPreexisting(ProjectId projectId) {
    roots[projectId.value] = _identityFor(projectId);
  }

  @override
  Future<bool> rootExists(ProjectId projectId) async =>
      roots.containsKey(projectId.value);

  @override
  Future<CanonicalDirectoryIdentity> createRoot(ProjectId projectId) async {
    writeCount += 1;
    opLog.add(ProjectFilesystemOpKind.createDirectory);
    final identity = _identityFor(projectId);
    roots[projectId.value] = identity;
    return identity;
  }

  @override
  Future<CanonicalDirectoryIdentity?> currentRoot(ProjectId projectId) async =>
      roots[projectId.value];

  @override
  Future<bool> removeIfEmpty(
    ProjectId projectId,
    CanonicalDirectoryIdentity expected,
  ) async {
    final current = roots[projectId.value];
    if (current == null) return true;
    if (current.fingerprint != expected.fingerprint) return false;
    opLog.add(ProjectFilesystemOpKind.deleteDirectory);
    writeCount += 1;
    roots.remove(projectId.value);
    return true;
  }

  CanonicalDirectoryIdentity _identityFor(ProjectId projectId) {
    final components = [...containerComponents, projectId.value];
    return CanonicalDirectoryIdentity(
      components: components,
      platformKind: platformKind,
      fingerprint: fingerprintForComponents(
        components,
        platformKind: platformKind,
      ),
    );
  }
}

typedef MobileSandboxDirectoryResolver = Future<Directory> Function();

final class IoMobileProjectSandbox implements MobileProjectSandbox {
  IoMobileProjectSandbox({
    required this.platformKind,
    required this.applicationSupportDirectoryResolver,
  }) : assert(platformKind != ProjectPlatformKind.web);

  @override
  final ProjectPlatformKind platformKind;
  final MobileSandboxDirectoryResolver applicationSupportDirectoryResolver;

  @override
  final ProjectFilesystemOpLog opLog = ProjectFilesystemOpLog();

  Future<Directory> _container() async {
    final support = await applicationSupportDirectoryResolver();
    return Directory(p.join(support.path, 'project-sandbox-roots-v1'));
  }

  Future<Directory> _root(ProjectId projectId) async =>
      Directory(p.join((await _container()).path, projectId.value));

  @override
  Future<bool> rootExists(ProjectId projectId) async =>
      (await _root(projectId)).exists();

  @override
  Future<CanonicalDirectoryIdentity> createRoot(ProjectId projectId) async {
    final container = await _container();
    await container.create(recursive: true);
    final root = await _root(projectId);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw ProjectException(sanitizedProjectCollisionError());
    }
    opLog.add(ProjectFilesystemOpKind.createDirectory);
    try {
      await root.create(recursive: false);
    } on FileSystemException {
      throw ProjectException(sanitizedProjectCollisionError());
    }
    final resolvedContainer = await container.resolveSymbolicLinks();
    final resolvedRoot = await root.resolveSymbolicLinks();
    if (!p.isWithin(resolvedContainer, resolvedRoot)) {
      throw ProjectException(sanitizedProjectDeniedError());
    }
    return _identity(resolvedRoot);
  }

  @override
  Future<CanonicalDirectoryIdentity?> currentRoot(ProjectId projectId) async {
    final root = await _root(projectId);
    if (!await root.exists()) return null;
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final resolved = await root.resolveSymbolicLinks();
    final container = await _container();
    final resolvedContainer = await container.resolveSymbolicLinks();
    final expected = p.normalize(p.join(resolvedContainer, projectId.value));
    if (p.normalize(resolved) != expected ||
        !p.isWithin(resolvedContainer, resolved)) {
      return null;
    }
    return _identity(resolved);
  }

  @override
  Future<bool> removeIfEmpty(
    ProjectId projectId,
    CanonicalDirectoryIdentity expected,
  ) async {
    final root = await _root(projectId);
    if (!await root.exists()) return true;
    final current = await currentRoot(projectId);
    if (current == null || current.fingerprint != expected.fingerprint) {
      return false;
    }
    if (!(await root.list().isEmpty)) return false;
    opLog.add(ProjectFilesystemOpKind.deleteDirectory);
    await root.delete(recursive: false);
    return true;
  }

  CanonicalDirectoryIdentity _identity(String absolutePath) {
    final normalized = p.normalize(p.absolute(absolutePath));
    final components = p
        .split(p.relative(normalized, from: p.rootPrefix(normalized)))
        .where((component) => component.isNotEmpty && component != '.')
        .toList(growable: false);
    return CanonicalDirectoryIdentity(
      components: components,
      platformKind: platformKind,
      fingerprint: fingerprintForComponents(
        components,
        platformKind: platformKind,
      ),
    );
  }
}

final class MobileSandboxProjectRootProvisioner
    implements ProjectRootProvisioner {
  MobileSandboxProjectRootProvisioner({
    required this.capabilities,
    required this.sandbox,
  }) : assert(
         capabilities.mobileSandboxRoots,
         'Mobile provisioner requires sandbox capabilities.',
       );

  @override
  final ProjectPlatformCapabilities capabilities;
  final MobileProjectSandbox sandbox;
  final Map<String, CanonicalDirectoryIdentity> _identities =
      <String, CanonicalDirectoryIdentity>{};

  @override
  Future<ProjectRootProvisionResult> stageRoot({
    DesktopRootProvisionRequest? desktop,
    MobileSandboxProvisionRequest? mobile,
    required CancellationToken cancellation,
  }) async {
    if (desktop != null) {
      throwProject(
        ProjectErrorKind.configuration,
        'Mobile sandbox provisioner does not accept desktop grants.',
      );
    }
    if (mobile == null) {
      throwProject(
        ProjectErrorKind.configuration,
        'Mobile sandbox request is required.',
      );
    }
    if (cancellation.isCancelled) {
      throwProject(ProjectErrorKind.cancelled, 'cancelled');
    }
    if (await sandbox.rootExists(mobile.projectId)) {
      throw ProjectException(sanitizedProjectCollisionError());
    }
    final identity = await sandbox.createRoot(mobile.projectId);
    _identities[mobile.rootId.value] = identity;
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

  @override
  Future<void> acknowledgeRoot(ProjectRootProvisionResult staged) async {
    if (staged is! MobileSandboxRootResult) {
      throwProject(
        ProjectErrorKind.configuration,
        'Mobile provisioner cannot acknowledge a non-sandbox root.',
      );
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
    if (grantId != null) {
      return ProjectAccessStatus.unsupported;
    }
    if (rootId == null || rootId.value != projectId.value) {
      return ProjectAccessStatus.unverifiable;
    }
    final identity = await sandbox.currentRoot(projectId);
    if (identity == null) {
      return ProjectAccessStatus.missing;
    }
    final known = _identities[rootId.value];
    if (known != null && known.fingerprint != identity.fingerprint) {
      return ProjectAccessStatus.unverifiable;
    }
    _identities[rootId.value] = identity;
    return ProjectAccessStatus.active;
  }

  @override
  Future<void> retireRoot({
    DirectoryGrantId? grantId,
    ProjectRootId? rootId,
    required ProjectId projectId,
  }) async {
    _identities.remove(rootId?.value);
  }

  @override
  Future<OrphanCleanupResult> cleanupOrphan(
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
    if (rootId == null) {
      return null;
    }
    return _identities[rootId.value];
  }
}

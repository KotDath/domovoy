import 'dart:async';
import 'dart:math';

import '../../../core/agents/catalog.dart';
import '../../../core/agents/errors.dart';
import '../../../core/agents/repository.dart';
import '../../../core/llm/cancellation.dart';
import '../../../core/projects/catalog.dart';
import '../../../core/projects/default_project.dart';
import '../../../core/projects/enums.dart';
import '../../../core/projects/errors.dart';
import '../../../core/projects/grants.dart';
import '../../../core/projects/ids.dart';
import '../../../core/projects/identity.dart';
import '../../../core/projects/names.dart';
import '../../../core/projects/policy.dart';
import '../../../core/projects/provisioning.dart';
import '../../../core/projects/record.dart';
import '../../../core/projects/repository.dart';
import 'project_command_result.dart';

enum ProjectMutationBoundary {
  afterStage,
  afterAcknowledge,
  beforeProjectCommit,
  afterProjectCommit,
  afterDeletingPublished,
  afterMembersUnassigned,
  beforeTombstone,
  afterTombstone,
}

typedef ProjectBoundaryHook =
    Future<void> Function(ProjectMutationBoundary boundary);

final class ProjectApplicationService {
  ProjectApplicationService({
    required this.projects,
    required this.projectCatalog,
    required this.sessions,
    required this.sessionCatalog,
    required this.provisioner,
    this.grants,
    this.nowMicros,
    this.nextId,
    this.boundaryHook,
    this.maxMembershipRetries = 5,
  });

  final ProjectRepository projects;
  final ProjectCatalog projectCatalog;
  final AgentSessionRepository sessions;
  final AgentSessionCatalog sessionCatalog;
  final ProjectRootProvisioner provisioner;
  final ProjectDirectoryGrantStore? grants;
  final int Function()? nowMicros;
  final String Function(String kind)? nextId;
  final ProjectBoundaryHook? boundaryHook;
  final int maxMembershipRetries;
  final _SerialLock _lock = _SerialLock();
  var _idSequence = 0;
  final Random _idRandom = Random.secure();

  ProjectPlatformCapabilities get capabilities => provisioner.capabilities;

  int _now() => nowMicros?.call() ?? DateTime.now().microsecondsSinceEpoch;

  String _id(String kind) {
    final custom = nextId;
    if (custom != null) {
      return custom(kind);
    }
    _idSequence += 1;
    final nonce = List<String>.generate(
      4,
      (_) => _idRandom.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
    ).join();
    return '$kind-${_now().toRadixString(36)}-$nonce-$_idSequence';
  }

  /// Admits the durable session creation under the same serialization boundary
  /// as Project deletion. The callback must perform the one acknowledged
  /// session creation before returning.
  Future<T> createProjectSession<T>({
    required ProjectId? projectId,
    required Future<T> Function() create,
    required T Function(ProjectError error) denied,
  }) {
    return _lock.run(() async {
      if (projectId == null) return create();
      try {
        final current = await projects.load(projectId);
        if (current == null ||
            current.lifecycle != ProjectLifecycle.active ||
            await _revalidateRecord(current) != ProjectAccessStatus.active) {
          return denied(sanitizedProjectAccessError());
        }
        return await create();
      } on ProjectException catch (error) {
        return denied(error.error);
      } on Object {
        return denied(sanitizedProjectPersistenceError());
      }
    });
  }

  /// Creates the protected default project and adopts unassigned chats.
  ///
  /// The operation is idempotent: running it on every startup leaves an
  /// existing healthy default project and its membership untouched.
  Future<ProjectCommandResult> bootstrapDefaultProject({
    required CancellationToken cancellation,
  }) {
    return _lock.run(() async {
      try {
        if (!capabilities.projectCreationSupported ||
            !capabilities.appManagedSandboxRoots) {
          return const ProjectCommandResult.unsupported();
        }
        _throwIfCancelled(cancellation);
        final existing = await projects.load(defaultProjectId);
        if (existing != null && existing.kind != ProjectKind.defaultProject) {
          throwProject(
            ProjectErrorKind.conflict,
            'The reserved default project identity is unavailable.',
          );
        }
        var current = existing;
        if (current == null) {
          final recovered = await provisioner.revalidateRoot(
            rootId: defaultProjectRootId,
            projectId: defaultProjectId,
          );
          switch (recovered) {
            case ProjectAccessStatus.active:
              break;
            case ProjectAccessStatus.missing:
              final staged = await _stageDefaultRoot(cancellation);
              if (staged == null) {
                return const ProjectCommandResult.unsupported();
              }
            case ProjectAccessStatus.unsupported:
              return const ProjectCommandResult.unsupported();
            case ProjectAccessStatus.corrupt:
            case ProjectAccessStatus.unverifiable:
            case ProjectAccessStatus.requiresRegrant:
            case ProjectAccessStatus.revoked:
              return ProjectCommandResult.failed(sanitizedProjectAccessError());
          }
          final now = _now();
          current = ProjectRecord(
            id: defaultProjectId,
            revision: 0,
            name: defaultProjectName,
            root: AppSandboxRootReference(defaultProjectRootId),
            kind: ProjectKind.defaultProject,
            createdAtMicros: now,
            updatedAtMicros: now,
          );
          await _runBoundary(ProjectMutationBoundary.beforeProjectCommit);
          _throwIfCancelled(cancellation);
          await projects.save(
            current,
            expectedRevision: 0,
            cancellation: cancellation,
          );
          await _runBoundary(ProjectMutationBoundary.afterProjectCommit);
        } else {
          if (current.lifecycle != ProjectLifecycle.active) {
            throwProject(
              ProjectErrorKind.conflict,
              'The default project is not active.',
            );
          }
          final root = current.root;
          if (root is! AppSandboxRootReference) {
            throwProject(
              ProjectErrorKind.configuration,
              'The default project root is not an app sandbox.',
            );
          }
          final status = await provisioner.revalidateRoot(
            rootId: root.rootId,
            projectId: current.id,
          );
          if (status == ProjectAccessStatus.missing) {
            final staged = await _stageDefaultRoot(cancellation);
            if (staged == null) {
              return ProjectCommandResult.failed(sanitizedProjectAccessError());
            }
            final successor = current.copyWith(
              revision: current.revision + 1,
              updatedAtMicros: _now(),
            );
            await projects.save(
              successor,
              expectedRevision: current.revision,
              cancellation: cancellation,
            );
            current = successor;
          } else if (status != ProjectAccessStatus.active) {
            await _migrateUnassignedSessions(cancellation);
            return ProjectCommandResult.failed(sanitizedProjectAccessError());
          }
        }
        await _migrateUnassignedSessions(cancellation);
        return ProjectCommandResult.succeeded(project: current);
      } on ProjectException catch (error) {
        return _mapFailure(error);
      } on Object {
        return ProjectCommandResult.failed(sanitizedProjectPersistenceError());
      }
    });
  }

  Future<MobileSandboxRootResult?> _stageDefaultRoot(
    CancellationToken cancellation,
  ) async {
    _throwIfCancelled(cancellation);
    final staged = await provisioner.stageRoot(
      mobile: MobileSandboxProvisionRequest(
        projectId: defaultProjectId,
        rootId: defaultProjectRootId,
      ),
      cancellation: cancellation,
    );
    if (staged is! MobileSandboxRootResult) {
      return null;
    }
    await provisioner.acknowledgeRoot(staged);
    return staged;
  }

  Future<ProjectCommandResult> createProject({
    required String name,
    ProjectDesktopRootMode? desktopMode,
    String folderName = 'Project',
    int additionalCount = 0,
    required CancellationToken cancellation,
  }) {
    return _lock.run(() async {
      ProjectRootProvisionResult? staged;
      try {
        if (!capabilities.projectCreationSupported) {
          return const ProjectCommandResult.unsupported();
        }
        _throwIfCancelled(cancellation);
        final normalized = requireNormalizedProjectName(
          normalizeProjectName(name),
        );
        await _assertUniqueName(normalized);
        final projectId = ProjectId(_id('project'));
        final now = _now();
        if (capabilities.desktopExternalRoots) {
          if (desktopMode == null) {
            throwProject(
              ProjectErrorKind.configuration,
              'Desktop root mode is required.',
            );
          }
          final additionalIds = List<DirectoryGrantId>.generate(
            additionalCount,
            (index) => DirectoryGrantId(_id('grant-extra-$index')),
          );
          staged = await provisioner.stageRoot(
            desktop: DesktopRootProvisionRequest(
              projectId: projectId,
              grantId: DirectoryGrantId(_id('grant-root')),
              mode: desktopMode,
              folderName: folderName,
              additionalGrantIds: additionalIds,
            ),
            cancellation: cancellation,
          );
        } else if (capabilities.mobileSandboxRoots) {
          staged = await provisioner.stageRoot(
            mobile: MobileSandboxProvisionRequest(
              projectId: projectId,
              rootId: ProjectRootId(projectId.value),
            ),
            cancellation: cancellation,
          );
        } else {
          return const ProjectCommandResult.unsupported();
        }
        await _runBoundary(ProjectMutationBoundary.afterStage);
        _throwIfCancelled(cancellation);
        await _assertNoOverlap(staged);
        await provisioner.acknowledgeRoot(staged);
        await _runBoundary(ProjectMutationBoundary.afterAcknowledge);
        _throwIfCancelled(cancellation);
        final record = _recordFromStaged(
          projectId: projectId,
          name: normalized,
          staged: staged,
          now: now,
        );
        final status = await _revalidateRecord(record);
        if (status != ProjectAccessStatus.active) {
          await _rollback(staged);
          staged = null;
          return ProjectCommandResult.failed(sanitizedProjectAccessError());
        }
        await _runBoundary(ProjectMutationBoundary.beforeProjectCommit);
        _throwIfCancelled(cancellation);
        await projects.save(
          record,
          expectedRevision: 0,
          cancellation: cancellation,
        );
        staged = null;
        await _runBoundary(ProjectMutationBoundary.afterProjectCommit);
        return ProjectCommandResult.succeeded(project: record);
      } on ProjectException catch (error) {
        final pending = staged;
        if (pending != null && error.error.kind != ProjectErrorKind.cancelled) {
          final cleanup = await _rollbackSafe(pending);
          return _mapFailure(error, cleanupWarning: cleanup);
        }
        if (pending != null) {
          final cleanup = await _rollbackSafe(pending);
          if (cleanup) {
            return ProjectCommandResult.failed(
              sanitizedProjectCleanupWarning(),
              cleanupWarning: true,
            );
          }
          return const ProjectCommandResult.cancelled();
        }
        return _mapFailure(error);
      } on AgentException catch (error) {
        return ProjectCommandResult.failed(
          ProjectError(
            kind: ProjectErrorKind.persistence,
            message: error.error.message,
          ),
        );
      }
    });
  }

  Future<ProjectCommandResult> deleteProject({
    required ProjectId id,
    required int expectedRevision,
    required CancellationToken cancellation,
    Future<void> Function()? stopSelectedMember,
  }) {
    return _lock.run(() async {
      try {
        _throwIfCancelled(cancellation);
        final existing = await projects.load(id);
        if (existing == null) {
          throwProject(
            ProjectErrorKind.conflict,
            'Project ${id.value} was not found.',
          );
        }
        if (existing.isDefaultProject || id.isDefault) {
          throw ProjectException(sanitizedProjectProtectedError());
        }
        if (existing.revision != expectedRevision &&
            existing.lifecycle != ProjectLifecycle.deleting) {
          throwProject(
            ProjectErrorKind.conflict,
            'Project ${id.value} was updated concurrently.',
          );
        }
        var current = existing;
        if (current.lifecycle != ProjectLifecycle.deleting) {
          _throwIfCancelled(cancellation);
          current = current.copyWith(
            revision: current.revision + 1,
            lifecycle: ProjectLifecycle.deleting,
            deletionOperationId: ProjectDeletionOperationId(_id('delete')),
            updatedAtMicros: _now(),
          );
          await projects.save(
            current,
            expectedRevision: existing.revision,
            cancellation: cancellation,
          );
        }
        await _runBoundary(ProjectMutationBoundary.afterDeletingPublished);
        await stopSelectedMember?.call();
        await _reassignMembers(id);
        await _runBoundary(ProjectMutationBoundary.afterMembersUnassigned);
        await _proveNoHealthyMembers(id);
        await _runBoundary(ProjectMutationBoundary.beforeTombstone);
        await projects.delete(
          id,
          expectedRevision: current.revision,
          cancellation: CancellationSource().token,
        );
        await _runBoundary(ProjectMutationBoundary.afterTombstone);
        await _revokeCapabilities(current);
        return ProjectCommandResult.succeeded(project: current);
      } on ProjectException catch (error) {
        return _mapFailure(error);
      } on AgentException {
        return ProjectCommandResult.failed(sanitizedProjectPersistenceError());
      } on Object {
        return ProjectCommandResult.failed(sanitizedProjectPersistenceError());
      }
    });
  }

  Future<ProjectAccessStatus> accessStatus(ProjectRecord record) {
    return _revalidateRecord(record);
  }

  Future<void> recoverDeletingProjects({
    Future<void> Function(ProjectId id)? stopSelectedMember,
  }) {
    return _lock.run(() async {
      final snapshot = await projectCatalog.list();
      for (final summary in snapshot.available) {
        if (summary.lifecycle != ProjectLifecycle.deleting) {
          continue;
        }
        final record = await projects.load(summary.id);
        if (record == null) {
          continue;
        }
        await stopSelectedMember?.call(summary.id);
        await _reassignMembers(summary.id);
        try {
          await _proveNoHealthyMembers(summary.id);
        } on ProjectException {
          continue;
        }
        await projects.delete(
          summary.id,
          expectedRevision: record.revision,
          cancellation: CancellationSource().token,
        );
        await _revokeCapabilities(record);
      }
    });
  }

  Future<void> cleanupOrphans() async {
    final snapshot = await projectCatalog.list();
    if (!snapshot.isFullyHealthy) {
      return;
    }
    final grantStore = grants;
    if (grantStore == null) {
      return;
    }
    final liveIds = snapshot.available.map((item) => item.id.value).toSet();
    for (final orphan in await grantStore.enumerateOrphans()) {
      if (liveIds.contains(orphan.projectId.value)) {
        continue;
      }
      await grantStore.revoke(orphan.grantId);
    }
  }

  ProjectRecord _recordFromStaged({
    required ProjectId projectId,
    required String name,
    required ProjectRootProvisionResult staged,
    required int now,
  }) {
    if (staged is DesktopExternalRootResult) {
      return ProjectRecord(
        id: projectId,
        revision: 0,
        name: name,
        root: ExternalGrantRootReference(staged.root.descriptor.grantId),
        additionalGrantIds: [
          for (final extra in staged.additional) extra.descriptor.grantId,
        ],
        createdAtMicros: now,
        updatedAtMicros: now,
      );
    }
    if (staged is MobileSandboxRootResult) {
      return ProjectRecord(
        id: projectId,
        revision: 0,
        name: name,
        root: AppSandboxRootReference(staged.descriptor.rootId),
        createdAtMicros: now,
        updatedAtMicros: now,
      );
    }
    throw ProjectException(sanitizedProjectUnsupportedError());
  }

  Future<ProjectAccessStatus> _revalidateRecord(ProjectRecord record) async {
    final root = record.root;
    if (root is ExternalGrantRootReference) {
      var status = await provisioner.revalidateRoot(
        grantId: root.grantId,
        projectId: record.id,
      );
      if (status != ProjectAccessStatus.active) {
        return status;
      }
      for (final extra in record.additionalGrantIds) {
        status = await provisioner.revalidateRoot(
          grantId: extra,
          projectId: record.id,
          expectedRole: DirectoryGrantRole.additional,
          expectedAccess: DirectoryGrantAccess.readOnly,
        );
        if (status != ProjectAccessStatus.active) {
          return status;
        }
      }
      return ProjectAccessStatus.active;
    }
    if (root is AppSandboxRootReference) {
      return provisioner.revalidateRoot(
        rootId: root.rootId,
        projectId: record.id,
      );
    }
    return ProjectAccessStatus.unsupported;
  }

  Future<void> _assertUniqueName(String normalized) async {
    final snapshot = await projectCatalog.list();
    final key = projectNameCollisionKey(normalized);
    for (final summary in snapshot.available) {
      if (projectNameCollisionKey(summary.name) == key) {
        throw ProjectException(sanitizedProjectCollisionError());
      }
    }
  }

  Future<void> _assertNoOverlap(ProjectRootProvisionResult staged) async {
    final candidates = <CanonicalDirectoryIdentity>[];
    if (staged is DesktopExternalRootResult) {
      candidates.add(staged.root.identity);
      for (final extra in staged.additional) {
        candidates.add(extra.identity);
      }
    } else if (staged is MobileSandboxRootResult) {
      candidates.add(staged.identity);
    } else {
      return;
    }
    final existing = await _activeIdentities();
    for (final candidate in candidates) {
      assertNoDesktopOverlap(candidate: candidate, existing: existing);
    }
    if (staged is DesktopExternalRootResult) {
      final local = <CanonicalDirectoryIdentity>[staged.root.identity];
      for (final extra in staged.additional) {
        assertNoDesktopOverlap(candidate: extra.identity, existing: local);
        local.add(extra.identity);
      }
    }
  }

  Future<List<CanonicalDirectoryIdentity>> _activeIdentities() async {
    final snapshot = await projectCatalog.list();
    final identities = <CanonicalDirectoryIdentity>[];
    for (final summary in snapshot.available) {
      if (summary.lifecycle != ProjectLifecycle.active) {
        continue;
      }
      final record = await projects.load(summary.id);
      if (record == null) {
        continue;
      }
      final root = record.root;
      if (root is ExternalGrantRootReference) {
        final identity = provisioner.identityForRoot(grantId: root.grantId);
        if (identity != null) {
          identities.add(identity);
        }
        for (final extra in record.additionalGrantIds) {
          final extraIdentity = provisioner.identityForRoot(grantId: extra);
          if (extraIdentity != null) {
            identities.add(extraIdentity);
          }
        }
      } else if (root is AppSandboxRootReference) {
        final identity = provisioner.identityForRoot(rootId: root.rootId);
        if (identity != null) {
          identities.add(identity);
        }
      }
    }
    return identities;
  }

  Future<bool> _rollbackSafe(ProjectRootProvisionResult staged) async {
    try {
      await _rollback(staged);
      return false;
    } on ProjectException catch (error) {
      return error.error.kind == ProjectErrorKind.persistence;
    } on Object {
      return true;
    }
  }

  Future<void> _rollback(ProjectRootProvisionResult staged) async {
    if (staged is DesktopExternalRootResult) {
      await provisioner.cleanupOrphan(
        OrphanRootCleanupRequest(
          projectId: staged.root.descriptor.projectId,
          identity: staged.root.identity,
          createdNewDirectory: staged.root.createdNewDirectory,
        ),
      );
      await provisioner.retireRoot(
        grantId: staged.root.descriptor.grantId,
        projectId: staged.root.descriptor.projectId,
      );
      for (final extra in staged.additional) {
        await provisioner.retireRoot(
          grantId: extra.descriptor.grantId,
          projectId: extra.descriptor.projectId,
        );
      }
      return;
    }
    if (staged is MobileSandboxRootResult) {
      await provisioner.cleanupOrphan(
        OrphanRootCleanupRequest(
          projectId: staged.descriptor.projectId,
          identity: staged.identity,
          createdNewDirectory: staged.createdNewDirectory,
        ),
      );
    }
  }

  Future<void> _migrateUnassignedSessions(
    CancellationToken cancellation,
  ) async {
    await _reassignSessions(
      from: null,
      to: defaultProjectId,
      cancellation: cancellation,
    );
  }

  Future<void> _reassignMembers(ProjectId projectId) async {
    final defaultExists = await projects.load(defaultProjectId) != null;
    await _reassignSessions(
      from: projectId,
      to: defaultExists ? defaultProjectId : null,
      cancellation: CancellationSource().token,
    );
  }

  Future<void> _reassignSessions({
    required ProjectId? from,
    required ProjectId? to,
    required CancellationToken cancellation,
  }) async {
    for (var attempt = 0; attempt < maxMembershipRetries; attempt += 1) {
      final snapshot = await sessionCatalog.list();
      var changed = false;
      for (final summary in snapshot.available) {
        if (summary.projectId != from) {
          continue;
        }
        final record = await sessions.load(summary.id);
        if (record == null || record.projectId != from) {
          continue;
        }
        try {
          await sessions.save(
            record.copyWith(
              revision: record.revision + 1,
              projectId: to,
              updatedAtMicros: _now(),
            ),
            expectedRevision: record.revision,
            cancellation: cancellation,
          );
          changed = true;
        } on AgentException catch (error) {
          if (error.error.kind == AgentErrorKind.conflict) {
            changed = true;
            continue;
          }
          rethrow;
        }
      }
      if (!changed) {
        return;
      }
    }
  }

  Future<void> _proveNoHealthyMembers(ProjectId projectId) async {
    final snapshot = await sessionCatalog.list();
    if (snapshot.issues.isNotEmpty) {
      throwProject(
        ProjectErrorKind.conflict,
        'Project deletion is blocked while a chat catalog issue remains.',
      );
    }
    for (final summary in snapshot.available) {
      if (summary.projectId == projectId) {
        throwProject(
          ProjectErrorKind.conflict,
          'Project still has assigned chats.',
        );
      }
    }
  }

  Future<void> _revokeCapabilities(ProjectRecord record) async {
    final root = record.root;
    if (root is ExternalGrantRootReference) {
      await provisioner.retireRoot(grantId: root.grantId, projectId: record.id);
      for (final extra in record.additionalGrantIds) {
        await provisioner.retireRoot(grantId: extra, projectId: record.id);
      }
    } else if (root is AppSandboxRootReference) {
      await provisioner.retireRoot(rootId: root.rootId, projectId: record.id);
    }
  }

  Future<void> _runBoundary(ProjectMutationBoundary boundary) async {
    await boundaryHook?.call(boundary);
  }

  ProjectCommandResult _mapFailure(
    ProjectException error, {
    bool cleanupWarning = false,
  }) {
    switch (error.error.kind) {
      case ProjectErrorKind.cancelled:
        return const ProjectCommandResult.cancelled();
      case ProjectErrorKind.collision:
        return ProjectCommandResult.conflict(error.error);
      case ProjectErrorKind.conflict:
        return ProjectCommandResult.conflict(error.error);
      case ProjectErrorKind.unsupported:
        return const ProjectCommandResult.unsupported();
      case ProjectErrorKind.persistence:
        final warning =
            cleanupWarning ||
            error.error.message == sanitizedProjectCleanupWarning().message;
        return ProjectCommandResult.failed(
          warning ? sanitizedProjectCleanupWarning() : error.error,
          cleanupWarning: warning,
        );
      default:
        return ProjectCommandResult.failed(
          error.error,
          cleanupWarning: cleanupWarning,
        );
    }
  }
}

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throwProject(ProjectErrorKind.cancelled, 'cancelled');
  }
}

final class _SerialLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final predecessor = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        released.complete();
      }
    }();
  }
}

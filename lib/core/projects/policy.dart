import 'enums.dart';
import 'errors.dart';
import 'grants.dart';
import 'ids.dart';
import 'identity.dart';
import 'record.dart';

enum ProjectChildResolutionDenial {
  absolutePath,
  emptySegment,
  nul,
  dotSegment,
  dotDotSegment,
  separatorInjection,
  alternateSyntax,
  canonicalEscape,
  symlinkEscape,
  junctionEscape,
  crossProject,
  staleGrant,
  revokedGrant,
  projectSwitch,
  additionalWrite,
  inactiveProject,
  grantMismatch,
  unverifiable,
  missingGrant,
  unsupported,
}

final class ProjectChildResolution {
  const ProjectChildResolution.allow(this.segments)
    : allowed = true,
      denial = null;

  const ProjectChildResolution.deny(this.denial)
    : allowed = false,
      segments = const <String>[];

  final bool allowed;
  final ProjectChildResolutionDenial? denial;
  final List<String> segments;
}

final class ProjectChildResolutionContext {
  const ProjectChildResolutionContext({
    required this.activeProjectId,
    required this.grantId,
    required this.write,
    required this.records,
    required this.grants,
    this.grantIdentities =
        const <DirectoryGrantId, CanonicalDirectoryIdentity>{},
    this.linkSegments = const <String>{},
    this.junctionSegments = const <String>{},
    this.resolvedIdentity,
  });

  final ProjectId activeProjectId;
  final DirectoryGrantId grantId;
  final bool write;
  final Map<ProjectId, ProjectRecord> records;
  final Map<DirectoryGrantId, DesktopGrantDescriptor> grants;
  final Map<DirectoryGrantId, CanonicalDirectoryIdentity> grantIdentities;
  final Set<String> linkSegments;
  final Set<String> junctionSegments;
  final CanonicalDirectoryIdentity? resolvedIdentity;
}

final class ProjectChildPathPolicy {
  const ProjectChildPathPolicy();

  ProjectChildResolution resolve({
    required String relativePath,
    required ProjectChildResolutionContext context,
  }) {
    final segments = parseRelativeSegments(relativePath);
    if (segments.denial != null) {
      return ProjectChildResolution.deny(segments.denial!);
    }
    final record = context.records[context.activeProjectId];
    if (record == null || !record.isActive) {
      return const ProjectChildResolution.deny(
        ProjectChildResolutionDenial.inactiveProject,
      );
    }
    final grant = context.grants[context.grantId];
    if (grant == null) {
      return const ProjectChildResolution.deny(
        ProjectChildResolutionDenial.missingGrant,
      );
    }
    if (grant.projectId != context.activeProjectId) {
      return const ProjectChildResolution.deny(
        ProjectChildResolutionDenial.projectSwitch,
      );
    }
    final belongsToRecord =
        record.root is ExternalGrantRootReference &&
            (record.root as ExternalGrantRootReference).grantId ==
                grant.grantId ||
        record.additionalGrantIds.contains(grant.grantId);
    if (!belongsToRecord) {
      return const ProjectChildResolution.deny(
        ProjectChildResolutionDenial.grantMismatch,
      );
    }
    if (grant.projectId != record.id) {
      return const ProjectChildResolution.deny(
        ProjectChildResolutionDenial.crossProject,
      );
    }
    switch (grant.status) {
      case ProjectAccessStatus.active:
        break;
      case ProjectAccessStatus.requiresRegrant:
      case ProjectAccessStatus.missing:
        return const ProjectChildResolution.deny(
          ProjectChildResolutionDenial.staleGrant,
        );
      case ProjectAccessStatus.revoked:
        return const ProjectChildResolution.deny(
          ProjectChildResolutionDenial.revokedGrant,
        );
      case ProjectAccessStatus.unsupported:
        return const ProjectChildResolution.deny(
          ProjectChildResolutionDenial.unsupported,
        );
      case ProjectAccessStatus.corrupt:
      case ProjectAccessStatus.unverifiable:
        return const ProjectChildResolution.deny(
          ProjectChildResolutionDenial.unverifiable,
        );
    }
    if (context.write && grant.role == DirectoryGrantRole.additional) {
      return const ProjectChildResolution.deny(
        ProjectChildResolutionDenial.additionalWrite,
      );
    }
    if (context.write &&
        grant.requestedAccess != DirectoryGrantAccess.readWrite) {
      return const ProjectChildResolution.deny(
        ProjectChildResolutionDenial.additionalWrite,
      );
    }
    for (final segment in segments.segments) {
      if (context.linkSegments.contains(segment)) {
        return const ProjectChildResolution.deny(
          ProjectChildResolutionDenial.symlinkEscape,
        );
      }
      if (context.junctionSegments.contains(segment)) {
        return const ProjectChildResolution.deny(
          ProjectChildResolutionDenial.junctionEscape,
        );
      }
    }
    final resolved = context.resolvedIdentity;
    if (resolved != null) {
      final grantIdentity = context.grantIdentities[grant.grantId];
      if (grantIdentity == null) {
        return const ProjectChildResolution.deny(
          ProjectChildResolutionDenial.unverifiable,
        );
      }
      final contained =
          resolved.fingerprint == grantIdentity.fingerprint ||
          identityContains(grantIdentity, resolved);
      if (!contained) {
        return const ProjectChildResolution.deny(
          ProjectChildResolutionDenial.canonicalEscape,
        );
      }
    }
    return ProjectChildResolution.allow(segments.segments);
  }
}

final class ParsedRelativePath {
  const ParsedRelativePath.ok(this.segments) : denial = null;

  const ParsedRelativePath.deny(this.denial) : segments = const <String>[];

  final List<String> segments;
  final ProjectChildResolutionDenial? denial;
}

ParsedRelativePath parseRelativeSegments(String input) {
  if (input.contains('\u0000')) {
    return const ParsedRelativePath.deny(ProjectChildResolutionDenial.nul);
  }
  if (input.isEmpty) {
    return const ParsedRelativePath.deny(
      ProjectChildResolutionDenial.emptySegment,
    );
  }
  if (input.startsWith('/') ||
      input.startsWith('\\') ||
      input.startsWith('//') ||
      input.startsWith('\\\\')) {
    return const ParsedRelativePath.deny(
      ProjectChildResolutionDenial.absolutePath,
    );
  }
  if (RegExp(r'^[a-zA-Z]:').hasMatch(input)) {
    return const ParsedRelativePath.deny(
      ProjectChildResolutionDenial.absolutePath,
    );
  }
  if (input.contains(':')) {
    return const ParsedRelativePath.deny(
      ProjectChildResolutionDenial.alternateSyntax,
    );
  }
  if (input.contains('\\')) {
    return const ParsedRelativePath.deny(
      ProjectChildResolutionDenial.separatorInjection,
    );
  }
  final unified = input;
  if (unified.contains('//')) {
    return const ParsedRelativePath.deny(
      ProjectChildResolutionDenial.emptySegment,
    );
  }
  final parts = unified.split('/');
  for (final part in parts) {
    if (part.isEmpty) {
      return const ParsedRelativePath.deny(
        ProjectChildResolutionDenial.emptySegment,
      );
    }
    if (part == '.') {
      return const ParsedRelativePath.deny(
        ProjectChildResolutionDenial.dotSegment,
      );
    }
    if (part == '..') {
      return const ParsedRelativePath.deny(
        ProjectChildResolutionDenial.dotDotSegment,
      );
    }
    if (part.contains('\\')) {
      return const ParsedRelativePath.deny(
        ProjectChildResolutionDenial.separatorInjection,
      );
    }
  }
  return ParsedRelativePath.ok(List<String>.unmodifiable(parts));
}

void assertNoDesktopOverlap({
  required CanonicalDirectoryIdentity candidate,
  required Iterable<CanonicalDirectoryIdentity> existing,
}) {
  for (final other in existing) {
    if (identitiesOverlap(candidate, other)) {
      throw ProjectException(sanitizedProjectCollisionError());
    }
  }
}

import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('child path policy', () {
    const policy = ProjectChildPathPolicy();
    final projectId = ProjectId('p-a');
    final otherId = ProjectId('p-b');
    final rootGrant = DirectoryGrantId('g-root');
    final extraGrant = DirectoryGrantId('g-extra');
    final otherGrant = DirectoryGrantId('g-other');
    final record = ProjectRecord(
      id: projectId,
      revision: 0,
      name: 'Alpha',
      root: ExternalGrantRootReference(rootGrant),
      additionalGrantIds: [extraGrant],
      createdAtMicros: 1,
      updatedAtMicros: 1,
    );
    final root = DesktopGrantDescriptor(
      grantId: rootGrant,
      projectId: projectId,
      role: DirectoryGrantRole.root,
      requestedAccess: DirectoryGrantAccess.readWrite,
      origin: DirectoryGrantOrigin.attached,
      safeDisplayLabel: 'Root',
      canonicalFingerprint: 'root-fp',
      platformKind: ProjectPlatformKind.linux,
      createdAtMicros: 1,
      updatedAtMicros: 1,
      status: ProjectAccessStatus.active,
    );
    final extraDesc = DesktopGrantDescriptor(
      grantId: extraGrant,
      projectId: projectId,
      role: DirectoryGrantRole.additional,
      requestedAccess: DirectoryGrantAccess.readOnly,
      origin: DirectoryGrantOrigin.attached,
      safeDisplayLabel: 'Extra',
      canonicalFingerprint: 'extra-fp',
      platformKind: ProjectPlatformKind.linux,
      createdAtMicros: 1,
      updatedAtMicros: 1,
      status: ProjectAccessStatus.active,
    );

    ProjectChildResolutionContext ctx({
      DirectoryGrantId? grantId,
      bool write = false,
      ProjectAccessStatus? status,
      CanonicalDirectoryIdentity? resolved,
      Set<String> links = const <String>{},
      Set<String> junctions = const <String>{},
    }) {
      return ProjectChildResolutionContext(
        activeProjectId: projectId,
        grantId: grantId ?? rootGrant,
        write: write,
        records: {projectId: record},
        grants: {
          rootGrant: status == null ? root : root.withStatus(status),
          extraGrant: extraDesc,
          otherGrant: DesktopGrantDescriptor(
            grantId: otherGrant,
            projectId: otherId,
            role: DirectoryGrantRole.root,
            requestedAccess: DirectoryGrantAccess.readWrite,
            origin: DirectoryGrantOrigin.attached,
            safeDisplayLabel: 'Other',
            canonicalFingerprint: 'other-fp',
            platformKind: ProjectPlatformKind.linux,
            createdAtMicros: 1,
            updatedAtMicros: 1,
            status: ProjectAccessStatus.active,
          ),
        },
        grantIdentities: {
          rootGrant: CanonicalDirectoryIdentity(
            components: ['home', 'alpha'],
            platformKind: ProjectPlatformKind.linux,
            fingerprint: 'root-fp',
          ),
        },
        linkSegments: links,
        junctionSegments: junctions,
        resolvedIdentity: resolved,
      );
    }

    test('table-driven negatives deny before I/O', () {
      final cases = <(String, ProjectChildResolutionDenial)>[
        ('/abs', ProjectChildResolutionDenial.absolutePath),
        (r'\abs', ProjectChildResolutionDenial.absolutePath),
        ('C:/windows', ProjectChildResolutionDenial.absolutePath),
        ('a\u0000b', ProjectChildResolutionDenial.nul),
        ('', ProjectChildResolutionDenial.emptySegment),
        ('.', ProjectChildResolutionDenial.dotSegment),
        ('..', ProjectChildResolutionDenial.dotDotSegment),
        ('a/../b', ProjectChildResolutionDenial.dotDotSegment),
        (r'a\b', ProjectChildResolutionDenial.separatorInjection),
        ('foo:bar', ProjectChildResolutionDenial.alternateSyntax),
      ];
      for (final entry in cases) {
        expect(
          policy.resolve(relativePath: entry.$1, context: ctx()).denial,
          entry.$2,
          reason: entry.$1,
        );
      }
    });

    test('denies stale, revoked, switch, extra writes, escapes', () {
      expect(
        policy
            .resolve(
              relativePath: 'file.txt',
              context: ctx(status: ProjectAccessStatus.requiresRegrant),
            )
            .denial,
        ProjectChildResolutionDenial.staleGrant,
      );
      expect(
        policy
            .resolve(
              relativePath: 'file.txt',
              context: ctx(status: ProjectAccessStatus.revoked),
            )
            .denial,
        ProjectChildResolutionDenial.revokedGrant,
      );
      expect(
        policy
            .resolve(
              relativePath: 'file.txt',
              context: ctx(grantId: otherGrant),
            )
            .denial,
        ProjectChildResolutionDenial.projectSwitch,
      );
      expect(
        policy
            .resolve(
              relativePath: 'file.txt',
              context: ctx(grantId: extraGrant, write: true),
            )
            .denial,
        ProjectChildResolutionDenial.additionalWrite,
      );
      expect(
        policy
            .resolve(
              relativePath: 'linky/file',
              context: ctx(links: {'linky'}),
            )
            .denial,
        ProjectChildResolutionDenial.symlinkEscape,
      );
      expect(
        policy
            .resolve(
              relativePath: 'junction/file',
              context: ctx(junctions: {'junction'}),
            )
            .denial,
        ProjectChildResolutionDenial.junctionEscape,
      );
      expect(
        policy
            .resolve(
              relativePath: 'file.txt',
              context: ctx(
                resolved: CanonicalDirectoryIdentity(
                  components: ['outside'],
                  platformKind: ProjectPlatformKind.linux,
                  fingerprint: 'outside-fp',
                ),
              ),
            )
            .denial,
        ProjectChildResolutionDenial.canonicalEscape,
      );
    });

    test('overlap uses components not string prefixes', () {
      final parent = CanonicalDirectoryIdentity(
        components: ['home', 'work'],
        platformKind: ProjectPlatformKind.linux,
        fingerprint: 'a',
      );
      final child = CanonicalDirectoryIdentity(
        components: ['home', 'work', 'p'],
        platformKind: ProjectPlatformKind.linux,
        fingerprint: 'b',
      );
      final neighbor = CanonicalDirectoryIdentity(
        components: ['home', 'workload'],
        platformKind: ProjectPlatformKind.linux,
        fingerprint: 'c',
      );
      expect(identitiesOverlap(parent, child), isTrue);
      expect(identitiesOverlap(parent, neighbor), isFalse);
      expect(
        () => assertNoDesktopOverlap(candidate: child, existing: [parent]),
        throwsA(isA<ProjectException>()),
      );
    });
  });
}

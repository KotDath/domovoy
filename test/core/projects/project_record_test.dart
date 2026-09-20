import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProjectRecord v2', () {
    test('desktop Project round-trips without native material', () {
      final record = ProjectRecord(
        id: ProjectId('p1'),
        revision: 3,
        name: 'Alpha Work',
        root: ExternalGrantRootReference(DirectoryGrantId('g-root')),
        additionalGrantIds: [DirectoryGrantId('g-a'), DirectoryGrantId('g-b')],
        createdAtMicros: 10,
        updatedAtMicros: 20,
      );
      const codec = ProjectCodec();
      final encoded = codec.encode(record);
      expect(encoded['version'], 2);
      expect(encoded['kind'], ProjectKind.user.name);
      expect(encoded.toString(), isNot(contains('bookmark')));
      expect(encoded.toString(), isNot(contains('/tmp')));
      expect(codec.decode(encoded), record);
      expect(record.root.kind, ProjectRootKind.externalGrant);
      expect(record.additionalGrantIds, hasLength(2));
      expect(record.isDefaultProject, isFalse);
    });

    test('v1 record migrates to an explicit user kind', () {
      final legacyRecord = ProjectRecord(
        id: ProjectId('legacy'),
        revision: 0,
        name: 'Legacy',
        root: ExternalGrantRootReference(DirectoryGrantId('g-legacy')),
        createdAtMicros: 1,
        updatedAtMicros: 2,
      );
      final legacy = Map<String, Object?>.from(legacyRecord.toJson())
        ..['version'] = ProjectRecord.legacyJsonVersion
        ..remove('kind');
      const codec = ProjectCodec();
      final decoded = codec.decode(legacy);
      expect(decoded.kind, ProjectKind.user);
      expect(decoded.id, ProjectId('legacy'));
      // Re-encoding publishes the migrated schema version.
      expect(
        codec.encode(decoded)['version'],
        ProjectRecord.currentJsonVersion,
      );
    });

    test('protected default record round-trips as a sandbox', () {
      final record = ProjectRecord(
        id: defaultProjectId,
        revision: 0,
        name: defaultProjectName,
        root: AppSandboxRootReference(defaultProjectRootId),
        kind: ProjectKind.defaultProject,
        createdAtMicros: 1,
        updatedAtMicros: 1,
      );
      const codec = ProjectCodec();
      final encoded = codec.encode(record);
      expect(encoded['kind'], ProjectKind.defaultProject.name);
      expect(record.isDefaultProject, isTrue);
      expect(codec.decode(encoded), record);
      expect(record.additionalGrantIds, isEmpty);
    });

    test('reserved identity and kind are mutually exclusive', () {
      expect(
        () => ProjectRecord(
          id: ProjectId('user-project'),
          revision: 0,
          name: 'Impostor',
          root: AppSandboxRootReference(ProjectRootId('r')),
          kind: ProjectKind.defaultProject,
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        throwsA(isA<ProjectException>()),
      );
      expect(
        () => ProjectRecord(
          id: defaultProjectId,
          revision: 0,
          name: 'Reserved',
          root: ExternalGrantRootReference(DirectoryGrantId('g')),
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        throwsA(isA<ProjectException>()),
      );
      expect(
        () => ProjectRecord(
          id: defaultProjectId,
          revision: 0,
          name: 'Reserved',
          root: AppSandboxRootReference(defaultProjectRootId),
          kind: ProjectKind.defaultProject,
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        returnsNormally,
      );
    });

    test('mobile sandbox Project round-trips without grants', () {
      final record = ProjectRecord(
        id: ProjectId('mobile-1'),
        revision: 0,
        name: 'Телефон',
        root: AppSandboxRootReference(ProjectRootId('root-mobile-1')),
        createdAtMicros: 1,
        updatedAtMicros: 1,
      );
      const codec = ProjectCodec();
      expect(codec.decode(codec.encode(record)), record);
      expect(record.additionalGrantIds, isEmpty);
    });

    test('rejects illegal metadata before any resolution', () {
      expect(
        () => ProjectRecord(
          id: ProjectId('p'),
          revision: -1,
          name: 'Ok',
          root: AppSandboxRootReference(ProjectRootId('r')),
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        throwsA(isA<ProjectException>()),
      );
      expect(
        () => ProjectRecord(
          id: ProjectId('p'),
          revision: 0,
          name: 'Ok',
          root: AppSandboxRootReference(ProjectRootId('r')),
          additionalGrantIds: [DirectoryGrantId('extra')],
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        throwsA(isA<ProjectException>()),
      );
      expect(
        () => ProjectRecord(
          id: ProjectId('p'),
          revision: 0,
          name: 'Ok',
          root: ExternalGrantRootReference(DirectoryGrantId('g')),
          additionalGrantIds: [DirectoryGrantId('x'), DirectoryGrantId('x')],
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        throwsA(isA<ProjectException>()),
      );
      expect(
        () => ProjectRecord(
          id: ProjectId('p'),
          revision: 0,
          name: 'Ok',
          root: ExternalGrantRootReference(DirectoryGrantId('g')),
          createdAtMicros: 1,
          updatedAtMicros: 1,
          lifecycle: ProjectLifecycle.deleting,
        ),
        throwsA(isA<ProjectException>()),
      );
      expect(
        () => ProjectRecord(
          id: ProjectId('p'),
          revision: 0,
          name: '',
          root: ExternalGrantRootReference(DirectoryGrantId('g')),
          createdAtMicros: 1,
          updatedAtMicros: 1,
        ),
        throwsA(isA<ProjectException>()),
      );
    });

    test('normalizes names and collision keys', () {
      expect(normalizeProjectName('  Alpha\nWork  '), 'Alpha Work');
      expect(
        projectNameCollisionKey('Alpha'),
        projectNameCollisionKey('ALPHA'),
      );
    });

    test('codec rejects opaque material keys', () {
      final record = ProjectRecord(
        id: ProjectId('p1'),
        revision: 0,
        name: 'Alpha',
        root: ExternalGrantRootReference(DirectoryGrantId('g')),
        createdAtMicros: 1,
        updatedAtMicros: 1,
      );
      final json = Map<String, Object?>.from(record.toJson())
        ..['bookmark'] = 'opaque-token';
      expect(
        () => const ProjectCodec().decode(json),
        throwsA(isA<ProjectException>()),
      );
    });
  });
}

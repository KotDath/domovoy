import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProjectRecord v1', () {
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
      expect(encoded['version'], 1);
      expect(encoded.toString(), isNot(contains('bookmark')));
      expect(encoded.toString(), isNot(contains('/tmp')));
      expect(codec.decode(encoded), record);
      expect(record.root.kind, ProjectRootKind.externalGrant);
      expect(record.additionalGrantIds, hasLength(2));
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

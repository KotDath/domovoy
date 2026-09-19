import '../llm/json.dart';
import 'enums.dart';
import 'errors.dart';
import 'ids.dart';
import 'names.dart';

sealed class ProjectRootReference {
  const ProjectRootReference();

  ProjectRootKind get kind;

  Map<String, Object?> toJson();

  static ProjectRootReference fromJson(Object? json) {
    final map = _strictObject(json, 'root');
    final kind = ProjectRootKindCodec.parse(requireNonBlankString(map, 'kind'));
    switch (kind) {
      case ProjectRootKind.externalGrant:
        _expectKeys(map, const <String>{'kind', 'grantId'});
        return ExternalGrantRootReference(
          DirectoryGrantId.fromJson(map['grantId']),
        );
      case ProjectRootKind.appSandbox:
        _expectKeys(map, const <String>{'kind', 'rootId'});
        return AppSandboxRootReference(ProjectRootId.fromJson(map['rootId']));
    }
  }
}

final class ExternalGrantRootReference extends ProjectRootReference {
  const ExternalGrantRootReference(this.grantId);

  final DirectoryGrantId grantId;

  @override
  ProjectRootKind get kind => ProjectRootKind.externalGrant;

  @override
  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'kind': kind.name,
    'grantId': grantId.toJson(),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExternalGrantRootReference && other.grantId == grantId;

  @override
  int get hashCode => grantId.hashCode;
}

final class AppSandboxRootReference extends ProjectRootReference {
  const AppSandboxRootReference(this.rootId);

  final ProjectRootId rootId;

  @override
  ProjectRootKind get kind => ProjectRootKind.appSandbox;

  @override
  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'kind': kind.name,
    'rootId': rootId.toJson(),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSandboxRootReference && other.rootId == rootId;

  @override
  int get hashCode => rootId.hashCode;
}

final class ProjectRecord {
  ProjectRecord({
    required this.id,
    required this.revision,
    required String name,
    required this.root,
    List<DirectoryGrantId> additionalGrantIds = const <DirectoryGrantId>[],
    required this.createdAtMicros,
    required this.updatedAtMicros,
    this.lifecycle = ProjectLifecycle.active,
    this.deletionOperationId,
  }) : name = requireNormalizedProjectName(name),
       additionalGrantIds = List<DirectoryGrantId>.unmodifiable(
         List<DirectoryGrantId>.from(additionalGrantIds),
       ) {
    if (revision < 0) {
      throwProject(
        ProjectErrorKind.configuration,
        'Project revision must be non-negative.',
      );
    }
    if (createdAtMicros < 0 || updatedAtMicros < 0) {
      throwProject(
        ProjectErrorKind.configuration,
        'Project timestamps must be non-negative.',
      );
    }
    final seen = <String>{};
    for (final grantId in this.additionalGrantIds) {
      if (!seen.add(grantId.value)) {
        throwProject(
          ProjectErrorKind.configuration,
          'Additional grant identities must be unique.',
        );
      }
      if (root is ExternalGrantRootReference &&
          grantId == (root as ExternalGrantRootReference).grantId) {
        throwProject(
          ProjectErrorKind.configuration,
          'Additional grants must not repeat the root grant.',
        );
      }
    }
    if (root is AppSandboxRootReference && this.additionalGrantIds.isNotEmpty) {
      throwProject(
        ProjectErrorKind.configuration,
        'Sandbox roots cannot carry additional external grants.',
      );
    }
    switch (lifecycle) {
      case ProjectLifecycle.active:
        if (deletionOperationId != null) {
          throwProject(
            ProjectErrorKind.configuration,
            'Active projects cannot carry a deletion operation.',
          );
        }
      case ProjectLifecycle.deleting:
        if (deletionOperationId == null) {
          throwProject(
            ProjectErrorKind.configuration,
            'Deleting projects require a deletion operation identity.',
          );
        }
    }
  }

  factory ProjectRecord.fromJson(Object? json) {
    try {
      _rejectOpaqueMaterial(json);
      final map = decodeTypedJson(
        json,
        type: jsonType,
        version: currentJsonVersion,
      );
      final expected = <String>{
        llmJsonTypeKey,
        llmJsonVersionKey,
        'id',
        'revision',
        'name',
        'root',
        'additionalGrantIds',
        'createdAtMicros',
        'updatedAtMicros',
        'lifecycle',
      };
      final lifecycle = ProjectLifecycleCodec.parse(
        requireNonBlankString(map, 'lifecycle'),
      );
      if (lifecycle == ProjectLifecycle.deleting) {
        expected.add('deletionOperationId');
      }
      _expectKeys(map, expected);
      final additional = requireList(
        map,
        'additionalGrantIds',
      ).map(DirectoryGrantId.fromJson).toList(growable: false);
      return ProjectRecord(
        id: ProjectId.fromJson(map['id']),
        revision: requireInt(map, 'revision'),
        name: requireString(map, 'name'),
        root: ProjectRootReference.fromJson(map['root']),
        additionalGrantIds: additional,
        createdAtMicros: requireInt(map, 'createdAtMicros'),
        updatedAtMicros: requireInt(map, 'updatedAtMicros'),
        lifecycle: lifecycle,
        deletionOperationId: map['deletionOperationId'] == null
            ? null
            : ProjectDeletionOperationId.fromJson(map['deletionOperationId']),
      );
    } on ProjectException {
      rethrow;
    } on Object catch (error) {
      throw wrapProjectCodecFailure(error);
    }
  }

  static const jsonType = 'project.record';
  static const currentJsonVersion = 1;

  final ProjectId id;
  final int revision;
  final String name;
  final ProjectRootReference root;
  final List<DirectoryGrantId> additionalGrantIds;
  final int createdAtMicros;
  final int updatedAtMicros;
  final ProjectLifecycle lifecycle;
  final ProjectDeletionOperationId? deletionOperationId;

  String get collisionKey => projectNameCollisionKey(name);

  bool get isActive => lifecycle == ProjectLifecycle.active;

  bool get isDeleting => lifecycle == ProjectLifecycle.deleting;

  ProjectRecord copyWith({
    int? revision,
    String? name,
    ProjectRootReference? root,
    List<DirectoryGrantId>? additionalGrantIds,
    int? updatedAtMicros,
    ProjectLifecycle? lifecycle,
    Object? deletionOperationId = _keep,
  }) {
    return ProjectRecord(
      id: id,
      revision: revision ?? this.revision,
      name: name ?? this.name,
      root: root ?? this.root,
      additionalGrantIds: additionalGrantIds ?? this.additionalGrantIds,
      createdAtMicros: createdAtMicros,
      updatedAtMicros: updatedAtMicros ?? this.updatedAtMicros,
      lifecycle: lifecycle ?? this.lifecycle,
      deletionOperationId: identical(deletionOperationId, _keep)
          ? this.deletionOperationId
          : deletionOperationId as ProjectDeletionOperationId?,
    );
  }

  Map<String, Object?> toJson() {
    return typedJson(
      type: jsonType,
      version: currentJsonVersion,
      fields: <String, Object?>{
        'id': id.toJson(),
        'revision': revision,
        'name': name,
        'root': root.toJson(),
        'additionalGrantIds': additionalGrantIds
            .map((id) => id.toJson())
            .toList(growable: false),
        'createdAtMicros': createdAtMicros,
        'updatedAtMicros': updatedAtMicros,
        'lifecycle': lifecycle.name,
        if (deletionOperationId != null)
          'deletionOperationId': deletionOperationId!.toJson(),
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectRecord &&
          other.id == id &&
          other.revision == revision &&
          other.name == name &&
          other.root == root &&
          listEquals(other.additionalGrantIds, additionalGrantIds) &&
          other.createdAtMicros == createdAtMicros &&
          other.updatedAtMicros == updatedAtMicros &&
          other.lifecycle == lifecycle &&
          other.deletionOperationId == deletionOperationId;

  @override
  int get hashCode => Object.hash(
    id,
    revision,
    name,
    root,
    Object.hashAll(additionalGrantIds),
    createdAtMicros,
    updatedAtMicros,
    lifecycle,
    deletionOperationId,
  );

  @override
  String toString() =>
      'ProjectRecord(${id.value}, rev=$revision, lifecycle=${lifecycle.name})';

  static const _keep = Object();
}

final class ProjectCodec {
  const ProjectCodec();

  Map<String, Object?> encode(ProjectRecord record) =>
      freezeJsonMap(record.toJson());

  ProjectRecord decode(Object? json) => ProjectRecord.fromJson(json);
}

void _rejectOpaqueMaterial(Object? json) {
  if (_containsOpaqueMaterial(json)) {
    throwProject(
      ProjectErrorKind.configuration,
      'Project records cannot contain native grant material or raw paths.',
    );
  }
}

bool _containsOpaqueMaterial(Object? json) {
  if (json is Map) {
    for (final entry in json.entries) {
      if (entry.key is! String) {
        return true;
      }
      final key = (entry.key as String).toLowerCase();
      if (_opaqueKeys.contains(key)) {
        return true;
      }
      if (_containsOpaqueMaterial(entry.value)) {
        return true;
      }
    }
    return false;
  }
  if (json is List) {
    return json.any(_containsOpaqueMaterial);
  }
  return false;
}

const _opaqueKeys = <String>{
  'path',
  'rawpath',
  'bookmark',
  'bookmarkdata',
  'handle',
  'token',
  'capability',
  'native',
  'securityscope',
  'securityscopedbookmark',
  'filesystem',
  'fd',
  'filedescriptor',
};

Map<String, Object?> _strictObject(Object? json, String label) {
  if (json is! Map) {
    throwProject(
      ProjectErrorKind.configuration,
      'Expected object field "$label".',
    );
  }
  final map = <String, Object?>{};
  json.forEach((key, value) {
    if (key is! String) {
      throwProject(
        ProjectErrorKind.configuration,
        'JSON object keys must be strings.',
      );
    }
    map[key] = value;
  });
  return map;
}

void _expectKeys(Map<String, Object?> map, Set<String> expected) {
  if (map.keys.length != expected.length ||
      !map.keys.every(expected.contains)) {
    throwProject(
      ProjectErrorKind.configuration,
      'Unexpected project record fields.',
    );
  }
}

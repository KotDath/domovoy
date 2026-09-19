import '../../../core/projects/errors.dart';
import '../../../core/projects/provisioning.dart';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

final class ScriptedProjectDirectoryPicker implements ProjectDirectoryPicker {
  ScriptedProjectDirectoryPicker();

  final List<ProjectPickedDirectory?> _results = <ProjectPickedDirectory?>[];
  final List<ProjectPickerKind> calls = <ProjectPickerKind>[];

  void enqueue(ProjectPickedDirectory? result) => _results.add(result);

  @override
  Future<ProjectPickedDirectory?> pick(ProjectPickerKind kind) async {
    calls.add(kind);
    if (_results.isEmpty) {
      throwProject(ProjectErrorKind.cancelled, 'cancelled');
    }
    return _results.removeAt(0);
  }
}

final class NativeProjectDirectoryPicker implements ProjectDirectoryPicker {
  const NativeProjectDirectoryPicker();

  @override
  Future<ProjectPickedDirectory?> pick(ProjectPickerKind kind) async {
    final path = await getDirectoryPath(
      confirmButtonText: switch (kind) {
        ProjectPickerKind.existingRoot => 'Выбрать корень проекта',
        ProjectPickerKind.parentDirectory => 'Выбрать родительскую папку',
        ProjectPickerKind.additionalDirectory =>
          'Добавить папку только для чтения',
      },
    );
    if (path == null) return null;
    return ProjectPickedDirectory(
      handleId: path,
      safeLabel: p.basename(p.normalize(path)),
    );
  }
}

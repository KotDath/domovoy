import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Persistent implementation/research tasks linked to Archive items.
final class ArchiveTaskStore {
  ArchiveTaskStore(this.file);

  final File file;
  final Map<String, Map<String, Object?>> _tasks = {};
  Future<void> _writes = Future<void>.value();

  Future<void> load() async {
    await file.parent.create(recursive: true);
    if (!await file.exists()) return;
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final value = jsonDecode(line);
      if (value is! Map<String, dynamic> || value['task'] is! Map) continue;
      final task = Map<String, Object?>.from(value['task'] as Map);
      if (task['id'] is String) _tasks[task['id'] as String] = task;
    }
  }

  Future<Map<String, Object?>> create({
    required String title,
    required String details,
    String? itemIdentifier,
  }) async {
    if (title.trim().isEmpty || title.length > 160 || details.length > 4000) {
      throw const FormatException('Invalid task title or details.');
    }
    if (itemIdentifier != null &&
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$',
        ).hasMatch(itemIdentifier)) {
      throw const FormatException('Invalid Archive item identifier.');
    }
    final task = <String, Object?>{
      'id':
          '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
          '${Random.secure().nextInt(1 << 30).toRadixString(36)}',
      'title': title.trim(),
      'details': details.trim(),
      'itemIdentifier': itemIdentifier,
      'status': 'open',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    await _put(task);
    return task;
  }

  List<Map<String, Object?>> list({String? status}) => [
    for (final task in _tasks.values)
      if (status == null || task['status'] == status)
        Map<String, Object?>.from(task),
  ];

  Future<Map<String, Object?>> complete(String id) async {
    final task = _tasks[id];
    if (task == null) throw const FormatException('Task not found.');
    if (task['status'] == 'done') return Map<String, Object?>.from(task);
    final updated = <String, Object?>{
      ...task,
      'status': 'done',
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await _put(updated);
    return updated;
  }

  Future<void> _put(Map<String, Object?> task) async {
    final next = _writes.then((_) async {
      await file.writeAsString(
        '${jsonEncode({'task': task})}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    _writes = next;
    await next;
    _tasks[task['id'] as String] = task;
  }

  Future<void> close() => _writes;
}

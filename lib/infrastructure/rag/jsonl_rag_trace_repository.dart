import 'dart:convert';

import '../../core/rag/models.dart';
import '../../core/rag/turn.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';

final class JsonlRagTraceRepository implements RagTraceRepository {
  JsonlRagTraceRepository(this.storage);
  final JsonlStreamStorage storage;
  final Map<String, Future<void>> _pending = {};
  String _key(String project, String session, String kind) =>
      ragHash(jsonEncode(['rag-trace-v1', project, session, kind]));

  Future<List<Map<String, dynamic>>> _read(String key) async {
    final stream = await storage.read(key);
    if (stream == null) return [];
    final bytes = await stream.fold<List<int>>([], (a, b) => a..addAll(b));
    final text = utf8.decode(bytes);
    if (!text.endsWith('\n')) throw const FormatException('Incomplete trace');
    final lines = text.substring(0, text.length - 1).split('\n');
    final footer = jsonDecode(lines.removeLast()) as Map;
    final payload = lines.isEmpty ? '' : '${lines.join('\n')}\n';
    if (footer['type'] != 'end' ||
        footer['version'] != 1 ||
        footer['hash'] != ragHash(payload)) {
      throw const FormatException('Corrupt trace');
    }
    return lines.map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
  }

  Future<void> _serial(String key, Future<void> Function() action) {
    final previous = _pending[key] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) => action());
    _pending[key] = next;
    return next.whenComplete(() {
      if (identical(_pending[key], next)) _pending.remove(key);
    });
  }

  @override
  Future<void> saveRequest(
    String project,
    String session,
    String id,
    Map<String, Object?> trace,
  ) {
    // Copy/encode before an await: callers cannot mutate a queued trace.
    final encoded = encodeRagJsonl([trace]);
    final listKey = _key(project, session, 'requests');
    return _serial(listKey, () async {
      final key = _key(project, session, 'request:$id');
      if (await storage.read(key) != null) {
        throw StateError('Trace identities are immutable');
      }
      await storage.publish(key, encoded);
      final rows = await _read(listKey);
      await storage.publish(
        listKey,
        encodeRagJsonl([
          ...rows,
          {'id': id},
        ]),
      );
    });
  }

  @override
  Future<void> saveCompletion(
    String project,
    String session,
    String id,
    Map<String, Object?> completion,
  ) {
    final encoded = encodeRagJsonl([completion]);
    final key = _key(project, session, 'completion:$id');
    return _serial(key, () async {
      if (await storage.read(key) != null) {
        throw StateError('Completion identities are immutable');
      }
      await storage.publish(key, encoded);
    });
  }

  @override
  Future<void> saveDiagnostic(
    String project,
    String session,
    String id,
    Map<String, Object?> diagnostic,
  ) {
    final encoded = encodeRagJsonl([diagnostic]);
    final key = _key(project, session, 'diagnostic:$id');
    return _serial(key, () async {
      if (await storage.read(key) != null) {
        throw StateError('Validation diagnostics are immutable');
      }
      await storage.publish(key, encoded);
    });
  }

  @override
  Future<List<Map<String, dynamic>>> list(
    String project,
    String session,
  ) async {
    final rows = await _read(_key(project, session, 'requests'));
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final id = row['id'] as String;
      final trace = await _read(_key(project, session, 'request:$id'));
      if (trace.length != 1) {
        throw const FormatException('Missing request trace');
      }
      final completion = await _read(_key(project, session, 'completion:$id'));
      if (completion.length > 1) throw const FormatException('Invalid receipt');
      final diagnostic = await _read(_key(project, session, 'diagnostic:$id'));
      if (diagnostic.length > 1) {
        throw const FormatException('Invalid diagnostic');
      }
      result.add({
        ...trace.single,
        'completion': completion.singleOrNull,
        if (diagnostic.isNotEmpty) 'diagnostic': diagnostic.single,
      });
    }
    return result;
  }
}

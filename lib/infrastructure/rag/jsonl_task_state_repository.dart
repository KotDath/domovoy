import 'dart:convert';

import '../../core/llm/cancellation.dart';
import '../../core/rag/models.dart';
import '../../core/rag/task_state.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';

/// Separate namespace/keys; independent of session compaction and memory stores.
final class JsonlRagTaskStateRepository implements RagTaskStateRepository {
  JsonlRagTaskStateRepository(this.storage);
  final JsonlStreamStorage storage;
  final Map<String, Future<void>> _pending = {};
  String _key(String project, String session) =>
      ragHash(jsonEncode(['rag-task-state-v1', project, session]));

  Future<List<Map<String, dynamic>>> _rows(String key) async {
    final stream = await storage.read(key);
    if (stream == null) return [];
    final bytes = await stream.fold<List<int>>([], (a, b) => a..addAll(b));
    final raw = utf8.decode(bytes);
    if (!raw.endsWith('\n')) {
      throw const FormatException('Incomplete task state');
    }
    final lines = raw.substring(0, raw.length - 1).split('\n');
    final footer = jsonDecode(lines.removeLast()) as Map;
    final payload = lines.isEmpty ? '' : '${lines.join('\n')}\n';
    if (footer['type'] != 'end' ||
        footer['version'] != 1 ||
        footer['hash'] != ragHash(payload)) {
      throw const FormatException('Corrupt task state');
    }
    return lines.map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
  }

  RagTaskState _replay(
    List<Map<String, dynamic>> rows,
    String project,
    String session,
  ) {
    var state = RagTaskState(project: project, session: session);
    for (final row in rows) {
      final next = RagTaskState.fromJson(row);
      if (next.project != project ||
          next.session != session ||
          next.revision != state.revision + 1) {
        throw const FormatException('Task-state scope/revision mismatch');
      }
      state = next;
    }
    return state;
  }

  @override
  Future<RagTaskState> load(String project, String session) async =>
      _replay(await _rows(_key(project, session)), project, session);

  @override
  Future<void> save(
    RagTaskState state, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) {
    // Immutable encoding is captured before queueing/awaiting.
    final encoded = jsonEncode(state.toJson());
    final key = _key(state.project, state.session);
    final previous = _pending[key] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      checkRagCancellation(cancellation.isCancelled);
      final rows = await _rows(key);
      final current = _replay(rows, state.project, state.session);
      if (current.revision != expectedRevision ||
          state.revision != expectedRevision + 1) {
        throw const RagTaskStateConflict();
      }
      checkRagCancellation(cancellation.isCancelled);
      await storage.publish(
        key,
        encodeRagJsonl([...rows, jsonDecode(encoded) as Map<String, dynamic>]),
      );
    });
    _pending[key] = next;
    return next.whenComplete(() {
      if (identical(_pending[key], next)) _pending.remove(key);
    });
  }
}

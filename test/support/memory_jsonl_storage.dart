import 'dart:convert';

import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage.dart';

/// Deterministic in-memory [JsonlStreamStorage] with corruption hooks.
///
/// Tests address individual streams through [MemoryJsonlKeyCodec] so they can
/// replace bytes, append partial tails, or fail enumeration.
final class FakeMemoryJsonlStorage implements JsonlStreamStorage {
  final Map<String, List<int>> _streams = <String, List<int>>{};
  var failList = false;
  var failCleanup = false;

  Iterable<String> get keys => _streams.keys;

  void replaceText(String key, String text) {
    _streams[key] = utf8.encode(text);
  }

  void replaceBytes(String key, List<int> bytes) {
    _streams[key] = List<int>.from(bytes);
  }

  void appendText(String key, String fragment) {
    _streams[key] = <int>[...?_streams[key], ...utf8.encode(fragment)];
  }

  void appendBytes(String key, List<int> fragment) {
    _streams[key] = <int>[...?_streams[key], ...fragment];
  }

  @override
  Future<List<String>> listKeys() async {
    if (failList) {
      throw StateError('list failed');
    }
    return _streams.keys.toList()..sort();
  }

  @override
  Future<Stream<List<int>>?> read(String key) async {
    final bytes = _streams[key];
    if (bytes == null) {
      return null;
    }
    return Stream<List<int>>.value(List<int>.from(bytes));
  }

  @override
  Future<void> publish(String key, List<int> contents) async {
    _streams[key] = List<int>.from(contents);
  }

  @override
  Future<void> cleanup(String key) async {
    if (failCleanup) throw StateError('cleanup failed');
  }
}

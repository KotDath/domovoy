import '../../agents/jsonl/jsonl_stream_storage.dart';

JsonlStreamStorage createPlatformTaskJsonlStreamStorage() =>
    _UnsupportedTaskJsonlStorage();

final class _UnsupportedTaskJsonlStorage implements JsonlStreamStorage {
  Never _unsupported() =>
      throw UnsupportedError('Task JSONL storage is unavailable.');

  @override
  Future<void> cleanup(String key) => _unsupported();

  @override
  Future<List<String>> listKeys() => _unsupported();

  @override
  Future<void> publish(String key, List<int> contents) => _unsupported();

  @override
  Future<Stream<List<int>>?> read(String key) => _unsupported();
}

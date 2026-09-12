/// Storage boundary for one atomic, logical byte stream per opaque key.
///
/// Implementations may use immutable generations internally, but [publish]
/// must make either the previous complete value or [contents] observable.
abstract interface class JsonlStreamStorage {
  Future<List<String>> listKeys();

  Future<Stream<List<int>>?> read(String key);

  Future<void> publish(String key, List<int> contents);

  /// Best-effort removal of inactive generations for [key].
  Future<void> cleanup(String key);
}

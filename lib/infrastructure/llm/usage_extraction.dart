import '../../core/llm/json.dart';
import '../../core/llm/usage.dart';

/// A typed, dialect-owned path to one optional usage counter.
final class LlmUsageFieldPath {
  const LlmUsageFieldPath(this.segments);

  final List<String> segments;

  static LlmUsageFieldPath topLevel(String field) =>
      LlmUsageFieldPath(<String>[field]);

  static LlmUsageFieldPath nested(String object, String field) =>
      LlmUsageFieldPath(<String>[object, field]);
}

/// Reads all aliases before selecting a semantic value. A malformed ancestor
/// becomes an invalid alias rather than a transport exception.
LlmUsageCounter extractUsageCounter(
  Map<String, Object?> usage,
  Iterable<LlmUsageFieldPath> paths,
) {
  return LlmUsageCounter.fromAliases(
    paths.map((path) => _readPath(usage, path.segments)),
  );
}

Object? _readPath(Map<String, Object?> root, List<String> segments) {
  Object? current = root;
  for (final segment in segments) {
    if (current == null) {
      return null;
    }
    final map = asJsonObject(current);
    if (map == null) {
      return const _MalformedUsageValue();
    }
    if (!map.containsKey(segment)) {
      return null;
    }
    current = map[segment];
  }
  return current;
}

final class _MalformedUsageValue {
  const _MalformedUsageValue();
}

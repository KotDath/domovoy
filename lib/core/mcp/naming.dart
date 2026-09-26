import 'ids.dart';

/// Derives stable, provider-safe model-facing names for MCP tools.
///
/// The name depends only on `(connectionId, originalToolName)`, so it survives
/// alias renames and catalog refreshes. Ordinal disambiguation is applied by
/// [McpCatalogBuilder] when two different pairs still collide after
/// sanitization.
final class McpToolNamePolicy {
  const McpToolNamePolicy({
    this.prefix = 'mcp',
    this.maxLength = McpModelToolName.maxLength,
  }) : assert(maxLength > 0);

  final String prefix;
  final int maxLength;

  /// Candidate name for one server tool.
  String candidate({
    required McpConnectionId connectionId,
    required String originalToolName,
  }) {
    final connection = _segment(connectionId.value, fallback: 'server');
    final tool = _segment(originalToolName, fallback: 'tool');
    final base = '${prefix}_${connection}__$tool';
    if (base.length <= maxLength) {
      return base;
    }
    final digest = stableToolNameHash('${connectionId.value}\u0000$tool');
    final suffix = '_$digest';
    final available = maxLength - prefix.length - 1 - suffix.length;
    final truncated = _truncateSegment(
      base.substring(prefix.length + 1),
      available,
    );
    return '${prefix}_$truncated$suffix';
  }

  /// Appends `_2`, `_3`, ... while staying within [maxLength].
  String withOrdinal(String base, int ordinal) {
    if (ordinal <= 1) {
      return base;
    }
    final suffix = '_$ordinal';
    final head = _truncateSegment(base, maxLength - suffix.length);
    return '$head$suffix';
  }
}

/// Deterministic 8-character hash that is identical on VM and web.
///
/// Uses a polynomial rolling hash kept below 2^30 so JavaScript number
/// precision cannot change the result.
String stableToolNameHash(String value) {
  var hash = 7;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) % 0x3FFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String _segment(String value, {required String fallback}) {
  final sanitized = value
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^[_-]+|[_-]+$'), '');
  if (sanitized.isEmpty) {
    return fallback;
  }
  return sanitized;
}

String _truncateSegment(String value, int length) {
  if (length <= 0) {
    return '';
  }
  if (value.length <= length) {
    return value;
  }
  return value.substring(0, length);
}

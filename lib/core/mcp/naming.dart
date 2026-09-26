import 'errors.dart';
import 'ids.dart';

/// Derives stable, provider-safe model-facing names for MCP tools.
///
/// A name is a pure function of `(connectionId, originalToolName)`:
/// - when both identifiers are already canonical (`[A-Za-z0-9]` at the edges,
///   no `__` separator inside), the readable name `mcp_<connection>__<tool>`
///   is injective over that pair;
/// - otherwise a stable hash of the exact pair is appended, so the name never
///   changes when other tools or connections join or leave the catalog.
///
/// The rare full-name collision between two different pairs is detected by
/// `McpCatalogBuilder` and rejected explicitly instead of being silently
/// reordered.
class McpToolNamePolicy {
  McpToolNamePolicy({
    this.prefix = 'mcp',
    this.maxLength = McpModelToolName.maxLength,
  }) {
    if (maxLength < _minimumLength) {
      throwMcp(
        McpErrorKind.configuration,
        'Model tool name budget must be at least $_minimumLength characters.',
      );
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(prefix)) {
      throwMcp(
        McpErrorKind.configuration,
        'Model tool name prefix contains unsupported characters.',
      );
    }
  }

  static const _minimumLength = 17;
  static final RegExp _canonicalPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]*$',
  );

  final String prefix;
  final int maxLength;

  /// Stable model-facing name for one server tool.
  String candidate({
    required McpConnectionId connectionId,
    required String originalToolName,
  }) {
    final rawConnection = connectionId.value.trim();
    final rawTool = originalToolName.trim();
    if (_isCanonical(rawConnection) && _isCanonical(rawTool)) {
      final plain = '${prefix}_${rawConnection}__$rawTool';
      if (plain.length <= maxLength) {
        return plain;
      }
    }
    final connectionSegment = _segment(rawConnection, fallback: 'server');
    final toolSegment = _segment(rawTool, fallback: 'tool');
    final hash = stableToolNameHash('$rawConnection\u0000$rawTool');
    final suffix = '_$hash';
    final available = maxLength - prefix.length - 1 - 2 - suffix.length;
    var connectionBudget = (available * 3) ~/ 5;
    if (connectionBudget > available - 1) {
      connectionBudget = available - 1;
    }
    if (connectionBudget < 1) {
      connectionBudget = 1;
    }
    final connectionPart = _truncateSegment(
      connectionSegment,
      connectionBudget,
    );
    final toolPart = _truncateSegment(
      toolSegment,
      available - connectionPart.length,
    );
    return '${prefix}_${connectionPart}__$toolPart$suffix';
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

bool _isCanonical(String value) {
  if (value.isEmpty || !McpToolNamePolicy._canonicalPattern.hasMatch(value)) {
    return false;
  }
  if (value.contains('__')) {
    return false;
  }
  final last = value.codeUnitAt(value.length - 1);
  return _isAlphaNumeric(last);
}

bool _isAlphaNumeric(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

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

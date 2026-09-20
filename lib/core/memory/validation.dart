import '../projects/ids.dart';
import 'enums.dart';
import 'errors.dart';
import 'ids.dart';

/// Maximum number of Unicode code points in a normalized memory record.
const maxMemoryContentRunes = 4096;

/// Minimum number of Unicode code points in a normalized memory record.
const minMemoryContentRunes = 1;

/// Maximum number of Unicode code points in a retrieval query.
const maxMemoryQueryRunes = 512;

final _providerKey = RegExp(r'\bsk-[A-Za-z0-9_-]{16,}\b');
final _keyAssignment = RegExp(
  r'\b(api[_-]?key|secret|token|password|passwd|credential|bearer)\b\s*[:=]\s*\S{8,}',
  caseSensitive: false,
);
final _authorization = RegExp(
  r'\bauthorization\s*[:=]\s*(bearer|basic)\s+\S+',
  caseSensitive: false,
);
final _privateKey = RegExp(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----');
final _awsAccessKey = RegExp(r'\bAKIA[0-9A-Z]{16}\b');
final _githubToken = RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b');
final _longOpaqueToken = RegExp(r'[A-Za-z0-9+/_-]{48,}={0,2}');

/// Whether [content] appears to embed a credential that must never become a
/// memory record.
bool containsMemorySecret(String content) {
  return _providerKey.hasMatch(content) ||
      _keyAssignment.hasMatch(content) ||
      _authorization.hasMatch(content) ||
      _privateKey.hasMatch(content) ||
      _awsAccessKey.hasMatch(content) ||
      _githubToken.hasMatch(content) ||
      _longOpaqueToken.hasMatch(content);
}

void assertNoMemorySecret(String content) {
  if (containsMemorySecret(content)) {
    throwMemory(
      MemoryErrorKind.secretDetected,
      'Memory content contains a detected secret.',
    );
  }
}

/// Trims, bounds, and security-checks durable memory content. Control characters
/// other than tab, line feed, and carriage return are rejected rather than
/// silently stripped so callers cannot smuggle prompt-control bytes.
String normalizeMemoryContent(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Memory content must not be blank.',
    );
  }
  for (final rune in trimmed.runes) {
    if (rune == 0 ||
        rune == 0x7F ||
        (rune < 0x20 && !_isAllowedControl(rune))) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Memory content contains a disallowed control character.',
      );
    }
  }
  final length = trimmed.runes.length;
  if (length < minMemoryContentRunes || length > maxMemoryContentRunes) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Memory content must be between $minMemoryContentRunes and '
      '$maxMemoryContentRunes characters.',
    );
  }
  assertNoMemorySecret(trimmed);
  return trimmed;
}

/// Trims and bounds a retrieval query. Queries are transient and never become
/// records, so they are not secret-screened.
String normalizeMemoryQuery(String source) {
  final trimmed = source.trim();
  if (trimmed.runes.length > maxMemoryQueryRunes) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Memory query must not exceed $maxMemoryQueryRunes characters.',
    );
  }
  for (final rune in trimmed.runes) {
    if (rune == 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Memory query contains a disallowed control character.',
      );
    }
  }
  return trimmed;
}

/// Enforces the layer/scope/project invariant shared by entries and candidates.
void validateMemoryLayerScope({
  required MemoryLayer layer,
  required MemoryScope scope,
  required ProjectId? projectId,
}) {
  if (layer.requiredScope != scope) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Layer ${layer.name} requires ${layer.requiredScope.name} scope.',
    );
  }
  if (scope.requiresProjectId && projectId == null) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Project-scoped memory requires a project id.',
    );
  }
  if (!scope.requiresProjectId && projectId != null) {
    throwMemory(
      MemoryErrorKind.configuration,
      'Global memory must not carry a project id.',
    );
  }
}

/// Rejects duplicate source identities while preserving their first-seen order.
void validateMemorySourceIds(List<MemorySourceId> sourceIds) {
  final seen = <String>{};
  for (final sourceId in sourceIds) {
    if (!seen.add(sourceId.value)) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Memory source identities must be unique.',
      );
    }
  }
}

bool _isAllowedControl(int rune) =>
    rune == 0x09 || rune == 0x0A || rune == 0x0D;

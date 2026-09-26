/// Shared arXiv identifier normalization for the research wire contracts.
///
/// The plan requires that a `Paper` identifier is normalized without its
/// version and that `abstractUrl` is built from the verified identifier rather
/// than copied from arbitrary model text.
library;

import 'errors.dart';

/// Matches a modern arXiv identifier: `2501.01234`.
final RegExp _modernId = RegExp(r'^(\d{4}\.\d{4,5})$');

/// Matches a legacy arXiv identifier: `math.GT/0309136`.
final RegExp _legacyId = RegExp(r'^([a-z-]+(?:\.[A-Z]{2})?/\d{7})$');

/// Matches a version suffix such as `v2`.
final RegExp _versionSuffix = RegExp(r'v(\d{1,4})$', caseSensitive: false);

/// Normalized arXiv identifier without a version suffix.
final class ArxivId {
  ArxivId(String raw) : value = normalizeArxivId(raw);

  factory ArxivId.fromJson(Object? json) {
    if (json is! String) {
      throwResearch(ResearchErrorKind.invalidArxivId, 'arXiv ID must be text.');
    }
    return ArxivId(json);
  }

  /// Identifier without the `vN` suffix, for example `2501.01234`.
  final String value;

  /// Canonical abstract page URL derived from [value].
  Uri get abstractUrl => Uri.parse('https://arxiv.org/abs/$value');

  /// Renders `arxiv:2501.01234v2` when [version] is supplied.
  String withVersion(String? version) =>
      version == null ? value : '$value$version';

  Map<String, Object?> toJson() => <String, Object?>{'arxivId': value};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ArxivId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Normalizes [raw] into an arXiv identifier without a version suffix.
///
/// Accepts an optional `arXiv:` prefix, surrounding whitespace and a trailing
/// `vN` marker. Anything else - URLs, blank strings, arbitrary model text - is
/// rejected so callers never build links from unverified text.
String normalizeArxivId(String raw) {
  var candidate = raw.trim();
  if (candidate.isEmpty) {
    throwResearch(ResearchErrorKind.invalidArxivId, 'arXiv ID is empty.');
  }
  if (candidate.toLowerCase().startsWith('arxiv:')) {
    candidate = candidate.substring('arxiv:'.length).trim();
  }
  final versionMatch = _versionSuffix.firstMatch(candidate);
  if (versionMatch != null) {
    candidate = candidate.substring(0, versionMatch.start).trim();
  }
  if (candidate.contains('://') ||
      candidate.contains('?') ||
      candidate.contains('#') ||
      candidate.contains(RegExp(r'\s'))) {
    throwResearch(
      ResearchErrorKind.invalidArxivId,
      'arXiv ID must not be a URL or contain whitespace.',
    );
  }
  if (_modernId.hasMatch(candidate) || _legacyId.hasMatch(candidate)) {
    return candidate;
  }
  throwResearch(
    ResearchErrorKind.invalidArxivId,
    'arXiv ID "$candidate" does not match a known identifier format.',
  );
}

/// Extracts a normalized version such as `v2` from [raw], or returns `null`.
///
/// The version is stored separately from the normalized identifier.
String? versionFromArxivInput(String raw) {
  final candidate = raw.trim();
  if (candidate.isEmpty) {
    return null;
  }
  final versionMatch = _versionSuffix.firstMatch(candidate);
  if (versionMatch == null) {
    return null;
  }
  return 'v${versionMatch.group(1)}';
}

/// Parses a normalized `vN` [version] value.
String? normalizeArxivVersion(String? version) {
  if (version == null) {
    return null;
  }
  final candidate = version.trim();
  if (candidate.isEmpty) {
    return null;
  }
  final match = RegExp(r'^v?(\d{1,4})$').firstMatch(candidate);
  if (match == null) {
    throwResearch(
      ResearchErrorKind.invalidField,
      'arXiv version must look like "v2".',
    );
  }
  return 'v${match.group(1)}';
}

import 'arxiv_id.dart';
import 'errors.dart';

/// Version of the shared `Paper` wire contract.
///
/// Bump only together with a replay/migration path: consumers reject unknown
/// versions instead of partially accepting a new shape.
const paperSchemaVersion = 1;

/// Field names of the complete Paper v1 wire contract.
///
/// [Paper.fromJson] stays tolerant of additional fields so existing consumers
/// keep working; boundaries that must reject smuggled data - the `library`
/// tool input and the library JSONL replay - call [verifyPaperV1Fields]
/// explicitly.
const paperV1Fields = <String>{
  'schemaVersion',
  'arxivId',
  'version',
  'title',
  'authors',
  'abstract',
  'categories',
  'publishedAt',
  'updatedAt',
  'abstractUrl',
};

/// Rejects [json] when it is not an object or carries a field outside
/// [paperV1Fields], for example a smuggled `pdfUrl` or `apiKey`.
void verifyPaperV1Fields(Object? json) {
  verifyResearchFields(json, paperV1Fields, 'Paper v1');
}

/// Versioned, SDK-independent description of one arXiv paper.
///
/// This is the boundary type shared by the `arxiv`, `digest` and `library`
/// MCP servers. It never depends on `mcp_dart`, so it can be validated in
/// `core` tests and reused by B3-B5 fixtures.
final class Paper {
  Paper({
    required String arxivId,
    String? version,
    required String title,
    required List<String> authors,
    required String abstractText,
    required List<String> categories,
    required DateTime publishedAt,
    required DateTime updatedAt,
  }) : arxivId = ArxivId(arxivId),
       version = normalizeArxivVersion(version),
       title = _requireNonBlank(title, 'title'),
       authors = _normalizedStrings(authors, 'authors', allowEmpty: false),
       abstractText = _requireNonBlank(abstractText, 'abstract'),
       categories = _normalizedStrings(
         categories,
         'categories',
         allowEmpty: true,
       ),
       publishedAt = publishedAt.toUtc(),
       updatedAt = updatedAt.toUtc();

  factory Paper.fromJson(Object? json) {
    final map = _decodeObject(json);
    _requireVersion(map);
    final arxivId = ArxivId.fromJson(map['arxivId']);
    final abstractUrl = map['abstractUrl'];
    if (abstractUrl != null) {
      _verifyAbstractUrl(abstractUrl, arxivId);
    }
    return Paper(
      arxivId: arxivId.value,
      version: map['version'] == null ? null : _requireText(map, 'version'),
      title: _requireText(map, 'title'),
      authors: _requireStringList(map, 'authors'),
      abstractText: _requireText(map, 'abstract'),
      categories: _requireStringList(map, 'categories'),
      publishedAt: _requireUtcDate(map, 'publishedAt'),
      updatedAt: _requireUtcDate(map, 'updatedAt'),
    );
  }

  static const jsonType = 'research.paper';

  final ArxivId arxivId;

  /// Version marker such as `v2`, stored apart from the normalized identifier.
  final String? version;
  final String title;
  final List<String> authors;
  final String abstractText;
  final List<String> categories;
  final DateTime publishedAt;
  final DateTime updatedAt;

  /// Always derived from the verified identifier, never copied from input.
  Uri get abstractUrl => arxivId.abstractUrl;

  String get displayId => arxivId.withVersion(version);

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': paperSchemaVersion,
    'arxivId': arxivId.value,
    if (version != null) 'version': version,
    'title': title,
    'authors': authors,
    'abstract': abstractText,
    'categories': categories,
    'publishedAt': publishedAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'abstractUrl': abstractUrl.toString(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Paper &&
          other.arxivId == arxivId &&
          other.version == version &&
          other.title == title &&
          _listEquals(other.authors, authors) &&
          other.abstractText == abstractText &&
          _listEquals(other.categories, categories) &&
          other.publishedAt == publishedAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    arxivId,
    version,
    title,
    Object.hashAll(authors),
    abstractText,
    Object.hashAll(categories),
    publishedAt,
    updatedAt,
  );

  @override
  String toString() => 'Paper($displayId, "$title")';
}

Map<String, Object?> _decodeObject(Object? json) {
  if (json is! Map) {
    throwResearch(ResearchErrorKind.format, 'Expected a JSON object.');
  }
  final map = <String, Object?>{};
  json.forEach((key, value) {
    if (key is! String) {
      throwResearch(ResearchErrorKind.format, 'JSON keys must be strings.');
    }
    map[key] = value;
  });
  return map;
}

void _requireVersion(Map<String, Object?> map) {
  final version = map['schemaVersion'];
  if (version != paperSchemaVersion) {
    throwResearch(
      ResearchErrorKind.unsupportedVersion,
      'Unsupported Paper schemaVersion "$version".',
    );
  }
}

String _requireText(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throwResearch(
      ResearchErrorKind.invalidField,
      'Expected string field "$key".',
    );
  }
  return value;
}

String _requireNonBlank(String value, String key) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throwResearch(
      ResearchErrorKind.invalidField,
      'Expected non-blank field "$key".',
    );
  }
  return trimmed;
}

List<String> _requireStringList(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! List) {
    throwResearch(
      ResearchErrorKind.invalidField,
      'Expected list field "$key".',
    );
  }
  return _normalizedStrings(
    value
        .map((item) {
          if (item is! String) {
            throwResearch(
              ResearchErrorKind.invalidField,
              'Expected text items in "$key".',
            );
          }
          return item;
        })
        .toList(growable: false),
    key,
    allowEmpty: true,
  );
}

List<String> _normalizedStrings(
  List<String> values,
  String key, {
  required bool allowEmpty,
}) {
  final normalized = values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (!allowEmpty && normalized.isEmpty) {
    throwResearch(
      ResearchErrorKind.invalidField,
      'Expected at least one item in "$key".',
    );
  }
  return List<String>.unmodifiable(normalized);
}

DateTime _requireUtcDate(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throwResearch(
      ResearchErrorKind.invalidField,
      'Expected ISO 8601 text for "$key".',
    );
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throwResearch(
      ResearchErrorKind.invalidField,
      'Expected ISO 8601 text for "$key".',
    );
  }
  return parsed.toUtc();
}

void _verifyAbstractUrl(Object? value, ArxivId arxivId) {
  if (value is! String) {
    throwResearch(
      ResearchErrorKind.invalidField,
      'Expected string field "abstractUrl".',
    );
  }
  final expected = arxivId.abstractUrl.toString();
  if (value.trim() != expected) {
    throwResearch(
      ResearchErrorKind.invalidArxivId,
      'abstractUrl must be derived from the arXiv ID.',
    );
  }
}

bool _listEquals(List<String> left, List<String> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

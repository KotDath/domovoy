import 'arxiv_id.dart';
import 'errors.dart';
import 'paper.dart';

/// Version of the shared `Digest` wire contract.
const digestSchemaVersion = 1;

/// The only v1 source scope: the digest was produced from abstracts.
const digestSourceScopeAbstract = 'abstract';

/// One grounded finding inside a [Digest].
final class DigestItem {
  DigestItem({
    required String arxivId,
    required String finding,
    String? limitation,
  }) : arxivId = ArxivId(arxivId),
       finding = _requireNonBlank(finding, 'finding'),
       limitation = limitation == null
           ? null
           : _requireNonBlank(limitation, 'limitation');

  factory DigestItem.fromJson(Object? json) {
    final map = _decodeObject(json);
    final arxivId = ArxivId.fromJson(map['arxivId']);
    final abstractUrl = map['abstractUrl'];
    if (abstractUrl != null) {
      if (abstractUrl is! String ||
          abstractUrl.trim() != arxivId.abstractUrl.toString()) {
        throwResearch(
          ResearchErrorKind.invalidArxivId,
          'Digest item abstractUrl must be derived from the arXiv ID.',
        );
      }
    }
    return DigestItem(
      arxivId: arxivId.value,
      finding: _requireText(map, 'finding'),
      limitation: map['limitation'] == null
          ? null
          : _requireText(map, 'limitation'),
    );
  }

  final ArxivId arxivId;
  final String finding;
  final String? limitation;

  Uri get abstractUrl => arxivId.abstractUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'arxivId': arxivId.value,
    'abstractUrl': abstractUrl.toString(),
    'finding': finding,
    if (limitation != null) 'limitation': limitation,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DigestItem &&
          other.arxivId == arxivId &&
          other.finding == finding &&
          other.limitation == limitation;

  @override
  int get hashCode => Object.hash(arxivId, finding, limitation);
}

/// Versioned synthesis produced from a bounded set of [Paper] abstracts.
final class Digest {
  Digest({
    required String topic,
    required String overview,
    required List<DigestItem> items,
    required DateTime generatedAt,
    String sourceScope = digestSourceScopeAbstract,
  }) : topic = _requireNonBlank(topic, 'topic'),
       sourceScope = _normalizeSourceScope(sourceScope),
       overview = _requireNonBlank(overview, 'overview'),
       items = List<DigestItem>.unmodifiable(items),
       generatedAt = generatedAt.toUtc() {
    if (this.items.isEmpty) {
      throwResearch(
        ResearchErrorKind.invalidField,
        'Expected at least one digest item.',
      );
    }
  }

  factory Digest.fromJson(Object? json) {
    final map = _decodeObject(json);
    final version = map['schemaVersion'];
    if (version != digestSchemaVersion) {
      throwResearch(
        ResearchErrorKind.unsupportedVersion,
        'Unsupported Digest schemaVersion "$version".',
      );
    }
    final rawItems = map['items'];
    if (rawItems is! List || rawItems.isEmpty) {
      throwResearch(
        ResearchErrorKind.invalidField,
        'Expected a non-empty "items" list.',
      );
    }
    return Digest(
      topic: _requireText(map, 'topic'),
      sourceScope: _requireText(map, 'sourceScope'),
      overview: _requireText(map, 'overview'),
      items: rawItems.map(DigestItem.fromJson).toList(growable: false),
      generatedAt: _requireUtcDate(map, 'generatedAt'),
    );
  }

  static const jsonType = 'research.digest';

  final String topic;

  /// Always `abstract` for schema version 1.
  final String sourceScope;
  final String overview;
  final List<DigestItem> items;
  final DateTime generatedAt;

  List<String> get arxivIds =>
      items.map((item) => item.arxivId.value).toList(growable: false);

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': digestSchemaVersion,
    'topic': topic,
    'sourceScope': sourceScope,
    'overview': overview,
    'items': items.map((item) => item.toJson()).toList(growable: false),
    'generatedAt': generatedAt.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Digest &&
          other.topic == topic &&
          other.sourceScope == sourceScope &&
          other.overview == overview &&
          _itemsEqual(other.items, items) &&
          other.generatedAt == generatedAt;

  @override
  int get hashCode => Object.hash(
    topic,
    sourceScope,
    overview,
    Object.hashAll(items),
    generatedAt,
  );

  @override
  String toString() => 'Digest($topic, ${items.length} items)';
}

/// Verifies that every digest item references one of the supplied papers.
///
/// `library.save_digest` uses this before persisting so a digest cannot smuggle
/// in a paper that was never returned by `arxiv`.
void verifyDigestItemsBelongToPapers(Digest digest, Iterable<Paper> papers) {
  final known = papers.map((paper) => paper.arxivId.value).toSet();
  for (final item in digest.items) {
    if (!known.contains(item.arxivId.value)) {
      throwResearch(
        ResearchErrorKind.invalidArxivId,
        'Digest item ${item.arxivId.value} is not part of the supplied papers.',
      );
    }
  }
}

String _normalizeSourceScope(String value) {
  final normalized = value.trim();
  if (normalized != digestSourceScopeAbstract) {
    throwResearch(
      ResearchErrorKind.unsupportedVersion,
      'Unsupported digest sourceScope "$normalized".',
    );
  }
  return normalized;
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

bool _itemsEqual(List<DigestItem> left, List<DigestItem> right) {
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

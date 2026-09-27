import '../../../../core/research/research.dart';
import 'arxiv_errors.dart';

/// Parsed, normalized result of one arXiv Atom response.
final class ArxivAtomFeed {
  const ArxivAtomFeed({
    required this.papers,
    this.totalResults,
    this.startIndex,
    this.itemsPerPage,
  });

  /// Entries in feed order; callers still normalize, dedupe and sort.
  final List<Paper> papers;

  /// `opensearch:totalResults` of the query, when the feed carries it.
  final int? totalResults;

  /// `opensearch:startIndex`, when present.
  final int? startIndex;

  /// `opensearch:itemsPerPage`, when present.
  final int? itemsPerPage;
}

/// Strict, bounded parser for the official arXiv Atom response.
///
/// The parser deliberately does not depend on a general XML package: the
/// response shape is a small, well-defined Atom subset, and a local scanner
/// keeps the dependency set unchanged. It never resolves entities from a DTD,
/// never follows external references and rejects anything it cannot prove
/// bounded: unmatched tags, unknown entities, control characters, too many
/// entries and oversized text. Every failure is an [ArxivFailureKind.protocol]
/// failure, and the raw response text never reaches the tool result.
final class ArxivAtomParser {
  const ArxivAtomParser({
    this.maxEntries = 100,
    this.maxDepth = 32,
    this.maxNodes = 20000,
    this.maxTextCharacters = 2000000,
    this.maxTitleCharacters = 2048,
    this.maxAbstractCharacters = 20000,
    this.maxAuthorNameCharacters = 512,
    this.maxAuthors = 100,
    this.maxCategories = 20,
    this.maxCategoryCharacters = 64,
  });

  final int maxEntries;
  final int maxDepth;
  final int maxNodes;
  final int maxTextCharacters;
  final int maxTitleCharacters;
  final int maxAbstractCharacters;
  final int maxAuthorNameCharacters;
  final int maxAuthors;
  final int maxCategories;
  final int maxCategoryCharacters;

  static const _arxivCategoryScheme = 'http://arxiv.org/schemas/atom';
  static const _absMarker = '/abs/';
  static final Set<String> _arxivHosts = <String>{
    'arxiv.org',
    'www.arxiv.org',
    'export.arxiv.org',
  };

  /// Parses [xml] into normalized [Paper] objects.
  ArxivAtomFeed parse(String xml) {
    if (xml.trim().isEmpty) {
      throwArxiv(ArxivFailureKind.protocol, 'arXiv вернул пустой ответ.');
    }
    final root = _XmlScanner(
      xml,
      maxDepth: maxDepth,
      maxNodes: maxNodes,
      maxTextCharacters: maxTextCharacters,
    ).parse();
    if (root.localName != 'feed') {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv не является Atom-лентой.',
      );
    }
    final entries = root.childrenNamed('entry').toList(growable: false);
    if (entries.length > maxEntries) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит слишком много записей.',
      );
    }
    return ArxivAtomFeed(
      papers: List<Paper>.unmodifiable(entries.map(_paperFromEntry)),
      totalResults: _optionalCount(root, 'totalResults'),
      startIndex: _optionalCount(root, 'startIndex'),
      itemsPerPage: _optionalCount(root, 'itemsPerPage'),
    );
  }

  Paper _paperFromEntry(_XmlElement entry) {
    final idText = entry.firstChildText('id');
    if (idText == null || idText.isEmpty) {
      throwArxiv(ArxivFailureKind.protocol, 'Запись arXiv без идентификатора.');
    }
    if (idText.contains('/api/errors')) {
      _throwApiError(idText);
    }
    final rawId = _extractAbsId(idText);
    final String arxivId;
    final String? version;
    try {
      arxivId = normalizeArxivId(rawId);
      version = versionFromArxivInput(rawId);
    } on ResearchException {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит некорректный идентификатор записи.',
      );
    }
    final publishedAt = _requiredDate(entry, 'published');
    final updatedAt = _requiredDate(entry, 'updated');
    try {
      return Paper(
        arxivId: arxivId,
        version: version,
        title: _requiredText(entry, 'title', maxTitleCharacters),
        authors: _authors(entry),
        abstractText: _requiredText(entry, 'summary', maxAbstractCharacters),
        categories: _categories(entry),
        publishedAt: publishedAt,
        updatedAt: updatedAt,
      );
    } on ResearchException {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит некорректное поле записи.',
      );
    }
  }

  /// arXiv returns query errors as an Atom feed with one error entry.
  ///
  /// Only the sanitized error-code prefix from the fragment is kept; the raw
  /// server text is never repeated back to the caller.
  Never _throwApiError(String idText) {
    final hash = idText.indexOf('#');
    final fragment = hash >= 0 ? idText.substring(hash + 1) : '';
    final match = RegExp(r'^([a-z_]{1,48})').firstMatch(fragment);
    final label = match?.group(1) ?? 'request_rejected';
    throwArxiv(
      ArxivFailureKind.invalidInput,
      'arXiv отклонил запрос ($label).',
    );
  }

  String _extractAbsId(String idText) {
    final uri = Uri.tryParse(idText);
    if (uri == null || !_arxivHosts.contains(uri.host)) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Запись arXiv ссылается на неизвестный хост.',
      );
    }
    final index = uri.path.indexOf(_absMarker);
    if (index < 0) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Запись arXiv не содержит ссылку на страницу abs.',
      );
    }
    final rawId = uri.path.substring(index + _absMarker.length);
    if (rawId.isEmpty || rawId.endsWith('/')) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Запись arXiv содержит некорректный идентификатор.',
      );
    }
    return rawId;
  }

  String _requiredText(_XmlElement element, String name, int maxCharacters) {
    final text = element.firstChildText(name);
    if (text == null || text.isEmpty) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv не содержит поле "$name".',
      );
    }
    if (text.length > maxCharacters) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Поле "$name" ответа arXiv превысило лимит $maxCharacters символов.',
      );
    }
    return text;
  }

  DateTime _requiredDate(_XmlElement element, String name) {
    final text = element.firstChildText(name);
    final parsed = text == null ? null : DateTime.tryParse(text);
    if (parsed == null) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит некорректную дату "$name".',
      );
    }
    return parsed.toUtc();
  }

  List<String> _authors(_XmlElement entry) {
    final authors = <String>[];
    for (final author in entry.childrenNamed('author')) {
      final name = author.firstChildText('name');
      if (name == null || name.isEmpty) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит автора без имени.',
        );
      }
      if (name.length > maxAuthorNameCharacters) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Имя автора в ответе arXiv превысило лимит.',
        );
      }
      authors.add(name);
      if (authors.length > maxAuthors) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит слишком много авторов.',
        );
      }
    }
    return List<String>.unmodifiable(authors);
  }

  List<String> _categories(_XmlElement entry) {
    final categories = <String>[];
    final primary = entry.firstChild('primary_category')?.attribute('term');
    if (primary != null) {
      _addCategory(categories, primary);
    }
    for (final category in entry.childrenNamed('category')) {
      final scheme = category.attribute('scheme');
      if (scheme != null && scheme != _arxivCategoryScheme) {
        // ACM/MSC classifications are metadata, not arXiv categories.
        continue;
      }
      final term = category.attribute('term');
      if (term == null || term.isEmpty) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит категорию без термина.',
        );
      }
      _addCategory(categories, term);
    }
    return List<String>.unmodifiable(categories);
  }

  void _addCategory(List<String> categories, String term) {
    final candidate = term.trim();
    if (candidate.isEmpty ||
        candidate.length > maxCategoryCharacters ||
        candidate.contains(RegExp(r'[\s\u0000-\u001F\u007F]'))) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит некорректную категорию.',
      );
    }
    if (!categories.contains(candidate)) {
      categories.add(candidate);
    }
    if (categories.length > maxCategories) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит слишком много категорий.',
      );
    }
  }

  int? _optionalCount(_XmlElement feed, String name) {
    final text = feed.firstChildText(name);
    if (text == null) {
      return null;
    }
    final value = int.tryParse(text);
    if (value == null || value < 0) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит некорректное поле "$name".',
      );
    }
    return value;
  }
}

final class _XmlElement {
  _XmlElement(this.localName);

  /// Tag name without the namespace prefix, for example `entry`.
  final String localName;
  final Map<String, String> attributes = <String, String>{};
  final List<_XmlElement> children = <_XmlElement>[];
  final StringBuffer text = StringBuffer();

  Iterable<_XmlElement> childrenNamed(String name) =>
      children.where((child) => child.localName == name);

  _XmlElement? firstChild(String name) {
    for (final child in children) {
      if (child.localName == name) {
        return child;
      }
    }
    return null;
  }

  /// Collapsed direct text of the first child named [name], or `null`.
  String? firstChildText(String name) {
    final child = firstChild(name);
    if (child == null) {
      return null;
    }
    return _collapseWhitespace(child.text.toString());
  }

  String? attribute(String name) {
    final direct = attributes[name];
    if (direct != null) {
      return direct;
    }
    for (final entry in attributes.entries) {
      final separator = entry.key.indexOf(':');
      if (separator >= 0 && entry.key.substring(separator + 1) == name) {
        return entry.value;
      }
    }
    return null;
  }
}

final class _XmlScanner {
  _XmlScanner(
    this._source, {
    required this.maxDepth,
    required this.maxNodes,
    required this.maxTextCharacters,
  });

  static final RegExp _name = RegExp(r'[A-Za-z_][A-Za-z0-9_.:-]*');
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _entity = RegExp(
    r'&(#x[0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z][A-Za-z0-9]{1,31});',
  );

  final String _source;
  final int maxDepth;
  final int maxNodes;
  final int maxTextCharacters;

  int _index = 0;
  int _nodeCount = 0;
  int _textCount = 0;

  _XmlElement parse() {
    _skipMisc();
    if (!_startsWith('<') || _startsWith('</')) {
      throwArxiv(ArxivFailureKind.protocol, 'Ответ arXiv не является XML.');
    }
    final root = _parseElement(0);
    _skipMisc();
    if (_index != _source.length) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит данные после XML-документа.',
      );
    }
    return root;
  }

  void _skipMisc() {
    while (true) {
      _skipWhitespace();
      if (_startsWith('<!--')) {
        _skipComment();
        continue;
      }
      if (_startsWith('<?')) {
        _skipUntil('?>', 'инструкцию обработки');
        continue;
      }
      break;
    }
  }

  _XmlElement _parseElement(int depth) {
    if (depth > maxDepth) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv слишком глубоко вложен.',
      );
    }
    if (!_startsWith('<')) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит некорректный XML.',
      );
    }
    _index += 1;
    final nameMatch = _name.matchAsPrefix(_source, _index);
    if (nameMatch == null) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит некорректный тег.',
      );
    }
    _index = nameMatch.end;
    _nodeCount += 1;
    if (_nodeCount > maxNodes) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит слишком много элементов.',
      );
    }
    final element = _XmlElement(_localName(nameMatch.group(0)!));
    if (_readAttributes(element)) {
      return element;
    }
    _readChildren(element, depth);
    return element;
  }

  /// Consumes attributes up to `>`; returns `true` for a self-closed tag.
  bool _readAttributes(_XmlElement element) {
    while (true) {
      _skipWhitespace();
      if (_startsWith('/>')) {
        _index += 2;
        return true;
      }
      if (_startsWith('>')) {
        _index += 1;
        return false;
      }
      final nameMatch = _name.matchAsPrefix(_source, _index);
      if (nameMatch == null) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит некорректный атрибут.',
        );
      }
      _index = nameMatch.end;
      _skipWhitespace();
      if (!_startsWith('=')) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит атрибут без значения.',
        );
      }
      _index += 1;
      _skipWhitespace();
      if (_index >= _source.length) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv обрывается внутри атрибута.',
        );
      }
      final quote = _source[_index];
      if (quote != '"' && quote != "'") {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит незакавыченный атрибут.',
        );
      }
      final end = _source.indexOf(quote, _index + 1);
      if (end < 0) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит незакрытый атрибут.',
        );
      }
      final rawValue = _source.substring(_index + 1, end);
      _index = end + 1;
      element.attributes[_localName(nameMatch.group(0)!)] = _decode(rawValue);
    }
  }

  void _readChildren(_XmlElement element, int depth) {
    while (true) {
      if (_index >= _source.length) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит незакрытый тег.',
        );
      }
      if (_startsWith('</')) {
        _index += 2;
        final nameMatch = _name.matchAsPrefix(_source, _index);
        if (nameMatch == null) {
          throwArxiv(
            ArxivFailureKind.protocol,
            'Ответ arXiv содержит некорректный закрывающий тег.',
          );
        }
        _index = nameMatch.end;
        _skipWhitespace();
        if (!_startsWith('>')) {
          throwArxiv(
            ArxivFailureKind.protocol,
            'Ответ arXiv содержит некорректный закрывающий тег.',
          );
        }
        _index += 1;
        if (_localName(nameMatch.group(0)!) != element.localName) {
          throwArxiv(
            ArxivFailureKind.protocol,
            'Ответ arXiv содержит несовпадающие теги.',
          );
        }
        return;
      }
      if (_startsWith('<!--')) {
        _skipComment();
        continue;
      }
      if (_startsWith('<![CDATA[')) {
        final end = _source.indexOf(']]>', _index + 9);
        if (end < 0) {
          throwArxiv(
            ArxivFailureKind.protocol,
            'Ответ arXiv содержит незакрытый CDATA.',
          );
        }
        final value = _source.substring(_index + 9, end);
        element.text.write(value);
        _bumpText(value.length);
        _index = end + 3;
        continue;
      }
      if (_startsWith('<?')) {
        _skipUntil('?>', 'инструкцию обработки');
        continue;
      }
      if (_startsWith('<!')) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит неподдерживаемую декларацию.',
        );
      }
      if (_startsWith('<')) {
        element.children.add(_parseElement(depth + 1));
        continue;
      }
      final next = _source.indexOf('<', _index);
      if (next < 0) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит незакрытый тег.',
        );
      }
      final rawText = _source.substring(_index, next);
      _index = next;
      final value = _decode(rawText);
      element.text.write(value);
      _bumpText(value.length);
    }
  }

  void _bumpText(int added) {
    _textCount += added;
    if (_textCount > maxTextCharacters) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит слишком много текста.',
      );
    }
  }

  String _decode(String raw) {
    if (!raw.contains('&')) {
      return raw;
    }
    final buffer = StringBuffer();
    var cursor = 0;
    while (true) {
      final amp = raw.indexOf('&', cursor);
      if (amp < 0) {
        buffer.write(raw.substring(cursor));
        return buffer.toString();
      }
      buffer.write(raw.substring(cursor, amp));
      final match = _entity.matchAsPrefix(raw, amp);
      if (match == null) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит некорректную XML-сущность.',
        );
      }
      buffer.write(_entityValue(match.group(1)!));
      cursor = match.end;
    }
  }

  String _entityValue(String token) {
    if (token.startsWith('#')) {
      final isHex = token.startsWith('#x') || token.startsWith('#X');
      final int code;
      try {
        code = isHex
            ? int.parse(token.substring(2), radix: 16)
            : int.parse(token.substring(1));
      } on FormatException {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит некорректную XML-сущность.',
        );
      }
      if (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит управляющий символ.',
        );
      }
      if (code > 0x10FFFF) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv содержит некорректную XML-сущность.',
        );
      }
      return String.fromCharCode(code);
    }
    return switch (token) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      'apos' => "'",
      _ => throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит неизвестную XML-сущность.',
      ),
    };
  }

  void _skipComment() {
    final end = _source.indexOf('-->', _index + 4);
    if (end < 0) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит незакрытый комментарий.',
      );
    }
    _index = end + 3;
  }

  void _skipUntil(String terminator, String label) {
    final end = _source.indexOf(terminator, _index + 2);
    if (end < 0) {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv содержит незакрытую $label.',
      );
    }
    _index = end + terminator.length;
  }

  bool _startsWith(String value) => _source.startsWith(value, _index);

  void _skipWhitespace() {
    final match = _whitespace.matchAsPrefix(_source, _index);
    if (match != null) {
      _index = match.end;
    }
  }

  static String _localName(String name) {
    final separator = name.indexOf(':');
    return separator < 0 ? name : name.substring(separator + 1);
  }
}

String _collapseWhitespace(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

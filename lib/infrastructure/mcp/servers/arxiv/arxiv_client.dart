import 'dart:async';

import '../../../../core/research/research.dart';
import 'arxiv_atom.dart';
import 'arxiv_errors.dart';
import 'arxiv_http.dart';

/// Default number of results of `search_papers`.
const defaultArxivSearchLimit = 10;

/// Hard upper bound of `search_papers.limit` (documented API range 1-30).
const maxArxivSearchLimit = 30;

/// Official arXiv API query endpoint (the Atom response of the user manual).
final Uri defaultArxivEndpoint = Uri.parse(
  'https://export.arxiv.org/api/query',
);

/// Injectable clock so rate limiting and cache TTL are deterministic in tests.
abstract interface class ArxivClock {
  DateTime nowUtc();

  Future<void> sleep(Duration duration);
}

/// Production clock backed by `DateTime.now()` and `Future.delayed`.
final class SystemArxivClock implements ArxivClock {
  const SystemArxivClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();

  @override
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);
}

/// Documented values of the API `sortBy` parameter.
enum ArxivSortBy {
  relevance('relevance'),
  lastUpdatedDate('lastUpdatedDate'),
  submittedDate('submittedDate');

  const ArxivSortBy(this.wireName);

  final String wireName;
}

/// Validated request of `search_papers`.
final class ArxivSearchRequest {
  ArxivSearchRequest({
    required String query,
    String? category,
    DateTime? submittedAfter,
    this.sortBy = ArxivSortBy.relevance,
    this.limit = defaultArxivSearchLimit,
  }) : query = query.trim(),
       category = category?.trim(),
       submittedAfter = submittedAfter?.toUtc();

  final String query;
  final String? category;

  /// Lower bound of the documented `submittedDate` filter, in UTC.
  final DateTime? submittedAfter;
  final ArxivSortBy sortBy;
  final int limit;
}

/// Normalized page returned by `search_papers`.
final class ArxivSearchPage {
  const ArxivSearchPage({
    required this.papers,
    this.totalResults,
    this.truncated = false,
  });

  final List<Paper> papers;

  /// `opensearch:totalResults` when the feed carries it.
  final int? totalResults;

  /// True when arXiv has more results than this page contains.
  final bool truncated;

  bool get isEmpty => papers.isEmpty;
}

/// arXiv API client used by the `arxiv` MCP tools.
///
/// Device-local coordination (documented API limit): the legacy API allows one
/// request every three seconds and a single connection, globally for the
/// machines a user controls. Domovoy cannot coordinate two independent
/// devices, so every device enforces its own
/// [minRequestInterval]/[cacheCapacity] budget; a PC and a phone running at the
/// same time may still exceed the shared arXiv limit together.
///
/// The client:
/// - serializes every arXiv request, so at most one is outstanding;
/// - waits at least [minRequestInterval] between request starts;
/// - honors `Retry-After` backs off requested by arXiv;
/// - caches successful responses in a bounded LRU with a TTL;
/// - validates and normalizes everything it returns as `Paper` v1;
/// - never requests a PDF link.
final class ArxivClient {
  ArxivClient({
    required ArxivHttpAdapter http,
    ArxivClock? clock,
    Uri? endpoint,
    this.requestTimeout = const Duration(seconds: 15),
    this.minRequestInterval = const Duration(seconds: 3),
    this.cacheTtl = const Duration(minutes: 10),
    this.cacheCapacity = 32,
    this.maxResponseCharacters = 2 * 1024 * 1024,
    this.maxRetryAfter = const Duration(hours: 24),
    ArxivAtomParser? parser,
  }) : _http = http,
       _clock = clock ?? const SystemArxivClock(),
       endpoint = endpoint ?? defaultArxivEndpoint,
       _parser = parser ?? const ArxivAtomParser() {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be > 0',
      );
    }
    if (minRequestInterval < Duration.zero) {
      throw ArgumentError.value(
        minRequestInterval,
        'minRequestInterval',
        'must be >= 0',
      );
    }
    if (cacheTtl < Duration.zero) {
      throw ArgumentError.value(cacheTtl, 'cacheTtl', 'must be >= 0');
    }
    if (cacheCapacity < 1) {
      throw ArgumentError.value(cacheCapacity, 'cacheCapacity', 'must be >= 1');
    }
    if (maxResponseCharacters < 1) {
      throw ArgumentError.value(
        maxResponseCharacters,
        'maxResponseCharacters',
        'must be >= 1',
      );
    }
    if (maxRetryAfter < Duration.zero) {
      throw ArgumentError.value(maxRetryAfter, 'maxRetryAfter', 'must be >= 0');
    }
  }

  static const _maxQueryCharacters = 500;
  static const _maxQueryTerms = 16;
  static final _controlCharacters = RegExp(r'[\u0000-\u001F\u007F]');
  static final _termPattern = RegExp(
    r"[\p{L}\p{N}][\p{L}\p{N}_.\-]*",
    unicode: true,
  );
  static final _categoryPattern = RegExp(
    r'^[a-z][a-z0-9-]{1,20}(\.[A-Za-z][A-Za-z0-9-]{0,20})?$',
  );

  final ArxivHttpAdapter _http;
  final ArxivClock _clock;
  final ArxivAtomParser _parser;
  final Uri endpoint;
  final Duration requestTimeout;
  final Duration minRequestInterval;
  final Duration cacheTtl;
  final int cacheCapacity;
  final int maxResponseCharacters;
  final Duration maxRetryAfter;

  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};
  Future<void> _requestTail = Future<void>.value();
  DateTime? _lastRequestAt;
  DateTime? _notBefore;

  /// Searches arXiv and returns at most `request.limit` normalized papers.
  Future<ArxivSearchPage> search(ArxivSearchRequest request) async {
    _validateSearch(request);
    final key = 'search|${_searchKey(request)}';
    return _load(key, () async {
      final feed = await _fetch(_searchUri(request));
      return _pageFromFeed(feed, request);
    });
  }

  /// Looks a paper up by (optionally versioned) arXiv ID.
  Future<Paper> getPaper(String rawId) async {
    final raw = rawId.trim();
    if (raw.isEmpty || raw.length > 64) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'arXiv ID пустой или слишком длинный.',
      );
    }
    final String arxivId;
    final String? version;
    try {
      arxivId = normalizeArxivId(raw);
      version = versionFromArxivInput(raw);
    } on ResearchException {
      throwArxiv(ArxivFailureKind.invalidInput, 'arXiv ID указан неверно.');
    }
    final key = 'get|$arxivId|${version ?? ''}';
    return _load(key, () async {
      final feed = await _fetch(_getUri(arxivId, version));
      return _selectPaper(feed, arxivId, version);
    });
  }

  void _validateSearch(ArxivSearchRequest request) {
    if (request.query.isEmpty) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Поисковый запрос не должен быть пустым.',
      );
    }
    if (request.query.length > _maxQueryCharacters) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Поисковый запрос длиннее $_maxQueryCharacters символов.',
      );
    }
    if (_controlCharacters.hasMatch(request.query)) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Поисковый запрос содержит управляющие символы.',
      );
    }
    final category = request.category;
    if (category != null && !_categoryPattern.hasMatch(category)) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Категория arXiv указана неверно (например, cs.AI).',
      );
    }
    if (request.limit < 1 || request.limit > maxArxivSearchLimit) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'limit должен быть от 1 до $maxArxivSearchLimit.',
      );
    }
    final after = request.submittedAfter;
    if (after != null && (after.year < 1991 || after.year > 9999)) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'submittedAfter вне поддерживаемого диапазона.',
      );
    }
    // Fails before any queueing/rate-limit wait when the query has no usable
    // terms or too many of them.
    _queryTerms(request.query);
  }

  /// Cache check + serialized load.
  ///
  /// Each call carries an expiry marker: when the caller's deadline fires
  /// while the action is still waiting in the queue, the action must neither
  /// send a request nor publish a result. The second cache check inside the
  /// exclusive section coalesces identical concurrent requests.
  Future<T> _load<T>(String key, Future<T> Function() loader) async {
    final hit = _cacheGet<T>(key);
    if (hit != null) {
      return hit;
    }
    final attempt = _LoadAttempt();
    try {
      final result =
          await _runExclusive(() async {
            attempt.throwIfExpired();
            final second = _cacheGet<T>(key);
            if (second != null) {
              return second;
            }
            attempt.throwIfExpired();
            final value = await loader();
            attempt.throwIfExpired();
            return value;
          }).timeout(
            requestTimeout,
            onTimeout: () {
              // Mark before the queued action gets its turn: `Future.timeout`
              // cannot cancel the action, so the action checks this marker itself.
              attempt.expire();
              throw TimeoutException('arXiv request deadline exceeded.');
            },
          );
      _cachePut(key, result);
      return result;
    } on ArxivFailure {
      rethrow;
    } on TimeoutException {
      throwArxiv(
        ArxivFailureKind.timeout,
        'arXiv не ответил за ${requestTimeout.inSeconds} с.',
      );
    }
  }

  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final previous = _requestTail;
    final release = Completer<void>();
    _requestTail = release.future;
    return () async {
      await previous;
      try {
        return await action();
      } finally {
        release.complete();
      }
    }();
  }

  Future<ArxivAtomFeed> _fetch(Uri uri) async {
    await _waitForTurn();
    final startedAt = _clock.nowUtc();
    _lastRequestAt = startedAt;
    final ArxivHttpResponse response;
    try {
      response = await _http.get(uri, timeout: requestTimeout);
    } on ArxivFailure {
      rethrow;
    } on TimeoutException {
      throwArxiv(
        ArxivFailureKind.timeout,
        'arXiv не ответил за ${requestTimeout.inSeconds} с.',
      );
    } on FormatException {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv имеет некорректный формат.',
      );
    } on Exception {
      throwArxiv(
        ArxivFailureKind.network,
        'Не удалось выполнить запрос к arXiv.',
      );
    }
    if (response.isSuccess) {
      if (response.body.length > maxResponseCharacters) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv превысил лимит $maxResponseCharacters символов.',
        );
      }
      return _parser.parse(response.body);
    }
    final retryAfter = _parseRetryAfter(response.header('retry-after'));
    if (retryAfter != null) {
      // Retry-After is measured from the moment the response arrives, not
      // from the request start: a slow request must not eat into the backoff.
      _notBefore = _clock.nowUtc().add(_clampRetryAfter(retryAfter));
    }
    switch (response.statusCode) {
      case 429:
        throwArxiv(
          ArxivFailureKind.rateLimited,
          retryAfter == null
              ? 'arXiv ограничил частоту запросов.'
              : 'arXiv ограничил частоту запросов, повтор через '
                    '${retryAfter.inSeconds} с.',
          retryAfter: retryAfter,
        );
      case >= 500:
        throwArxiv(
          ArxivFailureKind.network,
          'Сервис arXiv временно недоступен (HTTP ${response.statusCode}).',
        );
      default:
        throwArxiv(
          ArxivFailureKind.protocol,
          'arXiv отклонил запрос (HTTP ${response.statusCode}).',
        );
    }
  }

  Future<void> _waitForTurn() async {
    final now = _clock.nowUtc();
    var readyAt = now;
    final last = _lastRequestAt;
    if (last != null) {
      final spaced = last.add(minRequestInterval);
      if (spaced.isAfter(readyAt)) {
        readyAt = spaced;
      }
    }
    final notBefore = _notBefore;
    if (notBefore != null && notBefore.isAfter(readyAt)) {
      readyAt = notBefore;
    }
    final wait = readyAt.difference(now);
    if (wait > Duration.zero) {
      await _clock.sleep(wait);
    }
  }

  Uri _searchUri(ArxivSearchRequest request) {
    final parts = <String>[
      for (final term in _queryTerms(request.query)) 'all:$term',
      if (request.category != null) 'cat:${request.category}',
      if (request.submittedAfter != null)
        'submittedDate:[${_compactMinute(request.submittedAfter!)} '
            'TO 999912312359]',
    ];
    return _endpointWith(<String, String>{
      'search_query': parts.join(' AND '),
      'start': '0',
      'max_results': '${request.limit}',
      'sortBy': request.sortBy.wireName,
      'sortOrder': 'descending',
    });
  }

  Uri _getUri(String arxivId, String? version) =>
      _endpointWith(<String, String>{
        'id_list': version == null ? arxivId : '$arxivId$version',
        'start': '0',
        'max_results': '1',
      });

  Uri _endpointWith(Map<String, String> parameters) =>
      endpoint.replace(queryParameters: parameters);

  /// Tokenizes free text into `all:<term>` alternatives.
  ///
  /// Only letters, digits, `_`, `.`, `-` survive, so a model cannot change the
  /// query grammar (field prefixes, Boolean operators, date filters or
  /// parentheses) through `query`.
  List<String> _queryTerms(String query) {
    final terms = _termPattern
        .allMatches(query)
        .map((match) => match.group(0)!)
        .toList(growable: false);
    if (terms.isEmpty) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Поисковый запрос должен содержать буквы или цифры.',
      );
    }
    if (terms.length > _maxQueryTerms) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Запрос слишком сложный: не более $_maxQueryTerms слов.',
      );
    }
    return terms;
  }

  ArxivSearchPage _pageFromFeed(
    ArxivAtomFeed feed,
    ArxivSearchRequest request,
  ) {
    final ordered = _orderPapers(_dedupeVersions(feed.papers), request.sortBy);
    final limited = ordered.take(request.limit).toList(growable: false);
    final total = feed.totalResults;
    final truncated =
        ordered.length > request.limit ||
        (total != null && total > request.limit);
    return ArxivSearchPage(
      papers: List<Paper>.unmodifiable(limited),
      totalResults: total,
      truncated: truncated,
    );
  }

  /// Keeps one entry per base ID: the highest version, then the latest update.
  /// First-seen feed order of each base ID is preserved.
  List<Paper> _dedupeVersions(List<Paper> papers) {
    final winners = <String, Paper>{};
    for (final paper in papers) {
      final existing = winners[paper.arxivId.value];
      if (existing == null || _isPreferredVersion(paper, existing)) {
        winners[paper.arxivId.value] = paper;
      }
    }
    final seen = <String>{};
    final result = <Paper>[];
    for (final paper in papers) {
      if (seen.add(paper.arxivId.value)) {
        result.add(winners[paper.arxivId.value]!);
      }
    }
    return result;
  }

  bool _isPreferredVersion(Paper candidate, Paper current) {
    final candidateRank = _versionRank(candidate);
    final currentRank = _versionRank(current);
    if (candidateRank != currentRank) {
      return candidateRank > currentRank;
    }
    return candidate.updatedAt.isAfter(current.updatedAt);
  }

  int _versionRank(Paper paper) {
    final version = paper.version;
    if (version == null) {
      return -1;
    }
    return int.tryParse(version.substring(1)) ?? -1;
  }

  /// Deterministic order: date sorts are newest-first with an ID tie-breaker;
  /// `relevance` keeps the API order.
  List<Paper> _orderPapers(List<Paper> papers, ArxivSortBy sortBy) {
    if (sortBy == ArxivSortBy.relevance) {
      return List<Paper>.unmodifiable(papers);
    }
    final ordered = List<Paper>.of(papers);
    int compare(Paper left, Paper right) {
      final leftDate = sortBy == ArxivSortBy.submittedDate
          ? left.publishedAt
          : left.updatedAt;
      final rightDate = sortBy == ArxivSortBy.submittedDate
          ? right.publishedAt
          : right.updatedAt;
      final byDate = rightDate.compareTo(leftDate);
      if (byDate != 0) {
        return byDate;
      }
      return left.arxivId.value.compareTo(right.arxivId.value);
    }

    ordered.sort(compare);
    return List<Paper>.unmodifiable(ordered);
  }

  Paper _selectPaper(ArxivAtomFeed feed, String arxivId, String? version) {
    final matches = feed.papers
        .where((paper) => paper.arxivId.value == arxivId)
        .toList(growable: false);
    if (matches.isEmpty) {
      throwArxiv(ArxivFailureKind.notFound, 'Статья $arxivId не найдена.');
    }
    if (version != null) {
      for (final paper in matches) {
        if (paper.version == version) {
          return paper;
        }
      }
      throwArxiv(
        ArxivFailureKind.notFound,
        'Версия $version статьи $arxivId не найдена.',
      );
    }
    var newest = matches.first;
    for (final paper in matches.skip(1)) {
      if (_isPreferredVersion(paper, newest)) {
        newest = paper;
      }
    }
    return newest;
  }

  T? _cacheGet<T>(String key) {
    final entry = _cache[key];
    if (entry == null) {
      return null;
    }
    final age = _clock.nowUtc().difference(entry.storedAt);
    if (age > cacheTtl) {
      _cache.remove(key);
      return null;
    }
    // Touch for LRU: re-inserting moves the key to the end of the map.
    _cache.remove(key);
    _cache[key] = entry;
    return entry.value as T;
  }

  void _cachePut(String key, Object? value) {
    _cache.remove(key);
    _cache[key] = _CacheEntry(value, _clock.nowUtc());
    while (_cache.length > cacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
  }

  Duration? _parseRetryAfter(String? raw) {
    if (raw == null) {
      return null;
    }
    final candidate = raw.trim();
    if (candidate.isEmpty) {
      return null;
    }
    final seconds = int.tryParse(candidate);
    if (seconds != null) {
      return seconds < 0 ? null : Duration(seconds: seconds);
    }
    return _parseHttpDate(candidate);
  }

  Duration? _parseHttpDate(String raw) {
    final match = RegExp(
      r'^[A-Za-z]{3}, (\d{1,2}) ([A-Za-z]{3}) (\d{4}) '
      r'(\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(raw);
    if (match == null) {
      return null;
    }
    final month = _httpMonths[match.group(2)!.toLowerCase()];
    if (month == null) {
      return null;
    }
    final parsed = DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
    final delta = parsed.difference(_clock.nowUtc());
    return delta.isNegative ? Duration.zero : delta;
  }

  Duration _clampRetryAfter(Duration value) =>
      value > maxRetryAfter ? maxRetryAfter : value;

  String _searchKey(ArxivSearchRequest request) {
    final after = request.submittedAfter;
    return <String>[
      request.query,
      request.category ?? '',
      after == null ? '' : _compactMinute(after),
      request.sortBy.wireName,
      '${request.limit}',
    ].join('\u0000');
  }
}

final class _CacheEntry {
  const _CacheEntry(this.value, this.storedAt);

  final Object? value;
  final DateTime storedAt;
}

/// One in-flight [ArxivClient._load] whose caller deadline may expire while
/// the serialized action is still queued behind another request.
final class _LoadAttempt {
  bool _expired = false;

  void expire() => _expired = true;

  /// Refuses to start or publish work for an attempt the caller abandoned.
  void throwIfExpired() {
    if (_expired) {
      throwArxiv(
        ArxivFailureKind.timeout,
        'Запрос arXiv истёк в очереди и не был отправлен.',
      );
    }
  }
}

/// `YYYYMMDDHHMM` in UTC, the documented `submittedDate` grammar (minutes).
String _compactMinute(DateTime utc) {
  final value = utc.toUtc();
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}$month$day$hour$minute';
}

const Map<String, int> _httpMonths = <String, int>{
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

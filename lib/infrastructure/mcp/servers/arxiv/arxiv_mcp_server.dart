import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../../core/research/research.dart';
import '../../local/local_mcp_definition.dart';
import 'arxiv_client.dart';
import 'arxiv_errors.dart';
import 'arxiv_http.dart';

/// Stable identity of the local arXiv MCP server.
const arxivServerId = 'arxiv';

/// Display name shown in the MCP connection UI.
const arxivServerDisplayName = 'arXiv';

/// Version of this server's tools and schemas.
const arxivServerVersion = '1.0.0';

/// Original tool names of the server.
const arxivSearchToolName = 'search_papers';
const arxivGetToolName = 'get_paper';

const _serverInstructions =
    'Поиск и чтение описательных данных arXiv (метаданные и аннотации). '
    'PDF не загружаются; ссылки ведут на страницу abs.';

/// `LocalMcpServerFactory` of the built-in `arxiv` server.
///
/// B9 composes it explicitly, for example:
///
/// ```dart
/// final arxiv = ArxivMcpServerFactory();      // owns its HTTP client
/// host.register(arxiv);                       // or pass an injected adapter
/// // ... at shutdown:
/// arxiv.dispose();
/// ```
///
/// The factory owns one [ArxivClient] for the whole process, so the request
/// rate gate and the bounded cache are shared by every session and reconnect
/// of the server, not reset per MCP session. Injecting an
/// [ArxivHttpAdapter]/[ArxivClock] keeps tests hermetic.
final class ArxivMcpServerFactory implements LocalMcpServerFactory {
  ArxivMcpServerFactory({
    ArxivHttpAdapter? httpAdapter,
    ArxivClock? clock,
    Uri? endpoint,
    Duration requestTimeout = const Duration(seconds: 15),
    Duration minRequestInterval = const Duration(seconds: 3),
    Duration cacheTtl = const Duration(minutes: 10),
    int cacheCapacity = 32,
    int maxResponseBytes = 2 * 1024 * 1024,
  }) : _httpAdapter =
           httpAdapter ??
           HttpArxivHttpAdapter(maxResponseBytes: maxResponseBytes),
       _ownsHttpAdapter = httpAdapter == null {
    _client = ArxivClient(
      http: _httpAdapter,
      clock: clock,
      endpoint: endpoint,
      requestTimeout: requestTimeout,
      minRequestInterval: minRequestInterval,
      cacheTtl: cacheTtl,
      cacheCapacity: cacheCapacity,
      maxResponseCharacters: maxResponseBytes,
    );
  }

  final ArxivHttpAdapter _httpAdapter;
  final bool _ownsHttpAdapter;
  late final ArxivClient _client;

  /// Shared client; exposed for diagnostics and composition tests.
  ArxivClient get client => _client;

  @override
  LocalMcpServerDefinition create() => LocalMcpServerDefinition(
    serverId: arxivServerId,
    displayName: arxivServerDisplayName,
    version: arxivServerVersion,
    instructions: _serverInstructions,
    registerTools: _registerTools,
  );

  /// Closes the owned default HTTP client; an injected adapter stays owned by
  /// the caller and is never closed here.
  void dispose() {
    if (_ownsHttpAdapter) {
      final adapter = _httpAdapter;
      if (adapter is HttpArxivHttpAdapter) {
        adapter.close();
      }
    }
  }

  void _registerTools(sdk.McpServer server) {
    server.registerTool(
      arxivSearchToolName,
      title: 'Поиск статей на arXiv',
      description:
          'Ищет статьи в официальном API arXiv по свободному тексту, '
          'категории и дате подачи. Возвращает не более 30 работ с '
          'аннотациями и каноническими ссылками abs; PDF не загружаются.',
      inputSchema: _searchInputSchema(),
      outputSchema: _searchOutputSchema(),
      annotations: _annotations,
      callback: (args, extra) => _searchPapers(args, extra),
    );
    server.registerTool(
      arxivGetToolName,
      title: 'Получить статью arXiv',
      description:
          'Возвращает одну статью по проверенному arXiv ID '
          '(например 2501.01234 или 2501.01234v2). Для поиска по версиям '
          'используется id_list официального API.',
      inputSchema: _getInputSchema(),
      outputSchema: _paperSchema(),
      annotations: _annotations,
      callback: (args, extra) => _getPaper(args, extra),
    );
  }

  Future<sdk.CallToolResult> _searchPapers(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelled());
    }
    try {
      final request = ArxivSearchRequest(
        query: _requireString(args, 'query'),
        category: _optionalString(args, 'category'),
        submittedAfter: _parseUtcDate(_optionalString(args, 'submittedAfter')),
        sortBy: _parseSortBy(args['sortBy']),
        limit: _optionalInt(args, 'limit') ?? defaultArxivSearchLimit,
      );
      final page = await _client.search(request);
      if (extra.signal.aborted) {
        return _failure(_cancelled());
      }
      return _searchResult(page);
    } on ArxivFailure catch (failure) {
      return _failure(failure);
    }
  }

  Future<sdk.CallToolResult> _getPaper(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelled());
    }
    try {
      final paper = await _client.getPaper(_requireString(args, 'arxivId'));
      if (extra.signal.aborted) {
        return _failure(_cancelled());
      }
      return _paperResult(paper);
    } on ArxivFailure catch (failure) {
      return _failure(failure);
    }
  }

  sdk.CallToolResult _searchResult(ArxivSearchPage page) {
    final structured = <String, Object?>{
      'papers': <Object?>[for (final paper in page.papers) paper.toJson()],
      'count': page.papers.length,
      'truncated': page.truncated,
      if (page.totalResults != null) 'totalResults': page.totalResults,
    };
    return sdk.CallToolResult(
      content: <sdk.Content>[sdk.TextContent(text: _searchText(page))],
      structuredContent: structured,
    );
  }

  sdk.CallToolResult _paperResult(Paper paper) => sdk.CallToolResult(
    content: <sdk.Content>[sdk.TextContent(text: _paperText(paper))],
    structuredContent: paper.toJson(),
  );

  sdk.CallToolResult _failure(ArxivFailure failure) => sdk.CallToolResult(
    isError: true,
    content: <sdk.Content>[sdk.TextContent(text: failure.mcpText)],
  );

  ArxivFailure _cancelled() => ArxivFailure(
    kind: ArxivFailureKind.cancelled,
    message: 'Запрос отменён клиентом.',
  );

  String _searchText(ArxivSearchPage page) {
    final buffer = StringBuffer();
    if (page.isEmpty) {
      buffer.write('arXiv: ничего не найдено.');
      if (page.totalResults != null && page.totalResults == 0) {
        buffer.write(' totalResults=0.');
      }
      return buffer.toString();
    }
    buffer.write('arXiv: ${page.papers.length}');
    if (page.totalResults != null) {
      buffer.write(' из ${page.totalResults}');
    }
    buffer.write(page.truncated ? ' (показаны первые результаты).' : '.');
    for (final paper in page.papers) {
      buffer.write(
        '\n- ${paper.displayId}: ${_clip(paper.title, 160)} '
        '(${_formatDate(paper.publishedAt)})',
      );
    }
    return _clipText(buffer.toString(), 4000);
  }

  String _paperText(Paper paper) => _clipText(
    'arXiv ${paper.displayId}: ${_clip(paper.title, 200)}. '
    'Опубликовано ${_formatDate(paper.publishedAt)}, '
    'обновлено ${_formatDate(paper.updatedAt)}. '
    'Авторы: ${_clip(paper.authors.join(', '), 300)}. '
    'Категории: ${paper.categories.join(', ')}. '
    'Аннотация: ${_clip(paper.abstractText, 400)} '
    'Полная запись — в structuredContent.',
    1200,
  );

  static const _annotations = sdk.ToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: true,
  );

  sdk.JsonObject _searchInputSchema() => sdk.JsonSchema.object(
    description: 'Параметры поиска статей arXiv.',
    properties: <String, sdk.JsonSchema>{
      'query': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 500,
        description:
            'Свободный текст: слова ищутся по всем полям '
            '(all:<term> AND ...). Спецсимволы запроса отбрасываются.',
      ),
      'category': sdk.JsonSchema.string(
        minLength: 2,
        maxLength: 42,
        description: 'Категория arXiv, например cs.AI, math.GT, hep-th.',
      ),
      'submittedAfter': sdk.JsonSchema.string(
        minLength: 10,
        maxLength: 40,
        description:
            'Нижняя граница submittedDate в UTC: '
            '2024-01-01 или 2024-01-01T00:00:00Z.',
      ),
      'sortBy': sdk.JsonSchema.string(
        enumValues: <String>['relevance', 'lastUpdatedDate', 'submittedDate'],
        description: 'Документированное значение sortBy.',
      ),
      'limit': sdk.JsonSchema.integer(
        minimum: 1,
        maximum: maxArxivSearchLimit,
        defaultValue: defaultArxivSearchLimit,
        description: 'Число результатов от 1 до $maxArxivSearchLimit.',
      ),
    },
    required: <String>['query'],
    additionalProperties: false,
  );

  sdk.JsonObject _getInputSchema() => sdk.JsonSchema.object(
    description: 'Идентификатор статьи arXiv.',
    properties: <String, sdk.JsonSchema>{
      'arxivId': sdk.JsonSchema.string(
        minLength: 5,
        maxLength: 64,
        description:
            'Проверенный arXiv ID без URL: 2501.01234 или '
            '2501.01234v2 (также legacy-формат math.GT/0309136).',
      ),
    },
    required: <String>['arxivId'],
    additionalProperties: false,
  );

  sdk.JsonObject _searchOutputSchema() => sdk.JsonSchema.object(
    description: 'Страница результатов arXiv.',
    properties: <String, sdk.JsonSchema>{
      'papers': sdk.JsonSchema.array(
        items: _paperSchema(),
        description: 'Paper v1 в порядке, заданном sortBy.',
      ),
      'count': sdk.JsonSchema.integer(minimum: 0),
      'truncated': sdk.JsonSchema.boolean(
        description: 'У arXiv есть результаты сверх этой страницы.',
      ),
      'totalResults': sdk.JsonSchema.integer(minimum: 0),
    },
    required: <String>['papers', 'count', 'truncated'],
  );

  sdk.JsonObject _paperSchema() => sdk.JsonSchema.object(
    description: 'Paper v1 из core/research.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'arxivId': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
      'version': sdk.JsonSchema.string(minLength: 2, maxLength: 8),
      'title': sdk.JsonSchema.string(minLength: 1, maxLength: 4096),
      'authors': sdk.JsonSchema.array(
        items: sdk.JsonSchema.string(minLength: 1, maxLength: 512),
        minItems: 1,
        maxItems: 100,
      ),
      'abstract': sdk.JsonSchema.string(minLength: 1, maxLength: 20000),
      'categories': sdk.JsonSchema.array(
        items: sdk.JsonSchema.string(minLength: 1, maxLength: 64),
        maxItems: 20,
      ),
      'publishedAt': sdk.JsonSchema.string(format: 'date-time'),
      'updatedAt': sdk.JsonSchema.string(format: 'date-time'),
      'abstractUrl': sdk.JsonSchema.string(format: 'uri'),
    },
    required: <String>[
      'schemaVersion',
      'arxivId',
      'title',
      'authors',
      'abstract',
      'categories',
      'publishedAt',
      'updatedAt',
      'abstractUrl',
    ],
    additionalProperties: false,
  );

  String _requireString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String || value.trim().isEmpty) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Параметр "$key" должен быть непустой строкой.',
      );
    }
    return value.trim();
  }

  String? _optionalString(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Параметр "$key" должен быть строкой.',
      );
    }
    final candidate = value.trim();
    return candidate.isEmpty ? null : candidate;
  }

  int? _optionalInt(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    if (value is int) {
      return value;
    }
    if (value is num && value.isFinite && value == value.truncateToDouble()) {
      return value.toInt();
    }
    throwArxiv(
      ArxivFailureKind.invalidInput,
      'Параметр "$key" должен быть целым числом.',
    );
  }

  ArxivSortBy _parseSortBy(Object? value) {
    if (value == null) {
      return ArxivSortBy.relevance;
    }
    if (value is! String) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'Параметр "sortBy" должен быть строкой.',
      );
    }
    final candidate = value.trim();
    if (candidate.isEmpty) {
      return ArxivSortBy.relevance;
    }
    for (final sortBy in ArxivSortBy.values) {
      if (sortBy.wireName == candidate) {
        return sortBy;
      }
    }
    throwArxiv(
      ArxivFailureKind.invalidInput,
      'sortBy должен быть relevance, lastUpdatedDate или submittedDate.',
    );
  }

  /// ISO 8601 with an explicit zone, or a bare `YYYY-MM-DD` treated as UTC.
  DateTime? _parseUtcDate(String? value) {
    if (value == null) {
      return null;
    }
    final candidate = value.trim();
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(candidate)) {
      final parsed = DateTime.tryParse('${candidate}T00:00:00Z');
      if (parsed == null) {
        throwArxiv(
          ArxivFailureKind.invalidInput,
          'submittedAfter указан неверно.',
        );
      }
      return parsed.toUtc();
    }
    final hasZone = RegExp(r'(Z|z)$|[+-]\d{2}:?\d{2}$').hasMatch(candidate);
    if (!hasZone) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'submittedAfter требует часовой пояс UTC, например '
        '2024-01-01T00:00:00Z.',
      );
    }
    final parsed = DateTime.tryParse(candidate);
    if (parsed == null) {
      throwArxiv(
        ArxivFailureKind.invalidInput,
        'submittedAfter указан неверно.',
      );
    }
    return parsed.toUtc();
  }
}

String _formatDate(DateTime value) {
  final utc = value.toUtc();
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-$month-$day';
}

String _clip(String value, int limit) {
  if (value.length <= limit) {
    return value;
  }
  return '${value.substring(0, limit)}…';
}

String _clipText(String value, int limit) {
  if (value.length <= limit) {
    return value;
  }
  return '${value.substring(0, limit - 1)}…';
}

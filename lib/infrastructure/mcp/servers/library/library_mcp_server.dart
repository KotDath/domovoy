import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../../core/llm/cancellation.dart';
import '../../../../core/research/research.dart';
import '../../../agents/jsonl/jsonl_stream_storage.dart';
import '../../local/local_mcp_definition.dart';
import 'library_failure.dart';
import 'library_jsonl_store.dart';
import 'library_limits.dart';

/// Stable identity of the local `library` MCP server.
const libraryServerId = 'library';

/// Display name shown in the MCP connection UI.
const libraryServerDisplayName = 'Library';

/// Version of this server's tools and schemas.
const libraryServerVersion = '1.0.0';

/// Original tool names of the server.
const librarySaveToolName = 'save_digest';
const libraryListToolName = 'list_saved';
const libraryGetToolName = 'get_saved';

const _serverInstructions =
    'Локальная библиотека статей и сводок на этом устройстве. save_digest '
    'сохраняет проверенный Digest v1 вместе со снимками Paper v1; list_saved '
    'и get_saved читают сохранённое. PDF, ключи и произвольные файлы не '
    'сохраняются, путь файловой системы не принимается.';

/// Fields accepted inside one Paper v1 snapshot.
const _paperFields = <String>{
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

/// Fields accepted at the top level of one Digest v1 payload.
const _digestFields = <String>{
  'schemaVersion',
  'topic',
  'sourceScope',
  'overview',
  'items',
  'generatedAt',
};

/// Fields accepted inside one Digest v1 item.
const _digestItemFields = <String>{
  'arxivId',
  'abstractUrl',
  'finding',
  'limitation',
};

/// `LocalMcpServerFactory` of the built-in `library` server.
///
/// B9 composes it explicitly, for example:
///
/// ```dart
/// final storage = createPlatformLibraryJsonlStreamStorage();
/// if (storage != null) {
///   localHost.register(LibraryMcpServerFactory(storage: storage));
///   await localHost.start('library');   // serverId стабилен: 'library'
/// }
/// ```
///
/// The factory owns the only [LibraryRepository] of the application: the JSONL
/// store is created here and reused by every session and reconnect. Tests and
/// alternative compositions can inject a prepared repository through
/// [LibraryMcpServerFactory.withRepository].
final class LibraryMcpServerFactory implements LocalMcpServerFactory {
  factory LibraryMcpServerFactory({
    required JsonlStreamStorage storage,
    LibraryLimits limits = const LibraryLimits(),
    LibraryClock? clock,
    LibraryIdGenerator? ids,
  }) {
    final validated = limits.validate();
    return LibraryMcpServerFactory.withRepository(
      repository: JsonlLibraryStore(
        storage: storage,
        limits: validated,
        clock: clock,
        ids: ids,
      ),
      limits: validated,
    );
  }

  LibraryMcpServerFactory.withRepository({
    required this.repository,
    LibraryLimits limits = const LibraryLimits(),
  }) : _limits = limits.validate();

  /// The single owner of the local library.
  final LibraryRepository repository;
  final LibraryLimits _limits;

  @override
  LocalMcpServerDefinition create() => LocalMcpServerDefinition(
    serverId: libraryServerId,
    displayName: libraryServerDisplayName,
    version: libraryServerVersion,
    instructions: _serverInstructions,
    registerTools: _registerTools,
  );

  void _registerTools(sdk.McpServer server) {
    server.registerTool(
      librarySaveToolName,
      title: 'Сохранить сводку в библиотеку',
      description:
          'Сохраняет Digest v1 вместе со снимками Paper v1, темой и '
          'необязательным runId. Повтор с тем же runId и тем же payload '
          'возвращает ту же запись без дубликата; другой payload для того же '
          'runId отклоняется конфликтом. Каждый пункт сводки обязан '
          'ссылаться на переданную статью; PDF и произвольные файлы не '
          'принимаются.',
      inputSchema: _saveInputSchema(),
      outputSchema: _saveOutputSchema(),
      annotations: _saveAnnotations,
      callback: (args, extra) => _saveDigest(args, extra),
    );
    server.registerTool(
      libraryListToolName,
      title: 'Список сохранённых подборок',
      description:
          'Возвращает страницу карточек библиотеки в стабильном порядке '
          '(сначала новые) с необязательным поиском по теме, статье и сводке. '
          'Пагинация использует непрозрачный keyset-курсор: вставка новых '
          'записей между страницами не сдвигает уже начатый список.',
      inputSchema: _listInputSchema(),
      outputSchema: _listOutputSchema(),
      annotations: _readAnnotations,
      callback: (args, extra) => _listSaved(args, extra),
    );
    server.registerTool(
      libraryGetToolName,
      title: 'Прочитать сохранённую подборку',
      description:
          'Возвращает полную запись библиотеки по libraryId: тему, снимки '
          'Paper v1, Digest v1 и время сохранения. Это read API библиотеки '
          'для UI; второй копии данных в приложении нет.',
      inputSchema: _getInputSchema(),
      outputSchema: _recordSchema(),
      annotations: _readAnnotations,
      callback: (args, extra) => _getSaved(args, extra),
    );
  }

  Future<sdk.CallToolResult> _saveDigest(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelledFailure());
    }
    final cancellation = CancellationSource();
    final abortSubscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    try {
      final request = _parseSaveRequest(args);
      final result = await repository.save(
        topic: request.topic,
        papers: request.papers,
        digest: request.digest,
        runId: request.runId,
        cancellation: cancellation.token,
      );
      if (extra.signal.aborted) {
        return _failure(_cancelledFailure());
      }
      return _saveSuccess(result);
    } on LibraryFailure catch (failure) {
      return _failure(failure);
    } on LibraryException catch (error) {
      return _failure(libraryFailureFromError(error));
    } on Object {
      return _failure(_internalFailure());
    } finally {
      await abortSubscription.cancel();
    }
  }

  Future<sdk.CallToolResult> _listSaved(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelledFailure());
    }
    final cancellation = CancellationSource();
    final abortSubscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    try {
      final request = _parseListRequest(args);
      final page = await repository.list(
        query: request.query,
        limit: request.limit,
        cursor: request.cursor,
        cancellation: cancellation.token,
      );
      if (extra.signal.aborted) {
        return _failure(_cancelledFailure());
      }
      return _listSuccess(page);
    } on LibraryFailure catch (failure) {
      return _failure(failure);
    } on LibraryException catch (error) {
      return _failure(libraryFailureFromError(error));
    } on Object {
      return _failure(_internalFailure());
    } finally {
      await abortSubscription.cancel();
    }
  }

  Future<sdk.CallToolResult> _getSaved(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelledFailure());
    }
    final cancellation = CancellationSource();
    final abortSubscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    try {
      final request = _parseGetRequest(args);
      final record = await repository.find(
        request.libraryId,
        cancellation: cancellation.token,
      );
      if (extra.signal.aborted) {
        return _failure(_cancelledFailure());
      }
      if (record == null) {
        return _failure(
          LibraryFailure(
            kind: LibraryFailureKind.notFound,
            message:
                'Запись ${request.libraryId.value} не найдена в локальной '
                'библиотеке.',
          ),
        );
      }
      return _getSuccess(record);
    } on LibraryFailure catch (failure) {
      return _failure(failure);
    } on LibraryException catch (error) {
      return _failure(libraryFailureFromError(error));
    } on Object {
      return _failure(_internalFailure());
    } finally {
      await abortSubscription.cancel();
    }
  }

  _SaveRequest _parseSaveRequest(Map<String, dynamic> args) {
    _rejectUnknownKeys(args, const <String>{
      'digest',
      'papers',
      'topic',
      'runId',
    });
    final topic = _requireText(
      args,
      'topic',
      maxLength: _limits.maxTopicCharacters,
    );
    final digest = _parseDigest(args['digest']);
    if (digest.topic != topic) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'topic must match the digest topic "${digest.topic}".',
      );
    }
    final rawPapers = args['papers'];
    if (rawPapers is! List) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'papers must be an array of Paper v1 snapshots.',
      );
    }
    if (rawPapers.length < _limits.minPapers ||
        rawPapers.length > _limits.maxPapers) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Ожидается от ${_limits.minPapers} до ${_limits.maxPapers} статей, '
        'получено ${rawPapers.length}.',
      );
    }
    final papers = <Paper>[];
    var totalPaperBytes = 0;
    for (var index = 0; index < rawPapers.length; index += 1) {
      final paper = _parsePaper(rawPapers[index], index);
      final bytes = utf8.encode(jsonEncode(paper.toJson())).length;
      if (bytes > _limits.maxPaperBytes) {
        throwLibraryFailure(
          LibraryFailureKind.invalidInput,
          'Статья #${index + 1} занимает $bytes байт и превышает лимит '
          '${_limits.maxPaperBytes}.',
        );
      }
      totalPaperBytes += bytes;
      papers.add(paper);
    }
    if (totalPaperBytes > _limits.maxPapersBytes) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Снимки статей занимают $totalPaperBytes байт и превышают лимит '
        '${_limits.maxPapersBytes}.',
      );
    }
    final digestBytes = utf8.encode(jsonEncode(digest.toJson())).length;
    if (digestBytes > _limits.maxDigestBytes) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Digest занимает $digestBytes байт и превышает лимит '
        '${_limits.maxDigestBytes}.',
      );
    }
    final runId = _optionalText(
      args,
      'runId',
      maxLength: _limits.maxRunIdCharacters,
    );
    return _SaveRequest(
      topic: topic,
      digest: digest,
      papers: papers,
      runId: runId,
    );
  }

  _ListRequest _parseListRequest(Map<String, dynamic> args) {
    _rejectUnknownKeys(args, const <String>{'query', 'limit', 'cursor'});
    final limit = _optionalInt(args, 'limit') ?? _limits.defaultListLimit;
    if (limit < 1 || limit > _limits.maxListLimit) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'limit должен быть от 1 до ${_limits.maxListLimit}, получено $limit.',
      );
    }
    return _ListRequest(
      query: _optionalText(
        args,
        'query',
        maxLength: _limits.maxQueryCharacters,
      ),
      limit: limit,
      cursor: _optionalText(
        args,
        'cursor',
        maxLength: _limits.maxCursorCharacters,
      ),
    );
  }

  _GetRequest _parseGetRequest(Map<String, dynamic> args) {
    _rejectUnknownKeys(args, const <String>{'libraryId'});
    final raw = args['libraryId'];
    if (raw is! String) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'libraryId должен быть строкой.',
      );
    }
    final libraryId = LibraryId.tryParse(raw);
    if (libraryId == null) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'libraryId должен иметь вид lib_<hex>.',
      );
    }
    return _GetRequest(libraryId);
  }

  Digest _parseDigest(Object? raw) {
    _rejectUnknownKeys(raw, _digestFields, label: 'digest');
    if (raw is Map) {
      final items = raw['items'];
      if (items is List) {
        for (final item in items) {
          _rejectUnknownKeys(item, _digestItemFields, label: 'digest item');
        }
      }
    }
    try {
      return Digest.fromJson(raw);
    } on ResearchException catch (error) {
      if (error.error.kind == ResearchErrorKind.unsupportedVersion) {
        throwLibraryFailure(
          LibraryFailureKind.versionMismatch,
          'Digest schemaVersion не поддерживается: ${error.error.message}',
        );
      }
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Digest v1 не прошёл проверку: ${error.error.message}',
      );
    }
  }

  Paper _parsePaper(Object? raw, int index) {
    _rejectUnknownKeys(raw, _paperFields, label: 'paper #${index + 1}');
    try {
      return Paper.fromJson(raw);
    } on ResearchException catch (error) {
      if (error.error.kind == ResearchErrorKind.unsupportedVersion) {
        throwLibraryFailure(
          LibraryFailureKind.versionMismatch,
          'Paper schemaVersion не поддерживается: ${error.error.message}',
        );
      }
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Статья #${index + 1} не является полным Paper v1: '
        '${error.error.message}',
      );
    }
  }

  void _rejectUnknownKeys(
    Object? value,
    Set<String> expected, {
    String label = 'arguments',
  }) {
    if (value is! Map) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        '$label должен быть JSON-объектом.',
      );
    }
    for (final key in value.keys) {
      if (key is! String || !expected.contains(key)) {
        throwLibraryFailure(
          LibraryFailureKind.invalidInput,
          'Неизвестное поле "$key" в $label; PDF, ключи и произвольные данные '
          'не сохраняются.',
        );
      }
    }
  }

  String _requireText(
    Map<String, dynamic> args,
    String key, {
    required int maxLength,
  }) {
    final value = args[key];
    if (value is! String) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Параметр "$key" должен быть непустой строкой.',
      );
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Параметр "$key" должен быть непустой строкой.',
      );
    }
    if (trimmed.length > maxLength) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Параметр "$key" длиннее $maxLength символов.',
      );
    }
    return trimmed;
  }

  String? _optionalText(
    Map<String, dynamic> args,
    String key, {
    required int maxLength,
  }) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Параметр "$key" должен быть строкой.',
      );
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.length > maxLength) {
      throwLibraryFailure(
        LibraryFailureKind.invalidInput,
        'Параметр "$key" длиннее $maxLength символов.',
      );
    }
    return trimmed;
  }

  int? _optionalInt(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    // JSON numbers may arrive as an integral double; the MCP SDK accepts that
    // shape for an integer schema, so the handler accepts it too.
    if (value is int) {
      return value;
    }
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      return value.toInt();
    }
    throwLibraryFailure(
      LibraryFailureKind.invalidInput,
      'Параметр "$key" должен быть целым числом.',
    );
  }

  sdk.CallToolResult _saveSuccess(LibrarySaveResult result) {
    final record = result.record;
    return sdk.CallToolResult(
      content: <sdk.Content>[sdk.TextContent(text: _saveText(result))],
      structuredContent: <String, Object?>{
        'schemaVersion': 1,
        'libraryId': record.libraryId.value,
        if (record.runId != null) 'runId': record.runId,
        'savedAt': record.savedAt.toIso8601String(),
        'topic': record.topic,
        'paperCount': record.papers.length,
        'itemCount': record.digest.items.length,
        'created': result.created,
        'recordRef': record.recordRef,
      },
    );
  }

  sdk.CallToolResult _listSuccess(LibraryPage page) {
    return sdk.CallToolResult(
      content: <sdk.Content>[sdk.TextContent(text: _listText(page))],
      structuredContent: <String, Object?>{
        'schemaVersion': 1,
        'records': page.cards
            .map((card) => card.toJson())
            .toList(growable: false),
        if (page.nextCursor != null) 'nextCursor': page.nextCursor,
        'totalCount': page.totalCount,
      },
    );
  }

  sdk.CallToolResult _getSuccess(LibraryRecord record) {
    return sdk.CallToolResult(
      content: <sdk.Content>[sdk.TextContent(text: _getText(record))],
      structuredContent: record.toJson(),
    );
  }

  sdk.CallToolResult _failure(LibraryFailure failure) => sdk.CallToolResult(
    isError: true,
    content: <sdk.Content>[sdk.TextContent(text: failure.mcpText)],
  );

  LibraryFailure _cancelledFailure() => LibraryFailure(
    kind: LibraryFailureKind.cancelled,
    message: 'Вызов отменён клиентом.',
  );

  LibraryFailure _internalFailure() => LibraryFailure(
    kind: LibraryFailureKind.internal,
    message: 'Внутренняя ошибка библиотеки; запись не изменена.',
  );

  String _saveText(LibrarySaveResult result) {
    final record = result.record;
    final buffer = StringBuffer()
      ..write(result.created ? 'Сохранено в библиотеке: ' : 'Уже сохранено: ')
      ..write(record.libraryId.value)
      ..write(' (статей: ${record.papers.length}, ')
      ..write('пунктов сводки: ${record.digest.items.length}, ')
      ..write('${record.savedAt.toIso8601String()})')
      ..write(result.created ? '. ' : '; повтор runId без дубликата. ')
      ..write('Тема: ${_clip(record.topic, 200)}. ')
      ..write('Ссылка: ${record.recordRef}. ')
      ..write('Сводка составлена только по аннотациям arXiv.');
    return _clipText(buffer.toString(), 4000);
  }

  String _listText(LibraryPage page) {
    final buffer = StringBuffer()
      ..write('Найдено записей: ${page.totalCount}; ')
      ..write('на странице: ${page.cards.length}.');
    for (final card in page.cards) {
      buffer
        ..write('\n- ${card.libraryId.value} ')
        ..write('${card.savedAt.toIso8601String()} ')
        ..write('статей: ${card.paperCount} ')
        ..write(_clip(card.topic, 160));
    }
    if (page.nextCursor != null) {
      buffer.write('\nСледующая страница: передайте nextCursor.');
    }
    return _clipText(buffer.toString(), 4000);
  }

  String _getText(LibraryRecord record) {
    final buffer = StringBuffer()
      ..write('Запись ${record.libraryId.value} от ')
      ..write('${record.savedAt.toIso8601String()}. ')
      ..write('Тема: ${_clip(record.topic, 200)}. ')
      ..write('Статей: ${record.papers.length}. ')
      ..write('Обзор: ${_clip(record.digest.overview, 800)}');
    for (final item in record.digest.items) {
      buffer
        ..write('\n- ${item.arxivId.value}: ')
        ..write(_clip(item.finding, 220));
    }
    return _clipText(buffer.toString(), 4000);
  }

  static const _saveAnnotations = sdk.ToolAnnotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
  );

  static const _readAnnotations = sdk.ToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
  );

  sdk.JsonObject _saveInputSchema() => sdk.JsonSchema.object(
    description:
        'Digest v1, 1–10 снимков Paper v1, тема и необязательный runId.',
    properties: <String, sdk.JsonSchema>{
      'digest': _digestInputSchema(),
      'papers': sdk.JsonSchema.array(
        items: _paperInputSchema(),
        minItems: _limits.minPapers,
        maxItems: _limits.maxPapers,
        description:
            'Полные Paper v1 из arxiv.search_papers / get_paper; сервер не '
            'ищет статьи сам.',
      ),
      'topic': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxTopicCharacters,
        description: 'Тема подборки; должна совпадать с digest.topic.',
      ),
      'runId': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxRunIdCharacters,
        description:
            'Доверенный идентификатор запуска для идемпотентного повтора. '
            'Без него каждая ручная запись получает новый libraryId.',
      ),
    },
    required: <String>['digest', 'papers', 'topic'],
    additionalProperties: false,
  );

  sdk.JsonObject _listInputSchema() => sdk.JsonSchema.object(
    description: 'Необязательные поиск, размер страницы и keyset-курсор.',
    properties: <String, sdk.JsonSchema>{
      'query': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxQueryCharacters,
        description:
            'Поиск без учёта регистра по теме, сводке, статьям, arXiv ID и '
            'runId.',
      ),
      'limit': sdk.JsonSchema.integer(
        minimum: 1,
        maximum: _limits.maxListLimit,
        description:
            'Размер страницы, по умолчанию ${_limits.defaultListLimit}.',
      ),
      'cursor': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxCursorCharacters,
        description:
            'Непрозрачный nextCursor предыдущей страницы того же запроса.',
      ),
    },
    required: const <String>[],
    additionalProperties: false,
  );

  sdk.JsonObject _getInputSchema() => sdk.JsonSchema.object(
    description: 'Идентификатор сохранённой записи.',
    properties: <String, sdk.JsonSchema>{
      'libraryId': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 64,
        pattern: r'^lib_[a-z0-9]{16,64}$',
        description: 'Идентификатор из save_digest или list_saved.',
      ),
    },
    required: const <String>['libraryId'],
    additionalProperties: false,
  );

  sdk.JsonObject _saveOutputSchema() => sdk.JsonSchema.object(
    description: 'Результат сохранения: идентификатор, время и счётчики.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'libraryId': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
      'runId': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxRunIdCharacters,
      ),
      'savedAt': sdk.JsonSchema.string(format: 'date-time'),
      'topic': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxTopicCharacters,
      ),
      'paperCount': sdk.JsonSchema.integer(
        minimum: 1,
        maximum: _limits.maxPapers,
      ),
      'itemCount': sdk.JsonSchema.integer(
        minimum: 1,
        maximum: _limits.maxPapers,
      ),
      'created': sdk.JsonSchema.boolean(),
      'recordRef': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 256,
        format: 'uri',
      ),
    },
    required: const <String>[
      'schemaVersion',
      'libraryId',
      'savedAt',
      'topic',
      'paperCount',
      'itemCount',
      'created',
      'recordRef',
    ],
    additionalProperties: false,
  );

  sdk.JsonObject _listOutputSchema() => sdk.JsonSchema.object(
    description: 'Страница карточек библиотеки в стабильном порядке.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'records': sdk.JsonSchema.array(
        items: _cardSchema(),
        maxItems: _limits.maxListLimit,
      ),
      'nextCursor': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxCursorCharacters,
      ),
      'totalCount': sdk.JsonSchema.integer(minimum: 0),
    },
    required: const <String>['schemaVersion', 'records', 'totalCount'],
    additionalProperties: false,
  );

  sdk.JsonObject _cardSchema() => sdk.JsonSchema.object(
    properties: <String, sdk.JsonSchema>{
      'libraryId': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
      'runId': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxRunIdCharacters,
      ),
      'topic': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxTopicCharacters,
      ),
      'savedAt': sdk.JsonSchema.string(format: 'date-time'),
      'paperCount': sdk.JsonSchema.integer(
        minimum: 1,
        maximum: _limits.maxPapers,
      ),
      'itemCount': sdk.JsonSchema.integer(
        minimum: 1,
        maximum: _limits.maxPapers,
      ),
      'arxivIds': sdk.JsonSchema.array(
        items: sdk.JsonSchema.string(minLength: 1, maxLength: 64),
        minItems: 1,
        maxItems: _limits.maxPapers,
      ),
      'recordRef': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 256,
        format: 'uri',
      ),
    },
    required: const <String>[
      'libraryId',
      'topic',
      'savedAt',
      'paperCount',
      'itemCount',
      'arxivIds',
      'recordRef',
    ],
    additionalProperties: false,
  );

  sdk.JsonObject _recordSchema() => sdk.JsonSchema.object(
    description: 'Полная запись библиотеки: Paper v1 и Digest v1.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'libraryId': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
      'runId': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxRunIdCharacters,
      ),
      'topic': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxTopicCharacters,
      ),
      'papers': sdk.JsonSchema.array(
        items: _paperOutputSchema(),
        minItems: _limits.minPapers,
        maxItems: _limits.maxPapers,
      ),
      'digest': _digestOutputSchema(),
      'savedAt': sdk.JsonSchema.string(format: 'date-time'),
      'revision': sdk.JsonSchema.integer(minimum: 0),
    },
    required: const <String>[
      'schemaVersion',
      'libraryId',
      'topic',
      'papers',
      'digest',
      'savedAt',
      'revision',
    ],
    additionalProperties: false,
  );

  sdk.JsonObject _paperInputSchema() => sdk.JsonSchema.object(
    description:
        'Paper v1 из core/research; версия схемы проверяется сервером.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(
        minimum: 1,
        description: 'Поддерживается ровно Paper v1; иначе version_mismatch.',
      ),
      'arxivId': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
      'version': sdk.JsonSchema.string(minLength: 2, maxLength: 8),
      'title': sdk.JsonSchema.string(minLength: 1, maxLength: 4096),
      'authors': sdk.JsonSchema.array(
        items: sdk.JsonSchema.string(minLength: 1, maxLength: 512),
        minItems: 1,
        maxItems: 100,
      ),
      'abstract': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxPaperBytes,
      ),
      'categories': sdk.JsonSchema.array(
        items: sdk.JsonSchema.string(minLength: 1, maxLength: 64),
        maxItems: 20,
      ),
      'publishedAt': sdk.JsonSchema.string(format: 'date-time'),
      'updatedAt': sdk.JsonSchema.string(format: 'date-time'),
      'abstractUrl': sdk.JsonSchema.string(format: 'uri'),
    },
    required: const <String>[
      'schemaVersion',
      'arxivId',
      'title',
      'authors',
      'abstract',
      'categories',
      'publishedAt',
      'updatedAt',
    ],
    additionalProperties: false,
  );

  sdk.JsonObject _paperOutputSchema() => sdk.JsonSchema.object(
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
      'abstract': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxPaperBytes,
      ),
      'categories': sdk.JsonSchema.array(
        items: sdk.JsonSchema.string(minLength: 1, maxLength: 64),
        maxItems: 20,
      ),
      'publishedAt': sdk.JsonSchema.string(format: 'date-time'),
      'updatedAt': sdk.JsonSchema.string(format: 'date-time'),
      'abstractUrl': sdk.JsonSchema.string(format: 'uri'),
    },
    required: const <String>[
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

  sdk.JsonObject _digestInputSchema() => sdk.JsonSchema.object(
    description: 'Digest v1 из digest.summarize_papers.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(
        minimum: 1,
        description: 'Поддерживается ровно Digest v1; иначе version_mismatch.',
      ),
      'topic': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxTopicCharacters,
      ),
      'sourceScope': sdk.JsonSchema.string(
        enumValues: const <String>[digestSourceScopeAbstract],
      ),
      'overview': sdk.JsonSchema.string(minLength: 1, maxLength: 4096),
      'items': sdk.JsonSchema.array(
        items: _digestItemInputSchema(),
        minItems: _limits.minPapers,
        maxItems: _limits.maxPapers,
      ),
      'generatedAt': sdk.JsonSchema.string(format: 'date-time'),
    },
    required: const <String>[
      'schemaVersion',
      'topic',
      'sourceScope',
      'overview',
      'items',
      'generatedAt',
    ],
    additionalProperties: false,
  );

  sdk.JsonObject _digestItemInputSchema() => sdk.JsonSchema.object(
    properties: <String, sdk.JsonSchema>{
      'arxivId': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
      'abstractUrl': sdk.JsonSchema.string(format: 'uri'),
      'finding': sdk.JsonSchema.string(minLength: 1, maxLength: 4096),
      'limitation': sdk.JsonSchema.string(minLength: 1, maxLength: 1000),
    },
    required: const <String>['arxivId', 'finding'],
    additionalProperties: false,
  );

  sdk.JsonObject _digestOutputSchema() => sdk.JsonSchema.object(
    description: 'Digest v1 из core/research.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'topic': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxTopicCharacters,
      ),
      'sourceScope': sdk.JsonSchema.string(
        enumValues: const <String>[digestSourceScopeAbstract],
      ),
      'overview': sdk.JsonSchema.string(minLength: 1, maxLength: 4096),
      'items': sdk.JsonSchema.array(
        items: sdk.JsonSchema.object(
          properties: <String, sdk.JsonSchema>{
            'arxivId': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
            'abstractUrl': sdk.JsonSchema.string(format: 'uri'),
            'finding': sdk.JsonSchema.string(minLength: 1, maxLength: 4096),
            'limitation': sdk.JsonSchema.string(minLength: 1, maxLength: 1000),
          },
          required: const <String>['arxivId', 'abstractUrl', 'finding'],
          additionalProperties: false,
        ),
        minItems: _limits.minPapers,
        maxItems: _limits.maxPapers,
      ),
      'generatedAt': sdk.JsonSchema.string(format: 'date-time'),
    },
    required: const <String>[
      'schemaVersion',
      'topic',
      'sourceScope',
      'overview',
      'items',
      'generatedAt',
    ],
    additionalProperties: false,
  );
}

final class _SaveRequest {
  const _SaveRequest({
    required this.topic,
    required this.digest,
    required this.papers,
    required this.runId,
  });

  final String topic;
  final Digest digest;
  final List<Paper> papers;
  final String? runId;
}

final class _ListRequest {
  const _ListRequest({
    required this.query,
    required this.limit,
    required this.cursor,
  });

  final String? query;
  final int limit;
  final String? cursor;
}

final class _GetRequest {
  const _GetRequest(this.libraryId);

  final LibraryId libraryId;
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

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../../core/llm/llm.dart';
import '../../../../core/research/research.dart';
import '../../local/local_mcp_definition.dart';
import 'digest_failure.dart';
import 'digest_limits.dart';
import 'digest_model_pin.dart';
import 'digest_synthesizer.dart';

/// Stable identity of the local `digest` MCP server.
const digestServerId = 'digest';

/// Display name shown in the MCP connection UI.
const digestServerDisplayName = 'Digest';

/// Version of this server's tools and schemas.
const digestServerVersion = '1.0.0';

/// Original tool name of the server.
const digestSummarizeToolName = 'summarize_papers';

const _serverInstructions =
    'Сводки Digest v1 по аннотациям arXiv (sourceScope=abstract). '
    'Сервер не обращается к arXiv и не сохраняет библиотеку: статьи '
    'передаёт вызывающий агент, результат получает вызывающий агент. '
    'Модель для вызова задаёт композиция Domovoy, а не аргументы инструмента.';

/// `LocalMcpServerFactory` of the built-in `digest` server.
///
/// B9 composes it explicitly, for example:
///
/// ```dart
/// final digest = DigestMcpServerFactory(
///   registry: appRegistry,          // the existing Domovoy registry
///   pins: DigestModelPinRegistry(   // trusted per-run pin table
///     scopeKeyOf: (scope) => scope.meta['domovoy/runScope'] as String?,
///   ),
/// );
/// host.register(digest);
/// ```
///
/// The factory never creates a provider client or a secret store: it uses
/// exactly the [LlmProviderRegistry] and credentials the composition already
/// owns. It also never reads a global "current model": every invocation gets
/// its model from the injected [DigestModelPinResolver], so two concurrent
/// calls with different pins stay isolated.
final class DigestMcpServerFactory implements LocalMcpServerFactory {
  DigestMcpServerFactory({
    required LlmProviderRegistry registry,
    required DigestModelPinResolver pins,
    DigestLimits limits = const DigestLimits(),
    DigestClock? clock,
  }) : _limits = limits.validate(),
       _pins = pins,
       synthesizer = DigestSynthesizer(
         registry: registry,
         limits: limits,
         clock: clock,
       );

  final DigestLimits _limits;
  final DigestModelPinResolver _pins;

  /// Shared synthesizer; exposed for diagnostics and composition tests.
  final DigestSynthesizer synthesizer;

  @override
  LocalMcpServerDefinition create() => LocalMcpServerDefinition(
    serverId: digestServerId,
    displayName: digestServerDisplayName,
    version: digestServerVersion,
    instructions: _serverInstructions,
    registerTools: _registerTools,
  );

  void _registerTools(sdk.McpServer server) {
    server.registerTool(
      digestSummarizeToolName,
      title: 'Сводка по аннотациям arXiv',
      description:
          'Строит Digest v1 (sourceScope=abstract) по 1–10 полностью '
          'заполненным Paper v1, используя закреплённую для вызова модель '
          'Domovoy. Проверяются только аннотации; сервер не ищет статьи в '
          'arXiv и не сохраняет библиотеку. Каждый пункт привязан к '
          'переданному arXiv ID; ссылка строится из проверенного ID.',
      inputSchema: _inputSchema(),
      outputSchema: _outputSchema(),
      annotations: _annotations,
      callback: (args, extra) => _summarizePapers(args, extra),
    );
  }

  Future<sdk.CallToolResult> _summarizePapers(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelledFailure());
    }
    try {
      final request = _parseRequest(args);
      final pin = _resolvePin(extra);
      final cancellation = CancellationSource();
      final abortSubscription = extra.signal.onAbort.listen(
        (_) => cancellation.cancel(),
      );
      try {
        final digest = await synthesizer.synthesize(
          request,
          model: pin.model,
          cancellation: cancellation.token,
        );
        if (extra.signal.aborted) {
          return _failure(_cancelledFailure());
        }
        return _success(digest, pin.model);
      } finally {
        await abortSubscription.cancel();
      }
    } on DigestFailure catch (failure) {
      return _failure(failure);
    } on Object {
      return _failure(
        DigestFailure(
          kind: DigestFailureKind.internal,
          message: 'Внутренняя ошибка digest-сервера.',
        ),
      );
    }
  }

  DigestSynthesisRequest _parseRequest(Map<String, dynamic> args) {
    const knownKeys = <String>{'topic', 'papers', 'language', 'goal'};
    for (final key in args.keys) {
      if (!knownKeys.contains(key)) {
        throwDigest(
          DigestFailureKind.invalidInput,
          'Неизвестный параметр "$key".',
        );
      }
    }
    final topic = args['topic'];
    if (topic is! String || topic.trim().isEmpty) {
      throwDigest(
        DigestFailureKind.invalidInput,
        'Параметр "topic" должен быть непустой строкой.',
      );
    }
    if (topic.trim().length > _limits.maxTopicCharacters) {
      throwDigest(
        DigestFailureKind.invalidInput,
        'Параметр "topic" длиннее ${_limits.maxTopicCharacters} символов.',
      );
    }
    final rawPapers = args['papers'];
    if (rawPapers is! List) {
      throwDigest(
        DigestFailureKind.invalidInput,
        'Параметр "papers" должен быть массивом Paper v1.',
      );
    }
    if (rawPapers.length < _limits.minPapers ||
        rawPapers.length > _limits.maxPapers) {
      throwDigest(
        DigestFailureKind.invalidInput,
        'Ожидается от ${_limits.minPapers} до ${_limits.maxPapers} статей, '
        'получено ${rawPapers.length}.',
      );
    }
    final papers = <Paper>[];
    for (var index = 0; index < rawPapers.length; index++) {
      try {
        papers.add(Paper.fromJson(rawPapers[index]));
      } on ResearchException catch (error) {
        throwDigest(
          DigestFailureKind.invalidInput,
          'Статья #${index + 1} не является полным Paper v1: '
          '${error.error.message}',
        );
      }
    }
    return DigestSynthesisRequest(
      topic: topic,
      papers: papers,
      language: _optionalText(args, 'language', _limits.maxLanguageCharacters),
      goal: _optionalText(args, 'goal', _limits.maxGoalCharacters),
    );
  }

  String? _optionalText(Map<String, dynamic> args, String key, int maxLength) {
    final value = args[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throwDigest(
        DigestFailureKind.invalidInput,
        'Параметр "$key" должен быть строкой.',
      );
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.length > maxLength) {
      throwDigest(
        DigestFailureKind.invalidInput,
        'Параметр "$key" длиннее $maxLength символов.',
      );
    }
    return trimmed;
  }

  /// Resolves the trusted per-invocation pin; never falls back to a global.
  DigestModelPin _resolvePin(sdk.RequestHandlerExtra extra) {
    final scope = DigestInvocationScope(
      requestId: extra.requestId.toString(),
      sessionId: extra.sessionId,
      taskId: extra.taskId,
      meta: extra.meta,
    );
    DigestModelPin? pin;
    try {
      pin = _pins.resolve(scope);
    } on Object {
      pin = null;
    }
    if (pin == null) {
      throwDigest(
        DigestFailureKind.modelUnavailable,
        'Для этого вызова не закреплена модель: контекст запуска не передал '
        'доверенный выбор. Сводка не создана.',
      );
    }
    return pin;
  }

  DigestFailure _cancelledFailure() => DigestFailure(
    kind: DigestFailureKind.cancelled,
    message: 'Вызов отменён клиентом.',
  );

  sdk.CallToolResult _success(Digest digest, ModelRef model) =>
      sdk.CallToolResult(
        content: <sdk.Content>[
          sdk.TextContent(text: _summaryText(digest, model)),
        ],
        structuredContent: digest.toJson(),
      );

  sdk.CallToolResult _failure(DigestFailure failure) => sdk.CallToolResult(
    isError: true,
    content: <sdk.Content>[sdk.TextContent(text: failure.mcpText)],
  );

  String _summaryText(Digest digest, ModelRef model) {
    final buffer = StringBuffer()
      ..write(
        'Digest v1 (sourceScope=abstract, статей: ${digest.items.length}, ',
      )
      ..write('модель: $model). ')
      ..write(
        'Сводка составлена только по переданным аннотациям arXiv; '
        'полные тексты PDF не читались. ',
      )
      ..write(_clip(digest.overview, 1200));
    for (final item in digest.items) {
      buffer
        ..write('\n- ${item.arxivId.value}: ')
        ..write(_clip(item.finding, 220));
      final limitation = item.limitation;
      if (limitation != null) {
        buffer.write(' [ограничение: ${_clip(limitation, 120)}]');
      }
    }
    return _clipText(buffer.toString(), 4000);
  }

  static const _annotations = sdk.ToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: true,
  );

  sdk.JsonObject _inputSchema() => sdk.JsonSchema.object(
    description: 'Тема подборки и 1–10 полных объектов Paper v1.',
    properties: <String, sdk.JsonSchema>{
      'topic': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxTopicCharacters,
        description: 'Тема подборки, заданная вызывающим агентом.',
      ),
      'papers': sdk.JsonSchema.array(
        items: _paperInputSchema(),
        minItems: _limits.minPapers,
        maxItems: _limits.maxPapers,
        description:
            'Полные Paper v1 из arxiv.search_papers / get_paper; сервер '
            'не ищет статьи сам.',
      ),
      'language': sdk.JsonSchema.string(
        minLength: 2,
        maxLength: _limits.maxLanguageCharacters,
        description: 'Необязательный язык сводки, например ru или en.',
      ),
      'goal': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxGoalCharacters,
        description: 'Необязательная цель подборки.',
      ),
    },
    required: <String>['topic', 'papers'],
    additionalProperties: false,
  );

  sdk.JsonObject _paperInputSchema() => sdk.JsonSchema.object(
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
        maxLength: _limits.maxPaperAbstractBytes,
      ),
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
    ],
    additionalProperties: false,
  );

  sdk.JsonObject _outputSchema() => sdk.JsonSchema.object(
    description: 'Digest v1 из core/research.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'topic': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxTopicCharacters,
      ),
      'sourceScope': sdk.JsonSchema.string(
        enumValues: const <String>[digestSourceScopeAbstract],
        description: 'Единственный источник v1 — аннотации.',
      ),
      'overview': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: _limits.maxOverviewCharacters,
      ),
      'items': sdk.JsonSchema.array(
        items: sdk.JsonSchema.object(
          properties: <String, sdk.JsonSchema>{
            'arxivId': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
            'abstractUrl': sdk.JsonSchema.string(format: 'uri'),
            'finding': sdk.JsonSchema.string(
              minLength: 1,
              maxLength: _limits.maxFindingCharacters,
            ),
            'limitation': sdk.JsonSchema.string(
              minLength: 1,
              maxLength: _limits.maxLimitationCharacters,
            ),
          },
          required: <String>['arxivId', 'abstractUrl', 'finding'],
          additionalProperties: false,
        ),
        minItems: _limits.minPapers,
        maxItems: _limits.maxPapers,
      ),
      'generatedAt': sdk.JsonSchema.string(format: 'date-time'),
    },
    required: <String>[
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

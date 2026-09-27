import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../../../../core/automation/automation.dart';
import '../../../../core/llm/cancellation.dart';
import '../../../../core/llm/identifiers.dart';
import '../../local/local_mcp_definition.dart';
import 'automation_failure.dart';

/// Stable identity of the local `automation` MCP server.
const automationServerId = 'automation';

/// Display name shown in the MCP connection UI.
const automationServerDisplayName = 'Automation';

/// Version of this server's tools and schemas.
const automationServerVersion = '1.0.0';

/// Original tool names of the server.
const automationCreateTaskToolName = 'create_task';
const automationListTasksToolName = 'list_tasks';
const automationPauseTaskToolName = 'pause_task';
const automationRunTaskNowToolName = 'run_task_now';

const _serverInstructions =
    'Планировщик Domovoy: задачи с разовым моментом или пятичастным cron в '
    'явном часовом поясе IANA. create_task создаёт только предложение, которое '
    'включает человек в разделе «Задачи». Задача по расписанию не может '
    'создавать расписания и запускать другие задачи. Задания выполняются, '
    'только пока приложение открыто.';

/// `LocalMcpServerFactory` of the built-in `automation` server.
///
/// B9 composes it over the same [AutomationService] the tasks UI uses:
///
/// ```dart
/// localHost.register(AutomationMcpServerFactory(service: automation.service));
/// await localHost.start('automation'); // serverId стабилен: 'automation'
/// ```
final class AutomationMcpServerFactory implements LocalMcpServerFactory {
  AutomationMcpServerFactory({
    required this.service,
    AutomationLimits limits = const AutomationLimits(),
  }) : limits = limits.validate();

  /// The only scheduler of the application.
  final AutomationService service;
  final AutomationLimits limits;

  @override
  LocalMcpServerDefinition create() => LocalMcpServerDefinition(
    serverId: automationServerId,
    displayName: automationServerDisplayName,
    version: automationServerVersion,
    instructions: _serverInstructions,
    registerTools: _registerTools,
  );

  void _registerTools(sdk.McpServer server) {
    server.registerTool(
      automationCreateTaskToolName,
      title: 'Предложить задачу по расписанию',
      description:
          'Создаёт ПРЕДЛОЖЕНИЕ задачи: название, промпт, разовый момент '
          '(runAt) или cron (cron + timeZone), модель, разрешённые '
          'инструменты и доставку. Задача не включается до подтверждения '
          'человеком в разделе «Задачи»; предложение возвращает ближайшие три '
          'запуска. Запланированный запуск не может создавать задачи.',
      inputSchema: _createInputSchema(),
      outputSchema: _proposalSchema(),
      annotations: _createAnnotations,
      callback: (args, extra) => _createTask(args, extra),
    );
    server.registerTool(
      automationListTasksToolName,
      title: 'Список задач автоматизации',
      description:
          'Возвращает задачи со статусом, расписанием, ближайшим запуском и '
          'последним результатом. Фильтр status: active, paused, proposed, '
          'completed, deleted или all.',
      inputSchema: _listInputSchema(),
      outputSchema: _listOutputSchema(),
      annotations: _readAnnotations,
      callback: (args, extra) => _listTasks(args, extra),
    );
    server.registerTool(
      automationPauseTaskToolName,
      title: 'Приостановить или возобновить задачу',
      description:
          'Переводит задачу в паузу (paused=true) или возобновляет её '
          '(paused=false). Необязательный expectedRevision защищает от '
          'перезаписи чужого изменения. Возвращает новое состояние и ревизию.',
      inputSchema: _pauseInputSchema(),
      outputSchema: _pauseOutputSchema(),
      annotations: _pauseAnnotations,
      callback: (args, extra) => _pauseTask(args, extra),
    );
    server.registerTool(
      automationRunTaskNowToolName,
      title: 'Запустить задачу сейчас',
      description:
          'Немедленно создаёт отдельный запуск задачи и возвращает runId; '
          'следующий плановый момент не сдвигается. Задача-предложение не '
          'запускается до подтверждения человеком. Инструмент недоступен '
          'запланированным запускам: они не могут запускать другие задачи.',
      inputSchema: _runNowInputSchema(),
      outputSchema: _runNowOutputSchema(),
      annotations: _runNowAnnotations,
      callback: (args, extra) => _runTaskNow(args, extra),
    );
  }

  Future<sdk.CallToolResult> _createTask(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelled());
    }
    final cancellation = CancellationSource();
    final abortSubscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    try {
      final request = _parseCreateRequest(args);
      final draft = AutomationTaskDraft(
        name: request.name,
        prompt: request.prompt,
        schedule: request.schedule,
        model: request.model,
        allowedToolIds: request.allowedToolIds,
        delivery: request.delivery,
        origin: AutomationTaskOrigin.agent,
      );
      final task = await service.createTask(
        draft,
        origin: AutomationCallOrigin.agentTool,
      );
      return _proposalSuccess(task);
    } on AutomationFailure catch (failure) {
      return _failure(failure);
    } on AutomationException catch (error) {
      return _failure(AutomationFailure.fromError(error.error));
    } on Object {
      return _failure(_internal());
    } finally {
      await abortSubscription.cancel();
    }
  }

  Future<sdk.CallToolResult> _listTasks(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelled());
    }
    final cancellation = CancellationSource();
    final abortSubscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    try {
      final request = _parseListRequest(args);
      final tasks = await service.listTasks(
        includeDeleted: request.includeDeleted,
        state: request.state,
      );
      final selected = tasks.take(request.limit).toList(growable: false);
      final records = <Map<String, Object?>>[];
      for (final task in selected) {
        final runs = await service.listRuns(task.taskId, limit: 1);
        records.add(_taskRecord(task, runs.isEmpty ? null : runs.first));
      }
      if (extra.signal.aborted) {
        return _failure(_cancelled());
      }
      return _listSuccess(records, tasks.length);
    } on AutomationFailure catch (failure) {
      return _failure(failure);
    } on AutomationException catch (error) {
      return _failure(AutomationFailure.fromError(error.error));
    } on Object {
      return _failure(_internal());
    } finally {
      await abortSubscription.cancel();
    }
  }

  Future<sdk.CallToolResult> _pauseTask(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelled());
    }
    final cancellation = CancellationSource();
    final abortSubscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    try {
      final request = _parsePauseRequest(args);
      final task = await service.setPaused(
        request.taskId,
        request.paused,
        expectedRevision: request.expectedRevision,
      );
      return _pauseSuccess(task, request.paused);
    } on AutomationFailure catch (failure) {
      return _failure(failure);
    } on AutomationException catch (error) {
      return _failure(AutomationFailure.fromError(error.error));
    } on Object {
      return _failure(_internal());
    } finally {
      await abortSubscription.cancel();
    }
  }

  Future<sdk.CallToolResult> _runTaskNow(
    Map<String, dynamic> args,
    sdk.RequestHandlerExtra extra,
  ) async {
    if (extra.signal.aborted) {
      return _failure(_cancelled());
    }
    final cancellation = CancellationSource();
    final abortSubscription = extra.signal.onAbort.listen(
      (_) => cancellation.cancel(),
    );
    try {
      final request = _parseRunNowRequest(args);
      if (service.isScheduledRunActive) {
        // Defense in depth next to the intrinsic B2 denial: while a scheduled
        // run executes in this process, this tool refuses to start another
        // task even if it somehow reached the server.
        throwAutomationFailure(
          AutomationFailureKind.denied,
          'Запуск другой задачи недоступен, пока выполняется запланированный '
          'запуск.',
        );
      }
      final handle = await service.runTaskNow(
        request.taskId,
        origin: AutomationCallOrigin.agentTool,
        expectedRevision: request.expectedRevision,
      );
      return _runNowSuccess(handle);
    } on AutomationFailure catch (failure) {
      return _failure(failure);
    } on AutomationException catch (error) {
      return _failure(AutomationFailure.fromError(error.error));
    } on Object {
      return _failure(_internal());
    } finally {
      await abortSubscription.cancel();
    }
  }

  _CreateRequest _parseCreateRequest(Map<String, dynamic> args) {
    _rejectUnknownKeys(args, const <String>{
      'name',
      'prompt',
      'cron',
      'runAt',
      'timeZone',
      'model',
      'allowedTools',
      'delivery',
    });
    final name = _requireText(
      args,
      'name',
      maxLength: limits.maxNameCharacters,
    );
    final prompt = _requireText(
      args,
      'prompt',
      maxLength: limits.maxPromptCharacters,
    );
    final cron = _optionalText(args, 'cron', maxLength: 256);
    final runAt = _optionalText(args, 'runAt', maxLength: 64);
    final timeZone = _optionalText(args, 'timeZone', maxLength: 64);
    if ((cron == null) == (runAt == null)) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'Укажите ровно одно расписание: cron или runAt.',
      );
    }
    final AutomationSchedule schedule;
    if (cron != null) {
      if (timeZone == null) {
        throwAutomationFailure(
          AutomationFailureKind.invalidInput,
          'Для cron обязателен явный часовой пояс IANA в timeZone.',
        );
      }
      try {
        schedule = AutomationSchedule.cron(
          expression: cron,
          timeZoneId: timeZone,
        );
      } on AutomationException catch (error) {
        throwAutomationFailure(
          AutomationFailureKind.invalidSchedule,
          error.error.message,
        );
      }
    } else {
      final parsed = DateTime.tryParse(runAt!);
      if (parsed == null) {
        throwAutomationFailure(
          AutomationFailureKind.invalidInput,
          'runAt должен быть ISO 8601 моментом.',
        );
      }
      schedule = AutomationSchedule.oneShot(parsed.toUtc());
    }
    final model = _parseModel(args['model']);
    final allowedTools = _parseToolIds(args['allowedTools']);
    final delivery = _parseDelivery(args['delivery']);
    return _CreateRequest(
      name: name,
      prompt: prompt,
      schedule: schedule,
      model: model,
      allowedToolIds: allowedTools,
      delivery: delivery,
    );
  }

  _ListRequest _parseListRequest(Map<String, dynamic> args) {
    _rejectUnknownKeys(args, const <String>{'status', 'limit'});
    final status = _optionalText(args, 'status', maxLength: 32);
    AutomationTaskState? state;
    var includeDeleted = false;
    if (status != null && status != 'all') {
      try {
        state = AutomationTaskState.fromWire(status);
      } on AutomationException {
        throwAutomationFailure(
          AutomationFailureKind.invalidInput,
          'status должен быть active, paused, proposed, completed, deleted '
          'или all.',
        );
      }
      includeDeleted = state == AutomationTaskState.deleted;
    } else if (status == 'all') {
      includeDeleted = true;
    }
    final limit = _optionalInt(args, 'limit') ?? 50;
    if (limit < 1 || limit > limits.maxTasks) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'limit должен быть от 1 до ${limits.maxTasks}.',
      );
    }
    return _ListRequest(
      state: state,
      includeDeleted: includeDeleted,
      limit: limit,
    );
  }

  _PauseRequest _parsePauseRequest(Map<String, dynamic> args) {
    _rejectUnknownKeys(args, const <String>{
      'taskId',
      'paused',
      'expectedRevision',
    });
    final paused = args['paused'];
    if (paused is! bool) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'paused должен быть булевым значением.',
      );
    }
    return _PauseRequest(
      taskId: _parseTaskId(args['taskId']),
      paused: paused,
      expectedRevision: _optionalInt(args, 'expectedRevision'),
    );
  }

  _RunNowRequest _parseRunNowRequest(Map<String, dynamic> args) {
    _rejectUnknownKeys(args, const <String>{'taskId', 'expectedRevision'});
    return _RunNowRequest(
      taskId: _parseTaskId(args['taskId']),
      expectedRevision: _optionalInt(args, 'expectedRevision'),
    );
  }

  AutomationTaskId _parseTaskId(Object? raw) {
    if (raw is! String) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'taskId должен быть строкой.',
      );
    }
    final taskId = AutomationTaskId.tryParse(raw);
    if (taskId == null) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'taskId должен иметь вид atm_<hex>.',
      );
    }
    return taskId;
  }

  ModelRef _parseModel(Object? raw) {
    if (raw is! String) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'model должен быть строкой вида provider/modelId.',
      );
    }
    final slash = raw.indexOf('/');
    if (slash <= 0 || slash == raw.length - 1) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'model должен быть строкой вида provider/modelId.',
      );
    }
    final provider = raw.substring(0, slash);
    final modelId = raw.substring(slash + 1);
    try {
      return ModelRef(
        providerId: ProviderId(provider),
        modelId: ModelId(modelId),
      );
    } on Object {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'model должен быть строкой вида provider/modelId.',
      );
    }
  }

  List<String> _parseToolIds(Object? raw) {
    if (raw == null) {
      return const <String>[];
    }
    if (raw is! List) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'allowedTools должен быть массивом строк.',
      );
    }
    if (raw.length > limits.maxAllowedTools) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'allowedTools длиннее ${limits.maxAllowedTools} элементов.',
      );
    }
    final result = <String>[];
    for (final value in raw) {
      if (value is! String || value.trim().isEmpty) {
        throwAutomationFailure(
          AutomationFailureKind.invalidInput,
          'allowedTools должен содержать непустые строки.',
        );
      }
      result.add(value.trim());
    }
    return result;
  }

  AutomationDelivery _parseDelivery(Object? raw) {
    if (raw == null) {
      return const AutomationDelivery.tasks();
    }
    if (raw is! Map) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'delivery должен быть объектом.',
      );
    }
    _rejectUnknownKeys(Map<String, dynamic>.from(raw), const <String>{
      'kind',
      'chatId',
    }, label: 'delivery');
    final kind = raw['kind'];
    if (kind == 'tasks') {
      return const AutomationDelivery.tasks();
    }
    if (kind != 'chat') {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'delivery.kind должен быть tasks или chat.',
      );
    }
    final chatId = raw['chatId'];
    if (chatId is! String || chatId.trim().isEmpty) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'Доставка в чат требует непустой delivery.chatId.',
      );
    }
    try {
      return AutomationDelivery.chat(chatId);
    } on AutomationException catch (error) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        error.error.message,
      );
    }
  }

  void _rejectUnknownKeys(
    Map<String, dynamic> value,
    Set<String> expected, {
    String label = 'arguments',
  }) {
    for (final key in value.keys) {
      if (!expected.contains(key)) {
        throwAutomationFailure(
          AutomationFailureKind.invalidInput,
          'Неизвестное поле "$key" в $label.',
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
    if (value is! String || value.trim().isEmpty) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'Параметр "$key" должен быть непустой строкой.',
      );
    }
    final trimmed = value.trim();
    if (trimmed.length > maxLength) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
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
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
        'Параметр "$key" должен быть строкой.',
      );
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (trimmed.length > maxLength) {
      throwAutomationFailure(
        AutomationFailureKind.invalidInput,
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
    if (value is int) {
      return value;
    }
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      return value.toInt();
    }
    throwAutomationFailure(
      AutomationFailureKind.invalidInput,
      'Параметр "$key" должен быть целым числом.',
    );
  }

  sdk.CallToolResult _proposalSuccess(AutomationTask task) {
    final schedule = task.schedule;
    final preview = service.previewOccurrences(schedule);
    final buffer = StringBuffer()
      ..write('Предложение задачи ')
      ..write(task.taskId.value)
      ..write(' создано (состояние proposed). ')
      ..write('Расписание: ${schedule.summary}. ');
    if (preview.isNotEmpty) {
      buffer
        ..write('Ближайшие запуски: ')
        ..write(preview.map((at) => at.toIso8601String()).join(', '))
        ..write('. ');
    }
    buffer.write(
      'Задача включится только после подтверждения человеком в разделе '
      '«Задачи»; само расписание не может создавать новые расписания.',
    );
    return sdk.CallToolResult(
      content: <sdk.Content>[
        sdk.TextContent(text: _clipText(buffer.toString())),
      ],
      structuredContent: <String, Object?>{
        'schemaVersion': 1,
        'taskId': task.taskId.value,
        'taskRef': task.taskId.taskRef,
        'name': task.name,
        'state': task.state.name,
        'origin': task.origin.name,
        'requiresConfirmation': task.state == AutomationTaskState.proposed,
        'revision': task.revision,
        'scheduleKind': schedule.kind,
        if (schedule is CronSchedule) 'cron': schedule.expression,
        if (schedule is CronSchedule) 'timeZone': schedule.timeZoneId,
        if (schedule is OneShotSchedule)
          'runAt': schedule.atUtc.toIso8601String(),
        'nextOccurrences': preview
            .map((at) => at.toIso8601String())
            .toList(growable: false),
      },
    );
  }

  sdk.CallToolResult _listSuccess(
    List<Map<String, Object?>> records,
    int totalCount,
  ) {
    final buffer = StringBuffer()
      ..write('Задач: $totalCount; на странице: ${records.length}.');
    for (final record in records) {
      buffer
        ..write('\n- ${record['taskId']} [${record['state']}] ')
        ..write(_clip(record['name'] as String, 120))
        ..write(' — ${record['scheduleKind']}');
      final nextDueAt = record['nextDueAt'];
      if (nextDueAt is String) {
        buffer.write(', следующий: $nextDueAt');
      }
      final lastRun = record['lastRun'];
      if (lastRun is Map && lastRun['status'] is String) {
        buffer.write(', последний запуск: ${lastRun['status']}');
        final preview = lastRun['resultPreview'];
        if (preview is String) {
          buffer.write(' («${_clip(preview, 120)}»)');
        }
        final error = lastRun['errorMessage'];
        if (error is String) {
          buffer.write(' — ошибка: ${_clip(error, 160)}');
        }
      }
    }
    return sdk.CallToolResult(
      content: <sdk.Content>[
        sdk.TextContent(text: _clipText(buffer.toString())),
      ],
      structuredContent: <String, Object?>{
        'schemaVersion': 1,
        'tasks': records,
        'totalCount': totalCount,
      },
    );
  }

  sdk.CallToolResult _pauseSuccess(AutomationTask task, bool paused) {
    final text = paused
        ? 'Задача ${task.taskId.value} приостановлена; периоды паузы не '
              'воспроизводятся. Ревизия ${task.revision}.'
        : 'Задача ${task.taskId.value} возобновлена; следующий запуск '
              '${task.nextDueAt?.toIso8601String()}. Ревизия ${task.revision}.';
    return sdk.CallToolResult(
      content: <sdk.Content>[sdk.TextContent(text: text)],
      structuredContent: <String, Object?>{
        'schemaVersion': 1,
        'taskId': task.taskId.value,
        'state': task.state.name,
        'revision': task.revision,
        if (task.nextDueAt != null)
          'nextDueAt': task.nextDueAt!.toIso8601String(),
      },
    );
  }

  sdk.CallToolResult _runNowSuccess(AutomationRunHandle handle) {
    return sdk.CallToolResult(
      content: <sdk.Content>[
        sdk.TextContent(
          text:
              'Запуск ${handle.runId.value} задачи ${handle.taskId.value} '
              'создан сейчас; плановый момент не сдвигается. Статус можно '
              'прочитать в разделе «Задачи» по runId.',
        ),
      ],
      structuredContent: <String, Object?>{
        'schemaVersion': 1,
        'taskId': handle.taskId.value,
        'runId': handle.runId.value,
        'runRef': handle.runId.runRef,
        'status': handle.status.name,
        'trigger': handle.trigger.name,
        'scheduledAt': handle.scheduledAt.toIso8601String(),
      },
    );
  }

  Map<String, Object?> _taskRecord(
    AutomationTask task,
    AutomationRun? lastRun,
  ) {
    final schedule = task.schedule;
    final resultPreview = lastRun?.resultText;
    return <String, Object?>{
      'taskId': task.taskId.value,
      'taskRef': task.taskId.taskRef,
      'name': task.name,
      'state': task.state.name,
      'origin': task.origin.name,
      'revision': task.revision,
      'scheduleKind': schedule.kind,
      if (schedule is CronSchedule) 'cron': schedule.expression,
      if (schedule is CronSchedule) 'timeZone': schedule.timeZoneId,
      if (schedule is OneShotSchedule)
        'runAt': schedule.atUtc.toIso8601String(),
      if (task.nextDueAt != null)
        'nextDueAt': task.nextDueAt!.toIso8601String(),
      'allowedToolCount': task.allowedToolIds.length,
      'deliveryKind': task.delivery.kind.name,
      if (lastRun != null)
        'lastRun': <String, Object?>{
          'runId': lastRun.runId.value,
          'status': lastRun.status.name,
          'trigger': lastRun.trigger.name,
          'scheduledAt': lastRun.scheduledAt.toIso8601String(),
          if (lastRun.finishedAt != null)
            'finishedAt': lastRun.finishedAt!.toIso8601String(),
          if (resultPreview != null && resultPreview.isNotEmpty)
            'resultPreview': _clip(resultPreview, 280),
          if (lastRun.error != null) 'errorKind': lastRun.error!.kind.name,
          if (lastRun.error != null)
            'errorMessage': _clip(lastRun.error!.message, 280),
          if (lastRun.aggregatedSkippedCount > 0)
            'aggregatedSkippedCount': lastRun.aggregatedSkippedCount,
        },
    };
  }

  sdk.CallToolResult _failure(AutomationFailure failure) => sdk.CallToolResult(
    isError: true,
    content: <sdk.Content>[sdk.TextContent(text: failure.mcpText)],
  );

  AutomationFailure _cancelled() => AutomationFailure(
    kind: AutomationFailureKind.cancelled,
    message: 'Вызов отменён клиентом.',
  );

  AutomationFailure _internal() => AutomationFailure(
    kind: AutomationFailureKind.internal,
    message: 'Внутренняя ошибка планировщика; состояние не изменено.',
  );

  static const _createAnnotations = sdk.ToolAnnotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: false,
  );

  static const _readAnnotations = sdk.ToolAnnotations(
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
  );

  static const _pauseAnnotations = sdk.ToolAnnotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
  );

  static const _runNowAnnotations = sdk.ToolAnnotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: false,
  );

  sdk.JsonObject _createInputSchema() => sdk.JsonSchema.object(
    description:
        'Предложение задачи: ровно одно из cron или runAt, модель, '
        'разрешённые инструменты и доставка.',
    properties: <String, sdk.JsonSchema>{
      'name': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: limits.maxNameCharacters,
      ),
      'prompt': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: limits.maxPromptCharacters,
      ),
      'cron': sdk.JsonSchema.string(
        minLength: 5,
        maxLength: 256,
        description: 'Пятичастное выражение, например */5 * * * *.',
      ),
      'runAt': sdk.JsonSchema.string(
        format: 'date-time',
        description: 'Разовый момент в будущем (ISO 8601).',
      ),
      'timeZone': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 64,
        description: 'Обязательный IANA-пояс для cron, например Europe/Moscow.',
      ),
      'model': sdk.JsonSchema.string(
        minLength: 3,
        maxLength: 200,
        description: 'Провайдер и модель: provider/modelId.',
      ),
      'allowedTools': sdk.JsonSchema.array(
        items: sdk.JsonSchema.string(minLength: 1, maxLength: 128),
        maxItems: limits.maxAllowedTools,
        description:
            'Стабильные идентификаторы инструментов, которые разрешены '
            'запуску. Пустой список — запуск без инструментов.',
      ),
      'delivery': sdk.JsonSchema.object(
        properties: <String, sdk.JsonSchema>{
          'kind': sdk.JsonSchema.string(
            enumValues: const <String>['tasks', 'chat'],
          ),
          'chatId': sdk.JsonSchema.string(minLength: 1, maxLength: 128),
        },
        required: const <String>['kind'],
        additionalProperties: false,
      ),
    },
    required: const <String>['name', 'prompt', 'model'],
    additionalProperties: false,
  );

  sdk.JsonObject _listInputSchema() => sdk.JsonSchema.object(
    description: 'Фильтр статуса и размер страницы.',
    properties: <String, sdk.JsonSchema>{
      'status': sdk.JsonSchema.string(
        enumValues: const <String>[
          'active',
          'paused',
          'proposed',
          'completed',
          'deleted',
          'all',
        ],
      ),
      'limit': sdk.JsonSchema.integer(minimum: 1, maximum: limits.maxTasks),
    },
    required: const <String>[],
    additionalProperties: false,
  );

  sdk.JsonObject _pauseInputSchema() => sdk.JsonSchema.object(
    description: 'Идентификатор задачи, желаемое состояние и ревизия.',
    properties: <String, sdk.JsonSchema>{
      'taskId': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 80,
        pattern: r'^atm_[a-z0-9]{16,64}$',
      ),
      'paused': sdk.JsonSchema.boolean(),
      'expectedRevision': sdk.JsonSchema.integer(minimum: 0),
    },
    required: const <String>['taskId', 'paused'],
    additionalProperties: false,
  );

  sdk.JsonObject _runNowInputSchema() => sdk.JsonSchema.object(
    description: 'Идентификатор задачи для немедленного запуска.',
    properties: <String, sdk.JsonSchema>{
      'taskId': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 80,
        pattern: r'^atm_[a-z0-9]{16,64}$',
      ),
      'expectedRevision': sdk.JsonSchema.integer(minimum: 0),
    },
    required: const <String>['taskId'],
    additionalProperties: false,
  );

  sdk.JsonObject _proposalSchema() => sdk.JsonSchema.object(
    description: 'Предложение задачи, ожидающее подтверждения человеком.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'taskId': sdk.JsonSchema.string(minLength: 1, maxLength: 80),
      'taskRef': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 256,
        format: 'uri',
      ),
      'name': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: limits.maxNameCharacters,
      ),
      'state': sdk.JsonSchema.string(enumValues: const <String>['proposed']),
      'origin': sdk.JsonSchema.string(enumValues: const <String>['agent']),
      'requiresConfirmation': sdk.JsonSchema.boolean(),
      'revision': sdk.JsonSchema.integer(minimum: 0),
      'scheduleKind': sdk.JsonSchema.string(
        enumValues: const <String>['cron', 'oneShot'],
      ),
      'cron': sdk.JsonSchema.string(minLength: 5, maxLength: 256),
      'timeZone': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
      'runAt': sdk.JsonSchema.string(format: 'date-time'),
      'nextOccurrences': sdk.JsonSchema.array(
        items: sdk.JsonSchema.string(format: 'date-time'),
        maxItems: 3,
      ),
    },
    required: const <String>[
      'schemaVersion',
      'taskId',
      'taskRef',
      'name',
      'state',
      'origin',
      'requiresConfirmation',
      'revision',
      'scheduleKind',
      'nextOccurrences',
    ],
    additionalProperties: false,
  );

  sdk.JsonObject _listOutputSchema() => sdk.JsonSchema.object(
    description: 'Задачи автоматизации со сводкой последнего запуска.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'tasks': sdk.JsonSchema.array(
        items: _taskSchema(),
        maxItems: limits.maxTasks,
      ),
      'totalCount': sdk.JsonSchema.integer(minimum: 0),
    },
    required: const <String>['schemaVersion', 'tasks', 'totalCount'],
    additionalProperties: false,
  );

  sdk.JsonObject _taskSchema() => sdk.JsonSchema.object(
    properties: <String, sdk.JsonSchema>{
      'taskId': sdk.JsonSchema.string(minLength: 1, maxLength: 80),
      'taskRef': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 256,
        format: 'uri',
      ),
      'name': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: limits.maxNameCharacters,
      ),
      'state': sdk.JsonSchema.string(
        enumValues: const <String>[
          'proposed',
          'active',
          'paused',
          'completed',
          'deleted',
        ],
      ),
      'origin': sdk.JsonSchema.string(
        enumValues: const <String>['human', 'agent'],
      ),
      'revision': sdk.JsonSchema.integer(minimum: 0),
      'scheduleKind': sdk.JsonSchema.string(
        enumValues: const <String>['cron', 'oneShot'],
      ),
      'cron': sdk.JsonSchema.string(minLength: 5, maxLength: 256),
      'timeZone': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
      'runAt': sdk.JsonSchema.string(format: 'date-time'),
      'nextDueAt': sdk.JsonSchema.string(format: 'date-time'),
      'allowedToolCount': sdk.JsonSchema.integer(minimum: 0),
      'deliveryKind': sdk.JsonSchema.string(
        enumValues: const <String>['tasks', 'chat'],
      ),
      'lastRun': sdk.JsonSchema.object(
        properties: <String, sdk.JsonSchema>{
          'runId': sdk.JsonSchema.string(minLength: 1, maxLength: 80),
          'status': sdk.JsonSchema.string(
            enumValues: const <String>[
              'running',
              'succeeded',
              'failed',
              'skipped',
              'interrupted',
            ],
          ),
          'trigger': sdk.JsonSchema.string(
            enumValues: const <String>['scheduled', 'catchUp', 'manual'],
          ),
          'scheduledAt': sdk.JsonSchema.string(format: 'date-time'),
          'finishedAt': sdk.JsonSchema.string(format: 'date-time'),
          'resultPreview': sdk.JsonSchema.string(minLength: 1, maxLength: 280),
          'errorKind': sdk.JsonSchema.string(minLength: 1, maxLength: 64),
          'errorMessage': sdk.JsonSchema.string(minLength: 1, maxLength: 280),
          'aggregatedSkippedCount': sdk.JsonSchema.integer(minimum: 1),
        },
        required: const <String>['runId', 'status', 'trigger', 'scheduledAt'],
        additionalProperties: false,
      ),
    },
    required: const <String>[
      'taskId',
      'taskRef',
      'name',
      'state',
      'origin',
      'revision',
      'scheduleKind',
      'allowedToolCount',
      'deliveryKind',
    ],
    additionalProperties: false,
  );

  sdk.JsonObject _pauseOutputSchema() => sdk.JsonSchema.object(
    description: 'Новое состояние и ревизия задачи.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'taskId': sdk.JsonSchema.string(minLength: 1, maxLength: 80),
      'state': sdk.JsonSchema.string(
        enumValues: const <String>['active', 'paused'],
      ),
      'revision': sdk.JsonSchema.integer(minimum: 0),
      'nextDueAt': sdk.JsonSchema.string(format: 'date-time'),
    },
    required: const <String>['schemaVersion', 'taskId', 'state', 'revision'],
    additionalProperties: false,
  );

  sdk.JsonObject _runNowOutputSchema() => sdk.JsonSchema.object(
    description: 'Созданный ручной запуск.',
    properties: <String, sdk.JsonSchema>{
      'schemaVersion': sdk.JsonSchema.integer(minimum: 1, maximum: 1),
      'taskId': sdk.JsonSchema.string(minLength: 1, maxLength: 80),
      'runId': sdk.JsonSchema.string(minLength: 1, maxLength: 80),
      'runRef': sdk.JsonSchema.string(
        minLength: 1,
        maxLength: 256,
        format: 'uri',
      ),
      'status': sdk.JsonSchema.string(enumValues: const <String>['running']),
      'trigger': sdk.JsonSchema.string(enumValues: const <String>['manual']),
      'scheduledAt': sdk.JsonSchema.string(format: 'date-time'),
    },
    required: const <String>[
      'schemaVersion',
      'taskId',
      'runId',
      'runRef',
      'status',
      'trigger',
      'scheduledAt',
    ],
    additionalProperties: false,
  );
}

final class _CreateRequest {
  const _CreateRequest({
    required this.name,
    required this.prompt,
    required this.schedule,
    required this.model,
    required this.allowedToolIds,
    required this.delivery,
  });

  final String name;
  final String prompt;
  final AutomationSchedule schedule;
  final ModelRef model;
  final List<String> allowedToolIds;
  final AutomationDelivery delivery;
}

final class _ListRequest {
  const _ListRequest({
    required this.state,
    required this.includeDeleted,
    required this.limit,
  });

  final AutomationTaskState? state;
  final bool includeDeleted;
  final int limit;
}

final class _PauseRequest {
  const _PauseRequest({
    required this.taskId,
    required this.paused,
    required this.expectedRevision,
  });

  final AutomationTaskId taskId;
  final bool paused;
  final int? expectedRevision;
}

final class _RunNowRequest {
  const _RunNowRequest({required this.taskId, required this.expectedRevision});

  final AutomationTaskId taskId;
  final int? expectedRevision;
}

String _clip(String value, int limit) {
  if (value.length <= limit) {
    return value;
  }
  return '${value.substring(0, limit - 1)}…';
}

String _clipText(String value, [int limit = 4000]) {
  if (value.length <= limit) {
    return value;
  }
  return '${value.substring(0, limit - 1)}…';
}

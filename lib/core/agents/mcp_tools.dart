import 'dart:async';
import 'dart:convert';

import '../llm/cancellation.dart';
import '../llm/json.dart';
import '../llm/tools.dart';
import '../mcp/catalog.dart';
import '../mcp/errors.dart';
import '../mcp/host.dart';
import '../mcp/protocol.dart';
import 'access.dart';
import 'errors.dart';
import 'tool_schema.dart';
import 'tools.dart';

/// Stable identity of one MCP tool as seen by a running agent.
///
/// Equality covers the executable contract: which connection and original tool
/// the model-facing name routes to, plus the input/output schemas used to
/// validate the call. A catalog refresh that changes any of those makes the old
/// binding invalid, so a call that was approved against the previous catalog
/// cannot execute against the new one.
final class McpAgentToolBinding {
  McpAgentToolBinding({
    required this.modelToolName,
    required this.connectionId,
    required this.originalToolName,
    required this.schemaFingerprint,
  });

  factory McpAgentToolBinding.fromRoute(McpToolRoute route) {
    return McpAgentToolBinding(
      modelToolName: route.modelToolName.value,
      connectionId: route.connectionId.value,
      originalToolName: route.originalToolName,
      schemaFingerprint: Object.hash(
        jsonHash(route.descriptor.inputSchema),
        jsonHash(route.descriptor.outputSchema),
      ),
    );
  }

  final String modelToolName;
  final String connectionId;
  final String originalToolName;
  final int schemaFingerprint;

  bool matchesRoute(McpToolRoute route) =>
      modelToolName == route.modelToolName.value &&
      connectionId == route.connectionId.value &&
      originalToolName == route.originalToolName &&
      schemaFingerprint ==
          Object.hash(
            jsonHash(route.descriptor.inputSchema),
            jsonHash(route.descriptor.outputSchema),
          );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpAgentToolBinding &&
          other.modelToolName == modelToolName &&
          other.connectionId == connectionId &&
          other.originalToolName == originalToolName &&
          other.schemaFingerprint == schemaFingerprint;

  @override
  int get hashCode => Object.hash(
    modelToolName,
    connectionId,
    originalToolName,
    schemaFingerprint,
  );

  @override
  String toString() =>
      'McpAgentToolBinding($modelToolName -> $connectionId/$originalToolName)';
}

/// Maps MCP `tools/call` payloads into agent tool results.
///
/// Text, structured, media, resource and unsupported blocks are all carried
/// into the transcript as data. `isError` always produces a failed result:
/// a server-side failure can never be mistaken for success, and any
/// `structuredContent` it returned is preserved under `details`.
///
/// The transcript is bounded even for hostile responses: text and media data
/// are capped by the remaining character budget, every identifier/label field
/// by [maxFieldCharacters], at most [maxBlockEntries] entries are emitted, and
/// all further blocks collapse into one counted `omitted` marker. Truncation
/// is always visible (`truncated`, `contentTruncated`, `*Truncated`).
final class McpToolResultMapper {
  const McpToolResultMapper({
    this.maxBlockCharacters = 60000,
    this.maxResultCharacters = 120000,
    this.maxStructuredCharacters = 120000,
    this.maxErrorSummaryCharacters = 400,
    this.maxFieldCharacters = 4096,
    this.maxBlockEntries = 64,
  });

  final int maxBlockCharacters;
  final int maxResultCharacters;
  final int maxStructuredCharacters;
  final int maxErrorSummaryCharacters;

  /// Per-string cap for `uri`, `name`, `mimeType`, `label` and similar fields.
  final int maxFieldCharacters;

  /// Maximum number of content entries emitted before the rest are counted.
  final int maxBlockEntries;

  ToolExecutionResult map(
    McpToolCallResult result, {
    required String toolName,
  }) {
    final payload = _payload(result);
    if (!result.isError) {
      return ToolExecutionResult.success(payload);
    }
    return ToolExecutionResult.failure(
      _errorSummary(result, toolName: toolName),
      details: payload,
    );
  }

  String failureMessage(McpException error, {required String toolName}) {
    final category = switch (error.error.kind) {
      McpErrorKind.toolNotFound => sanitizedMcpToolMissingMessage(),
      McpErrorKind.unavailable ||
      McpErrorKind.transport => sanitizedMcpUnavailableMessage(),
      McpErrorKind.timeout =>
        'MCP: инструмент "$toolName" не ответил за отведённое время.',
      McpErrorKind.toolDenied => 'MCP: вызов инструмента отклонён политикой.',
      McpErrorKind.toolFailure =>
        'MCP: инструмент "$toolName" завершился с ошибкой.',
      McpErrorKind.protocol ||
      McpErrorKind.invalidResponse ||
      McpErrorKind.handshake => 'MCP: сервер вернул несовместимый ответ.',
      McpErrorKind.configuration || McpErrorKind.unsupported =>
        'MCP: подключение инструмента настроено неверно.',
      McpErrorKind.nameCollision =>
        'MCP: имя инструмента конфликтует с другим сервером.',
      McpErrorKind.refresh => sanitizedMcpRefreshMessage(),
      McpErrorKind.persistence => sanitizedMcpPersistenceMessage(),
      McpErrorKind.cancelled => 'MCP: вызов инструмента "$toolName" отменён.',
    };
    final detail = sanitizeMcpText(error.error.message, fallback: '');
    if (detail.isEmpty || detail == category) {
      return category;
    }
    return '$category $detail';
  }

  String progressDetail(double fraction) {
    final safe = fraction.isFinite ? fraction.clamp(0.0, 1.0) : 0.0;
    final percent = (safe * 100).round();
    return 'MCP: $percent%';
  }

  Map<String, Object?> _payload(McpToolCallResult result) {
    final blocks = <Object?>[];
    var budget = maxResultCharacters;
    var omittedBlocks = 0;
    var truncated = false;
    for (final block in result.content) {
      if (budget <= 0 || blocks.length >= maxBlockEntries) {
        omittedBlocks += 1;
        continue;
      }
      final mapped = _block(block, budget: budget);
      budget -= _estimateSize(mapped);
      if (mapped is Map && mapped['truncated'] == true) {
        truncated = true;
      }
      blocks.add(mapped);
    }
    if (omittedBlocks > 0) {
      // Exactly one bounded marker instead of one entry per dropped block; the
      // count keeps the omission visible without letting the peer grow the
      // transcript.
      blocks.add(<String, Object?>{
        'type': 'omitted',
        'blocks': omittedBlocks,
        'reason': 'Результат превысил лимит размера.',
      });
      truncated = true;
    }
    final payload = <String, Object?>{'content': blocks};
    final structured = result.structuredContent;
    if (structured != null) {
      final encoded = jsonEncode(structured);
      if (encoded.length <= maxStructuredCharacters) {
        payload['structuredContent'] = structured;
      } else {
        payload['structuredContent'] = <String, Object?>{
          'omitted': true,
          'reason':
              'structuredContent превысил лимит $maxStructuredCharacters символов.',
          'characters': encoded.length,
        };
        truncated = true;
      }
    }
    if (result.isEmpty) {
      payload['empty'] = true;
    }
    if (truncated) {
      payload['contentTruncated'] = true;
    }
    return payload;
  }

  Object? _block(McpContentBlock block, {required int budget}) {
    final textLimit = _min(maxBlockCharacters, budget);
    final fieldLimit = _min(maxFieldCharacters, budget);
    return switch (block) {
      McpTextBlock(:final text) => _textBlock(text, textLimit),
      McpMediaBlock(:final kind, :final data, :final mimeType) =>
        <String, Object?>{
          'type': kind == McpContentKind.audio ? 'audio' : 'image',
          ..._cappedField('mimeType', mimeType, fieldLimit),
          'characters': data.length,
          if (data.length <= textLimit) 'data': data else 'dataOmitted': true,
          if (data.length > textLimit) 'truncated': true,
        },
      McpResourceLinkBlock(:final uri, :final name, :final mimeType) =>
        <String, Object?>{
          'type': 'resource_link',
          ..._cappedField('uri', uri, fieldLimit),
          if (name != null) ..._cappedField('name', name, fieldLimit),
          if (mimeType != null)
            ..._cappedField('mimeType', mimeType, fieldLimit),
        },
      McpEmbeddedResourceBlock(
        :final uri,
        :final embeddedText,
        :final data,
        :final mimeType,
      ) =>
        <String, Object?>{
          if (embeddedText != null) ..._cappedText(embeddedText, textLimit),
          'type': 'resource',
          ..._cappedField('uri', uri, fieldLimit),
          if (mimeType != null)
            ..._cappedField('mimeType', mimeType, fieldLimit),
          if (data != null) 'characters': data.length,
          if (data != null && data.length <= textLimit) 'data': data,
          if (data != null && data.length > textLimit) 'dataOmitted': true,
        },
      McpUnsupportedBlock(:final label, :final text) => <String, Object?>{
        'type': 'unsupported',
        ..._cappedField('label', label, fieldLimit),
        ..._cappedText(text, textLimit),
      },
    };
  }

  Map<String, Object?> _textBlock(String text, int limit) => <String, Object?>{
    'type': 'text',
    ..._cappedText(text, limit),
  };

  Map<String, Object?> _cappedText(String text, int limit) =>
      text.length <= limit
      ? <String, Object?>{'text': text}
      : <String, Object?>{
          'text': text.substring(0, limit),
          'truncated': true,
          'characters': text.length,
        };

  /// Caps one identifier-like field and marks the cut explicitly.
  Map<String, Object?> _cappedField(String key, String value, int limit) =>
      value.length <= limit
      ? <String, Object?>{key: value}
      : <String, Object?>{
          key: value.substring(0, limit),
          '${key}Truncated': true,
          '${key}Characters': value.length,
        };

  String _errorSummary(McpToolCallResult result, {required String toolName}) {
    for (final block in result.content) {
      if (block is McpTextBlock && block.text.trim().isNotEmpty) {
        final text = _singleLine(block.text);
        final capped = text.length <= maxErrorSummaryCharacters
            ? text
            : '${text.substring(0, maxErrorSummaryCharacters)}…';
        return 'MCP tool "$toolName" reported an error: $capped';
      }
    }
    return 'MCP tool "$toolName" reported an error. '
        '${sanitizedMcpToolFailureMessage()}';
  }

  static String _singleLine(String value) => value
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static int _min(int left, int right) => left < right ? left : right;

  static int _estimateSize(Object? value) =>
      value == null ? 0 : jsonEncode(value).length;
}

/// Dynamic [AgentToolSource] that mirrors one [McpHost] catalog.
///
/// The source rebuilds its view atomically from the host snapshot: a refresh
/// that adds tools publishes new entries, a removed tool disappears, and a
/// tool whose schema the provider cannot represent is published as
/// unavailable with a visible reason instead of a broadened schema. A running
/// agent turn keeps the view it started with until it settles; the runtime
/// re-checks the live binding before every call.
final class McpAgentToolSource implements AgentToolSource {
  McpAgentToolSource({
    required McpHost host,
    ToolSchemaProfile? profile,
    this.callTimeout,
    McpToolResultMapper mapper = const McpToolResultMapper(),
    this.maxDescriptionCharacters = 2048,
  }) : _host = host,
       profile = profile ?? ToolSchemaProfile.openaiChatCompletions,
       _mapper = mapper {
    _subscription = host.events.listen((_) => _rebuild());
    _rebuild();
  }

  static const sourceIdValue = 'mcp';

  final McpHost _host;
  final ToolSchemaProfile profile;
  final McpToolResultMapper _mapper;

  /// Per-call deadline handed to the host; `null` uses the host default.
  final Duration? callTimeout;

  final int maxDescriptionCharacters;

  final List<void Function()> _listeners = <void Function()>[];
  StreamSubscription<McpHostEvent>? _subscription;
  var _disposed = false;
  AgentToolSourceView _view = AgentToolSourceView.empty;
  String _signature = '';

  McpHost get host => _host;

  @override
  String get sourceId => sourceIdValue;

  @override
  AgentToolSourceView get view => _view;

  /// Current per-name reasons for tools that cannot be offered.
  Map<String, String> get unavailableTools => _view.unavailable;

  @override
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _listeners.clear();
  }

  void _rebuild() {
    if (_disposed) {
      return;
    }
    final catalog = _host.snapshot.catalog;
    final signature = _catalogSignature(catalog);
    if (signature == _signature) {
      return;
    }
    _signature = signature;
    final tools = <String, AgentTool>{};
    final unavailable = <String, String>{};
    for (final route in catalog.routes) {
      final reason = _availabilityReason(route.descriptor);
      // A known-but-unavailable tool stays registered so enabling it is a
      // visible, call-free denial instead of a phantom "not registered";
      // it is never advertised to the model.
      tools[route.modelToolName.value] = _toolFor(
        route,
        unavailableReason: reason,
      );
      if (reason != null) {
        unavailable[route.modelToolName.value] = reason;
      }
    }
    _view = AgentToolSourceView(tools: tools, unavailable: unavailable);
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  String? _availabilityReason(McpToolDescriptor descriptor) {
    final input = representToolSchema(descriptor.inputSchema, profile: profile);
    if (!input.isRepresented) {
      return input.reason;
    }
    if (!_inputSchemaAcceptsObject(descriptor.inputSchema)) {
      return 'JSON Schema root must describe an object; this tool cannot be '
          'called with an argument object.';
    }
    final output = descriptor.outputSchema;
    if (output != null) {
      final problem = toolSchemaProblem(output, profile: profile);
      if (problem != null) {
        return 'JSON Schema for this tool cannot be validated faithfully: '
            '$problem';
      }
    }
    return null;
  }

  bool _inputSchemaAcceptsObject(Map<String, Object?> schema) {
    final type = schema['type'];
    if (type == null) {
      return true;
    }
    if (type == 'object') {
      return true;
    }
    if (type is List) {
      return type.contains('object');
    }
    return false;
  }

  AgentTool _toolFor(McpToolRoute route, {String? unavailableReason}) {
    final descriptor = route.descriptor;
    final name = route.modelToolName.value;
    final description = _description(route);
    final binding = McpAgentToolBinding.fromRoute(route);
    return AgentTool(
      descriptor: LlmToolDescriptor(
        name: name,
        description: description,
        parameters: copyJsonMap(descriptor.inputSchema),
      ),
      binding: binding,
      unavailableReason: unavailableReason,
      argumentValidator: (arguments) {
        final problem = firstToolSchemaValueProblem(
          descriptor.inputSchema,
          arguments,
        );
        if (problem != null) {
          throwAgent(AgentErrorKind.configuration, problem);
        }
      },
      descriptorProjector: (target) {
        final representation = representToolSchema(
          descriptor.inputSchema,
          profile: target,
        );
        if (!representation.isRepresented) {
          return UnavailableToolDescriptor(representation.reason!);
        }
        return AvailableToolDescriptor(
          LlmToolDescriptor(
            name: name,
            description: description,
            parameters: representation.schema,
          ),
        );
      },
      executor: _McpAgentToolExecutor(
        host: _host,
        binding: binding,
        mapper: _mapper,
        callTimeout: callTimeout,
      ),
    );
  }

  String _description(McpToolRoute route) {
    final buffer = StringBuffer('[MCP: ${route.connectionId.value}]');
    final raw = route.descriptor.description ?? route.descriptor.title;
    if (raw != null) {
      final sanitized = raw
          .replaceAll(
            RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'),
            ' ',
          )
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
      if (sanitized.isNotEmpty) {
        buffer.write(' ');
        buffer.write(
          sanitized.length <= maxDescriptionCharacters
              ? sanitized
              : '${sanitized.substring(0, maxDescriptionCharacters)}…',
        );
      }
    }
    return buffer.toString();
  }

  String _catalogSignature(McpCatalog catalog) => catalog.routes
      .map(
        (route) =>
            '${route.connectionId.value}\u0000${route.originalToolName}\u0000'
            '${route.modelToolName.value}\u0000'
            '${route.descriptor.title ?? ''}\u0000'
            '${route.descriptor.description ?? ''}\u0000'
            '${jsonHash(route.descriptor.inputSchema)}\u0000'
            '${jsonHash(route.descriptor.outputSchema)}',
      )
      .join('|');
}

final class _McpAgentToolExecutor implements AgentToolExecutor {
  _McpAgentToolExecutor({
    required this.host,
    required this.binding,
    required this.mapper,
    this.callTimeout,
  });

  final McpHost host;
  final McpAgentToolBinding binding;
  final McpToolResultMapper mapper;
  final Duration? callTimeout;

  @override
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  }) async {
    final route = host.snapshot.catalog.lookup(binding.modelToolName);
    if (route == null) {
      return ToolExecutionResult.failure(sanitizedMcpToolMissingMessage());
    }
    if (!binding.matchesRoute(route)) {
      return ToolExecutionResult.failure(
        'MCP: маршрут инструмента "${binding.modelToolName}" изменился '
        'с момента подтверждения вызова.',
      );
    }
    try {
      final result = await host.callTool(
        modelToolName: binding.modelToolName,
        arguments: invocation.arguments,
        timeout: callTimeout,
        cancellation: cancellation,
        onProgress: (fraction) =>
            liveness.reportProgress(detail: mapper.progressDetail(fraction)),
      );
      final mapped = mapper.map(result, toolName: binding.modelToolName);
      final outputProblem = _outputProblem(
        result,
        route.descriptor.outputSchema,
      );
      if (outputProblem != null) {
        return ToolExecutionResult.failure(
          outputProblem,
          details: mapped.success ? mapped.output : mapped.errorDetails,
        );
      }
      return mapped;
    } on McpException catch (error) {
      if (error.error.kind == McpErrorKind.cancelled ||
          cancellation.isCancelled) {
        throw AgentException(
          AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
        );
      }
      return ToolExecutionResult.failure(
        mapper.failureMessage(error, toolName: binding.modelToolName),
      );
    }
  }

  /// Validates declared `structuredContent` against the tool's `outputSchema`.
  ///
  /// MCP 2025-11-25 says a server that declares an output schema MUST return
  /// structured content conforming to it, so a *successful* result without
  /// `structuredContent` is a visible failure: the text stays available as
  /// error details, but the call is never reported as a success. Error results
  /// keep their own failure and are not required to carry structured content.
  String? _outputProblem(
    McpToolCallResult result,
    Map<String, Object?>? outputSchema,
  ) {
    if (outputSchema == null) {
      return null;
    }
    final structured = result.structuredContent;
    if (structured == null) {
      if (result.isError) {
        return null;
      }
      return 'MCP: инструмент "${binding.modelToolName}" объявил outputSchema, '
          'но вернул успешный результат без structuredContent. '
          'Результат не подтверждён схемой.';
    }
    final problem = firstToolSchemaValueProblem(outputSchema, structured);
    if (problem == null) {
      return null;
    }
    return 'MCP: structuredContent инструмента "${binding.modelToolName}" '
        'не соответствует объявленной outputSchema: $problem';
  }
}

/// Production-ready bridge between one [McpHost] and the agent layer.
///
/// B9 composes it once and hands it to the runtime:
///
/// ```dart
/// final bridge = McpAgentToolBridge(host: mcpHost);
/// bridge.attachTo(tools);            // dynamic MCP tools join read/write/edit/bash
/// policies['chat-42'] = bridge.grantFor(allowedToolIds: chatSelection);
/// ```
///
/// Rights never widen on their own: [grantFor] snapshots the current catalog
/// only when the UI asks for it, and the runtime re-checks the live route and
/// policy immediately before every call.
final class McpAgentToolBridge {
  McpAgentToolBridge({
    required McpHost host,
    ToolSchemaProfile? profile,
    Duration? callTimeout,
    McpToolResultMapper mapper = const McpToolResultMapper(),
    int maxDescriptionCharacters = 2048,
  }) : source = McpAgentToolSource(
         host: host,
         profile: profile,
         callTimeout: callTimeout,
         mapper: mapper,
         maxDescriptionCharacters: maxDescriptionCharacters,
       );

  final McpAgentToolSource source;

  McpHost get host => source.host;

  void attachTo(AgentToolRegistry registry) => registry.attachSource(source);

  void detachFrom(AgentToolRegistry registry) =>
      registry.detachSource(source.sourceId);

  /// Builds an explicit grant for one chat/project/task from the live catalog.
  ///
  /// Only [allowedToolIds] receive access; destructive server annotations can
  /// add an approval requirement but never remove the explicit denial. With
  /// [interactiveApproval] disabled (or [ToolAccessScope.scheduledTask]) the
  /// grant additionally denies [ScheduledToolRestrictions.intrinsicDeniedToolIds],
  /// so a scheduled run cannot create new schedules even without a caller
  /// deny list.
  ToolAccessGrant grantFor({
    required Iterable<String> allowedToolIds,
    Iterable<String> deniedToolIds = const <String>[],
    bool askOnDestructive = true,
    bool interactiveApproval = true,
    ToolAccessScope scope = ToolAccessScope.chat,
  }) {
    return ToolAccessGrant.forMcpCatalog(
      catalog: host.snapshot.catalog,
      allowedToolIds: allowedToolIds,
      deniedToolIds: deniedToolIds,
      askOnDestructive: askOnDestructive,
      interactiveApproval: interactiveApproval,
      scope: scope,
    );
  }

  void dispose() => source.dispose();
}

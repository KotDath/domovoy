import 'dart:convert';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import 'chat_workspace_state.dart';

enum ChatToolStatus {
  assembled,
  awaitingPermission,
  running,
  succeeded,
  failed,
}

enum ChatCompactionStatus { running, succeeded, unchanged, failed, cancelled }

enum ChatTimelineErrorKind { failed, cancelled, interrupted, unsupported }

sealed class ChatTimelineItem {
  const ChatTimelineItem({required this.key});

  final String key;
}

final class ChatUserItem extends ChatTimelineItem {
  const ChatUserItem({required super.key, required this.text});

  final String text;
}

final class ChatAssistantItem extends ChatTimelineItem {
  const ChatAssistantItem({
    required super.key,
    required this.text,
    this.isPartial = false,
  });

  final String text;
  final bool isPartial;
}

final class ChatReasoningItem extends ChatTimelineItem {
  const ChatReasoningItem({
    required super.key,
    required this.text,
    required this.responseKey,
    this.isPartial = false,
  });

  final String text;
  final String responseKey;
  final bool isPartial;
}

final class ChatToolItem extends ChatTimelineItem {
  const ChatToolItem({
    required super.key,
    required this.callId,
    required this.name,
    required this.arguments,
    required this.displayArguments,
    required this.status,
    this.progress,
    this.result,
    this.displayResult,
  });

  final ToolCallId callId;
  final String name;
  final String arguments;
  final String displayArguments;
  final ChatToolStatus status;
  final String? progress;
  final String? result;
  final String? displayResult;
}

final class ChatCompactionItem extends ChatTimelineItem {
  const ChatCompactionItem({
    required super.key,
    required this.status,
    required this.reasonLabel,
    required this.strategyLabel,
    required this.beforeEstimate,
    this.afterEstimate,
    this.targetEstimate,
    this.generation,
  });

  final ChatCompactionStatus status;
  final String reasonLabel;
  final String strategyLabel;
  final int beforeEstimate;
  final int? afterEstimate;
  final int? targetEstimate;
  final int? generation;
}

final class ChatErrorItem extends ChatTimelineItem {
  const ChatErrorItem({
    required super.key,
    required this.kind,
    required this.message,
    this.modelLabel,
    this.offersSettings = false,
  });

  final ChatTimelineErrorKind kind;
  final String message;
  final String? modelLabel;
  final bool offersSettings;
}

final class ChatUnsupportedPartItem extends ChatTimelineItem {
  const ChatUnsupportedPartItem({required super.key, required this.label});

  final String label;
}

final class ChatTimelineProjection {
  ChatTimelineProjection(List<ChatTimelineItem> items)
    : items = List<ChatTimelineItem>.unmodifiable(items);

  final List<ChatTimelineItem> items;
}

/// Pure, identity-based projection of acknowledged and live chat state.
final class ChatTimelineProjector {
  const ChatTimelineProjector();

  ChatTimelineProjection project({
    required AgentSessionSnapshot snapshot,
    ChatLiveRunState? liveRun,
    List<AgentCompactionEvent> operationCompactions =
        const <AgentCompactionEvent>[],
    ChatWorkspaceError? workspaceError,
  }) {
    final transcript = snapshot.transcript;
    final live = liveRun == null ? null : _LiveProjection.reduce(liveRun);
    final results = <ToolCallId, LlmToolResultPart>{};
    final resultMessageIndexes = <ToolCallId, int>{};
    for (
      var messageIndex = 0;
      messageIndex < transcript.messages.length;
      messageIndex += 1
    ) {
      for (final part in transcript.messages[messageIndex].parts) {
        if (part is LlmToolResultPart) {
          results[part.callId] = part;
          resultMessageIndexes[part.callId] = messageIndex;
        }
      }
    }

    final items = <ChatTimelineItem>[];
    final persistedCalls = <ToolCallId>{};
    final consumedResults = <ToolCallId>{};
    final matchedResponses = <int>{};

    for (
      var messageIndex = 0;
      messageIndex < transcript.messages.length;
      messageIndex += 1
    ) {
      final message = transcript.messages[messageIndex];
      final messageKey = _messageKey(snapshot, messageIndex);
      switch (message.role) {
        case LlmMessageRole.user:
          final text = message.parts
              .whereType<LlmTextPart>()
              .map((part) => part.text)
              .join();
          items.add(ChatUserItem(key: '$messageKey:user', text: text));
        case LlmMessageRole.assistant:
          final responseKey = '$messageKey:assistant';
          final matchingLive = live?._match(message, matchedResponses);
          if (matchingLive != null) matchedResponses.add(matchingLive.ordinal);
          for (
            var partIndex = 0;
            partIndex < message.parts.length;
            partIndex += 1
          ) {
            final part = message.parts[partIndex];
            if (part is LlmToolCallPart) {
              persistedCalls.add(part.callId);
              final result = results[part.callId];
              if (result != null) consumedResults.add(part.callId);
              items.add(
                _toolItem(
                  snapshot.id,
                  part,
                  result: result,
                  live: live?.tools[part.callId],
                ),
              );
            } else {
              items.add(
                projectContentPart(
                  part: part,
                  key: '$messageKey:part:$partIndex',
                  responseKey: responseKey,
                ),
              );
            }
          }
        case LlmMessageRole.tool:
          // Correlated results are rendered inside their tool call card. Any
          // orphan is projected once by the explicit fallback below.
          break;
      }
    }

    final persistedCompaction = snapshot.compactionState;
    if (persistedCompaction != null) {
      items.add(
        ChatCompactionItem(
          key:
              'session:${snapshot.id.value}:compaction:'
              '${persistedCompaction.generation}',
          status: ChatCompactionStatus.succeeded,
          reasonLabel: _reasonLabel(persistedCompaction.reason),
          strategyLabel: persistedCompaction.strategyId,
          beforeEstimate: persistedCompaction.beforeEstimate,
          afterEstimate: persistedCompaction.afterEstimate,
          generation: persistedCompaction.generation,
        ),
      );
    }

    if (live != null) {
      for (final response in live.responses) {
        if (matchedResponses.contains(response.ordinal)) continue;
        final responseKey = _liveResponseKey(
          snapshot.id,
          liveRun!.runId,
          response.ordinal,
        );
        if (response.reasoning.isNotEmpty) {
          items.add(
            ChatReasoningItem(
              key: '$responseKey:reasoning',
              responseKey: responseKey,
              text: response.reasoning,
              isPartial: !response.isPersistedBoundary,
            ),
          );
        }
        if (response.answer.isNotEmpty) {
          items.add(
            ChatAssistantItem(
              key: '$responseKey:answer',
              text: response.answer,
              isPartial: !response.isPersistedBoundary,
            ),
          );
        }
        for (final call in response.calls) {
          if (persistedCalls.contains(call.callId)) continue;
          items.add(
            _toolItem(
              snapshot.id,
              call,
              result: results[call.callId],
              live: live.tools[call.callId],
            ),
          );
        }
      }
      for (final tool in live.tools.values) {
        if (persistedCalls.contains(tool.callId) ||
            live.responses.any(
              (response) =>
                  response.calls.any((call) => call.callId == tool.callId),
            )) {
          continue;
        }
        final result = results[tool.callId];
        items.add(
          ChatToolItem(
            key: _toolKey(snapshot.id, tool.callId),
            callId: tool.callId,
            name: tool.name ?? 'Инструмент',
            arguments: '',
            displayArguments: '',
            status: tool.status,
            progress: tool.progress,
            result: result?.content,
            displayResult: result == null
                ? null
                : formatToolContent(result.content),
          ),
        );
      }
      final terminalItem = _terminalItem(snapshot.id, liveRun!);
      if (terminalItem != null) items.add(terminalItem);
    }

    final liveCompactions = <ChatCompactionItem>[
      if (live != null) ...live.compactions,
      ..._reduceCompactions(operationCompactions),
    ];
    for (final item in liveCompactions) {
      final replacedByPersisted =
          persistedCompaction != null &&
          item.status == ChatCompactionStatus.succeeded &&
          item.generation == persistedCompaction.generation;
      if (!replacedByPersisted) items.add(item);
    }

    if (workspaceError != null && live?.hasFailure != true) {
      items.add(
        ChatErrorItem(
          key: 'session:${snapshot.id.value}:workspace-error',
          kind: ChatTimelineErrorKind.failed,
          message: workspaceError.message,
          offersSettings: workspaceError.kind == AgentErrorKind.configuration,
        ),
      );
    }

    // A result without its call is retained as an explicit safe fallback.
    for (final entry in results.entries) {
      if (consumedResults.contains(entry.key)) continue;
      final messageIndex = resultMessageIndexes[entry.key]!;
      items.add(
        ChatUnsupportedPartItem(
          key:
              '${_messageKey(snapshot, messageIndex)}:orphan:${entry.key.value}',
          label: 'Результат неизвестного вызова инструмента',
        ),
      );
    }
    return ChatTimelineProjection(items);
  }

  ChatTimelineItem projectContentPart({
    required Object part,
    required String key,
    required String responseKey,
  }) {
    if (part is LlmTextPart) {
      return ChatAssistantItem(key: key, text: part.text);
    }
    if (part is LlmReasoningPart) {
      return ChatReasoningItem(
        key: key,
        responseKey: responseKey,
        text: part.text,
      );
    }
    return ChatUnsupportedPartItem(
      key: key,
      label: 'Неподдерживаемая часть ответа',
    );
  }
}

ChatToolItem _toolItem(
  AgentSessionId sessionId,
  LlmToolCallPart call, {
  LlmToolResultPart? result,
  _LiveTool? live,
}) {
  final status =
      live?.status ??
      (result == null
          ? ChatToolStatus.assembled
          : _resultLooksFailed(result.content)
          ? ChatToolStatus.failed
          : ChatToolStatus.succeeded);
  return ChatToolItem(
    key: _toolKey(sessionId, call.callId),
    callId: call.callId,
    name: call.name,
    arguments: call.arguments,
    displayArguments: formatToolContent(call.arguments),
    status: status,
    progress: live?.progress,
    result: result?.content,
    displayResult: result == null ? null : formatToolContent(result.content),
  );
}

String formatToolContent(String value) {
  try {
    final decoded = jsonDecode(value);
    return const JsonEncoder.withIndent('  ').convert(decoded);
  } on FormatException {
    return value;
  }
}

bool _resultLooksFailed(String value) {
  try {
    final decoded = jsonDecode(value);
    return decoded is Map && decoded.containsKey('error');
  } on FormatException {
    return false;
  }
}

String _messageKey(AgentSessionSnapshot snapshot, int index) {
  final identity = snapshot.transcript.messageIds[index];
  return 'session:${snapshot.id.value}:message:${identity?.value ?? 'legacy-$index'}';
}

String _liveResponseKey(AgentSessionId sessionId, RunId runId, int ordinal) =>
    'session:${sessionId.value}:run:${runId.value}:response:$ordinal';

String _toolKey(AgentSessionId sessionId, ToolCallId callId) =>
    'session:${sessionId.value}:tool:${callId.value}';

String _reasonLabel(AgentCompactionReason reason) => switch (reason) {
  AgentCompactionReason.preRequest => 'Подготовка контекста',
  AgentCompactionReason.providerOverflow => 'Переполнение контекста',
  AgentCompactionReason.modelSwitch => 'Подготовка к смене модели',
  AgentCompactionReason.manual => 'Ручное сжатие',
};

ChatErrorItem? _terminalItem(
  AgentSessionId sessionId,
  ChatLiveRunState liveRun,
) {
  final terminal = liveRun.terminal;
  if (terminal is AgentRunFailed) {
    return ChatErrorItem(
      key: 'session:${sessionId.value}:run:${liveRun.runId.value}:terminal',
      kind: ChatTimelineErrorKind.failed,
      message:
          terminal.error.kind == AgentErrorKind.provider &&
              terminal.error.safeProviderMessage
          ? terminal.error.message
          : _sanitizedRunFailure(terminal.error.kind),
      modelLabel: liveRun.model?.toString(),
      offersSettings: terminal.error.kind == AgentErrorKind.configuration,
    );
  }
  if (terminal is AgentRunCancelled) {
    return ChatErrorItem(
      key: 'session:${sessionId.value}:run:${liveRun.runId.value}:terminal',
      kind: ChatTimelineErrorKind.cancelled,
      message: 'Ответ остановлен. Полученная часть сохранена на экране.',
    );
  }
  if (terminal is AgentRunStopped) {
    return ChatErrorItem(
      key: 'session:${sessionId.value}:run:${liveRun.runId.value}:terminal',
      kind: ChatTimelineErrorKind.interrupted,
      message: 'Ответ прерван ограничением выполнения.',
    );
  }
  return null;
}

String _sanitizedRunFailure(AgentErrorKind kind) => switch (kind) {
  AgentErrorKind.configuration =>
    'Не удалось начать ответ. Проверьте модель и настройки.',
  AgentErrorKind.persistence ||
  AgentErrorKind.conflict => 'Не удалось подтвердить состояние чата.',
  AgentErrorKind.cancelled => 'Ответ остановлен.',
  AgentErrorKind.compaction || AgentErrorKind.budgetUnverifiable =>
    'Не удалось безопасно подготовить контекст.',
  AgentErrorKind.provider ||
  AgentErrorKind.protocol => 'Провайдер не смог завершить ответ.',
  AgentErrorKind.busy => 'Чат занят другой операцией.',
  AgentErrorKind.runtime ||
  AgentErrorKind.unknown => 'Ответ завершился внутренней ошибкой.',
};

final class _LiveResponse {
  _LiveResponse(this.ordinal);

  final int ordinal;
  final StringBuffer reasoningBuffer = StringBuffer();
  final StringBuffer answerBuffer = StringBuffer();
  final List<LlmToolCallPart> calls = <LlmToolCallPart>[];
  bool isPersistedBoundary = false;

  String get reasoning => reasoningBuffer.toString();
  String get answer => answerBuffer.toString();
}

final class _LiveTool {
  _LiveTool(this.callId);

  final ToolCallId callId;
  String? name;
  String? progress;
  ChatToolStatus status = ChatToolStatus.assembled;
}

final class _LiveProjection {
  _LiveProjection({
    required this.responses,
    required this.tools,
    required this.compactions,
    required this.hasFailure,
  });

  factory _LiveProjection.reduce(ChatLiveRunState liveRun) {
    final responses = <_LiveResponse>[_LiveResponse(0)];
    final tools = <ToolCallId, _LiveTool>{};
    final compactions = <String, ChatCompactionItem>{};
    var current = responses.first;
    var hasFailure = false;
    for (final entry in liveRun.events) {
      final event = entry.event;
      if ((event is AgentReasoningDelta || event is AgentAnswerDelta) &&
          current.isPersistedBoundary) {
        current = _LiveResponse(responses.length);
        responses.add(current);
      }
      switch (event) {
        case AgentReasoningDelta(:final text):
          current.reasoningBuffer.write(text);
        case AgentAnswerDelta(:final text):
          current.answerBuffer.write(text);
        case AgentToolAssembled(:final calls):
          current.calls.addAll(calls);
          current.isPersistedBoundary = true;
          for (final call in calls) {
            final tool = tools.putIfAbsent(
              call.callId,
              () => _LiveTool(call.callId),
            );
            tool.name = call.name;
          }
        case AgentPermissionDecision(:final callId):
          tools.putIfAbsent(callId, () => _LiveTool(callId)).status =
              ChatToolStatus.awaitingPermission;
        case AgentToolStarted(:final callId, :final name):
          final tool = tools.putIfAbsent(callId, () => _LiveTool(callId));
          tool.name = name;
          tool.status = ChatToolStatus.running;
        case AgentToolProgress(:final callId, :final detail):
          tools.putIfAbsent(callId, () => _LiveTool(callId)).progress = detail;
        case AgentToolFinished(:final callId, :final success):
          tools.putIfAbsent(callId, () => _LiveTool(callId)).status = success
              ? ChatToolStatus.succeeded
              : ChatToolStatus.failed;
        case AgentAutomaticCompactionEvent(:final compaction):
          compactions[compaction.operationId.value] = _compactionItem(
            compaction,
          );
        case AgentRunFailed():
          hasFailure = true;
        default:
          break;
      }
    }
    return _LiveProjection(
      responses: responses,
      tools: tools,
      compactions: compactions.values.toList(growable: false),
      hasFailure: hasFailure,
    );
  }

  final List<_LiveResponse> responses;
  final Map<ToolCallId, _LiveTool> tools;
  final List<ChatCompactionItem> compactions;
  final bool hasFailure;

  _LiveResponse? _match(LlmMessage message, Set<int> used) {
    for (final response in responses) {
      if (used.contains(response.ordinal)) continue;
      final reasoning = message.parts
          .whereType<LlmReasoningPart>()
          .map((part) => part.text)
          .join();
      final answer = message.parts
          .whereType<LlmTextPart>()
          .map((part) => part.text)
          .join();
      final calls = message.parts.whereType<LlmToolCallPart>().toList();
      if (reasoning == response.reasoning &&
          answer == response.answer &&
          calls.length == response.calls.length &&
          calls.every(
            (call) => response.calls.any(
              (liveCall) => liveCall.callId == call.callId,
            ),
          ) &&
          (reasoning.isNotEmpty || answer.isNotEmpty || calls.isNotEmpty)) {
        return response;
      }
    }
    return null;
  }
}

ChatCompactionItem _compactionItem(AgentCompactionEvent event) {
  final status = switch (event) {
    AgentCompactionStarted() => ChatCompactionStatus.running,
    AgentCompactionSucceeded() => ChatCompactionStatus.succeeded,
    AgentCompactionNoChangeEvent() => ChatCompactionStatus.unchanged,
    AgentCompactionFailed() => ChatCompactionStatus.failed,
    AgentCompactionCancelled() => ChatCompactionStatus.cancelled,
  };
  return ChatCompactionItem(
    key:
        'session:${event.sessionId.value}:compaction:'
        '${event.operationId.value}',
    status: status,
    reasonLabel: _reasonLabel(event.reason),
    strategyLabel: event.strategyId,
    beforeEstimate: event.beforeEstimate,
    afterEstimate: event is AgentCompactionSucceeded
        ? event.afterEstimate
        : null,
    targetEstimate: event.targetEstimate,
    generation: event is AgentCompactionSucceeded ? event.generation : null,
  );
}

List<ChatCompactionItem> _reduceCompactions(List<AgentCompactionEvent> events) {
  final byOperation = <String, ChatCompactionItem>{};
  for (final event in events) {
    byOperation[event.operationId.value] = _compactionItem(event);
  }
  return byOperation.values.toList(growable: false);
}

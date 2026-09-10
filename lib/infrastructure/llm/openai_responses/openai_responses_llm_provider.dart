import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/llm/cancellation.dart';
import '../../../core/llm/capabilities.dart';
import '../../../core/llm/catalog.dart';
import '../../../core/llm/continuation.dart';
import '../../../core/llm/credentials.dart';
import '../../../core/llm/errors.dart';
import '../../../core/llm/events.dart';
import '../../../core/llm/generation.dart';
import '../../../core/llm/identifiers.dart';
import '../../../core/llm/json.dart';
import '../../../core/llm/messages.dart';
import '../../../core/llm/provider.dart';
import '../../../core/llm/request.dart';
import '../../../core/llm/tools.dart';
import '../../../core/llm/usage.dart';
import '../openai_compatible/sse_decoder.dart';
import '../openai_compatible/stream_session.dart';
import 'openai_responses_profile.dart';

final class OpenAiResponsesLlmProvider implements LlmProvider {
  OpenAiResponsesLlmProvider({
    required this.profile,
    required http.Client client,
    required ProviderCredentialResolver credentials,
  }) : _client = client,
       _credentials = credentials;

  final OpenAiResponsesProfile profile;
  final http.Client _client;
  final ProviderCredentialResolver _credentials;

  @override
  ProviderId get id => profile.id;

  @override
  LlmWireFamily get wireFamily => LlmWireFamily.openaiResponses;

  Map<String, Object?> requestBody(LlmRequest request) {
    final model = profile.requireModel(request.model.modelId);
    validateRequestAgainstModel(request, model);
    if (request.model.providerId != id) {
      throwLlm(
        LlmErrorKind.configuration,
        'Request provider ${request.model.providerId.value} does not match ${id.value}.',
      );
    }
    return buildResponsesBody(request: request, model: model);
  }

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) {
    final model = profile.requireModel(request.model.modelId);
    validateRequestAgainstModel(request, model);
    if (request.model.providerId != id) {
      throwLlm(
        LlmErrorKind.configuration,
        'Request provider ${request.model.providerId.value} does not match ${id.value}.',
      );
    }
    final body = buildResponsesBody(request: request, model: model);
    final session = _ResponsesParseState(
      model: model,
      generation: request.generation,
    );
    return runLlmHttpStream(
      providerId: id,
      endpoint: profile.snapshot.endpoint,
      body: body,
      client: _client,
      credentials: _credentials,
      environmentVariable: profile.snapshot.environmentVariable,
      cancellation: cancellation,
      consume: (response, sink, token) {
        return consumeSse(
          response: response,
          sink: sink,
          cancellation: token,
          onMessage: (message, eventSink) async {
            session.handle(message, eventSink, id);
          },
        );
      },
    );
  }
}

Map<String, Object?> buildResponsesBody({
  required LlmRequest request,
  required LlmModel model,
}) {
  final body = <String, Object?>{
    'model': model.id.value,
    'input': encodeResponsesInput(request),
    'stream': true,
    'store': false,
  };
  if (request.context.systemPrompt != null) {
    body['instructions'] = request.context.systemPrompt;
  }
  if (request.context.tools.isNotEmpty) {
    body['tools'] = request.context.tools.map(encodeResponsesTool).toList();
  }
  applyResponsesReasoning(body, model: model, generation: request.generation);
  if (request.generation.temperature != null) {
    body['temperature'] = request.generation.temperature;
  }
  if (request.generation.maxOutputTokens != null) {
    body['max_output_tokens'] = request.generation.maxOutputTokens;
  }
  return body;
}

void applyResponsesReasoning(
  Map<String, Object?> body, {
  required LlmModel model,
  required LlmGenerationConfig generation,
}) {
  final capability = model.capabilities.reasoning;
  if (capability == ModelReasoningCapability.unsupported) {
    return;
  }
  body['include'] = const <String>['reasoning.encrypted_content'];
  if (model.id == BuiltInLlmCatalog.gpt54) {
    if (generation.reasoningMode == ReasoningMode.disabled) {
      body['reasoning'] = const <String, String>{'effort': 'none'};
      return;
    }
    body['reasoning'] = <String, String>{
      'effort': switch (generation.reasoningEffort) {
        ReasoningEffort.low => 'low',
        ReasoningEffort.medium => 'medium',
        ReasoningEffort.high => 'high',
        ReasoningEffort.max => 'xhigh',
        ReasoningEffort.modelDefault => 'high',
      },
    };
    return;
  }
  if (generation.reasoningMode == ReasoningMode.disabled) {
    throwLlm(
      LlmErrorKind.configuration,
      'Model ${model.id.value} cannot disable reasoning.',
    );
  }
  body['reasoning'] = <String, String>{
    'effort': switch (generation.reasoningEffort) {
      ReasoningEffort.low => 'low',
      ReasoningEffort.medium => 'medium',
      ReasoningEffort.high => 'high',
      ReasoningEffort.modelDefault => 'high',
      ReasoningEffort.max => throwLlm(
        LlmErrorKind.configuration,
        'Model ${model.id.value} does not accept reasoning effort "max".',
      ),
    },
  };
}

List<Map<String, Object?>> encodeResponsesInput(LlmRequest request) {
  final replayed = <int>{};
  if (request.generation.reasoningMode == ReasoningMode.enabled) {
    for (final entry in request.context.continuationEntries) {
      replayed.add(entry.assistantMessageIndex);
    }
  }
  final items = <Map<String, Object?>>[];
  final messages = request.context.messages;
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    switch (message.role) {
      case LlmMessageRole.user:
        items.add(<String, Object?>{
          'role': 'user',
          'content': <Map<String, Object?>>[
            <String, Object?>{
              'type': 'input_text',
              'text': message.parts
                  .whereType<LlmTextPart>()
                  .map((part) => part.text)
                  .join(),
            },
          ],
        });
      case LlmMessageRole.assistant:
        if (replayed.contains(index)) {
          final entry = request.context.continuationEntries.firstWhere(
            (value) => value.assistantMessageIndex == index,
          );
          final payload = entry.state.payload;
          if (payload is! List) {
            throwLlm(
              LlmErrorKind.configuration,
              'Continuation payload must be a list of output items.',
            );
          }
          for (final item in payload) {
            final map = asJsonObject(item);
            if (map == null) {
              throwLlm(
                LlmErrorKind.configuration,
                'Continuation output items must be objects.',
              );
            }
            items.add(Map<String, Object?>.from(map));
          }
          continue;
        }
        final textBuffer = StringBuffer();
        final toolCalls = <LlmToolCallPart>[];
        for (final part in message.parts) {
          switch (part) {
            case LlmTextPart(:final text):
              textBuffer.write(text);
            case LlmReasoningPart():
              break;
            case LlmToolCallPart():
              toolCalls.add(part);
            case LlmToolResultPart():
              throwLlm(
                LlmErrorKind.configuration,
                'Assistant messages cannot contain tool results.',
              );
          }
        }
        if (textBuffer.isNotEmpty) {
          items.add(<String, Object?>{
            'role': 'assistant',
            'content': <Map<String, Object?>>[
              <String, Object?>{
                'type': 'output_text',
                'text': textBuffer.toString(),
              },
            ],
          });
        }
        for (final call in toolCalls) {
          items.add(<String, Object?>{
            'type': 'function_call',
            'call_id': call.callId.value,
            'name': call.name,
            'arguments': call.arguments,
          });
        }
      case LlmMessageRole.tool:
        for (final part in message.parts.whereType<LlmToolResultPart>()) {
          items.add(<String, Object?>{
            'type': 'function_call_output',
            'call_id': part.callId.value,
            'output': part.content,
          });
        }
    }
  }
  return items;
}

Map<String, Object?> encodeResponsesTool(LlmToolDescriptor tool) {
  final encoded = <String, Object?>{
    'type': 'function',
    'name': tool.name,
    'parameters': jsonDecode(jsonEncode(tool.parameters)),
  };
  if (tool.description != null) {
    encoded['description'] = tool.description;
  }
  return encoded;
}

final class _FunctionCallRef {
  _FunctionCallRef({
    required this.callId,
    required this.index,
    this.name = '',
    this.arguments = '',
  });

  final ToolCallId callId;
  final int index;
  String name;
  String arguments;
}

final class _ResponsesParseState {
  _ResponsesParseState({required this.model, required this.generation});

  final LlmModel model;
  final LlmGenerationConfig generation;
  LlmUsage? usage;
  final Map<String, _FunctionCallRef> _callsByItemId =
      <String, _FunctionCallRef>{};
  final Map<int, Map<String, Object?>> _completedByIndex =
      <int, Map<String, Object?>>{};
  var _toolIndex = 0;
  var _sawFunctionCall = false;

  void handle(SseMessage message, LlmStreamSink sink, ProviderId providerId) {
    if (message.data == '[DONE]') {
      if (!sink.terminated) {
        sink.add(LlmFailed(interruptedProtocolError()));
      }
      return;
    }
    final payload = decodeSseJsonObject(message.data, providerId);
    final type = payload['type'] is String
        ? payload['type'] as String
        : message.event;
    if (type == null || type.isEmpty) {
      throwLlm(LlmErrorKind.protocol, 'Responses event is missing a type.');
    }
    switch (type) {
      case 'response.output_text.delta':
        final text = _deltaText(payload);
        if (text != null && text.isNotEmpty) {
          sink.add(LlmTextDelta(text));
        }
      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_text.delta':
      case 'response.reasoning.delta':
        if (model.capabilities.reasoning ==
            ModelReasoningCapability.unsupported) {
          sink.add(LlmFailed(protocolError(providerId)));
          return;
        }
        final text = _deltaText(payload);
        if (text != null && text.isNotEmpty) {
          sink.add(LlmReasoningDelta(text));
        }
      case 'response.output_item.added':
        _handleItemAdded(payload, sink);
      case 'response.output_item.done':
        _handleItemDone(payload, sink, providerId);
      case 'response.function_call_arguments.delta':
        _handleArgumentDelta(payload, sink);
      case 'response.completed':
        final completedUsage = _usageFrom(payload) ?? usage;
        usage = completedUsage;
        if (completedUsage != null) {
          sink.add(LlmUsageUpdate(completedUsage));
        }
        final turnState = _turnStateOrFailure(sink, providerId);
        if (sink.terminated) {
          return;
        }
        sink.add(
          LlmCompleted(
            finishReason: _completedFinishReason(payload),
            usage: completedUsage,
            turnState: turnState,
          ),
        );
      case 'response.incomplete':
        final completedUsage = _usageFrom(payload) ?? usage;
        sink.add(
          LlmCompleted(
            finishReason: _incompleteFinishReason(payload),
            usage: completedUsage,
          ),
        );
      case 'response.failed':
      case 'error':
        sink.add(LlmFailed(providerStreamError(providerId)));
      case 'response.refusal.delta':
      case 'response.output_text.refusal':
        sink.add(LlmFailed(providerStreamError(providerId)));
      default:
        if (payload['error'] != null) {
          sink.add(LlmFailed(providerStreamError(providerId)));
        }
    }
  }

  void _handleItemDone(
    Map<String, Object?> payload,
    LlmStreamSink sink,
    ProviderId providerId,
  ) {
    final item = asJsonObject(payload['item']);
    if (item == null) {
      throwLlm(
        LlmErrorKind.protocol,
        'Responses output_item.done is missing an item.',
      );
    }
    validateOpenAiResponsesOutputItem(item);
    if (item['type'] == 'reasoning' &&
        model.capabilities.reasoning == ModelReasoningCapability.unsupported) {
      sink.add(LlmFailed(protocolError(providerId)));
      return;
    }
    if (item['type'] == 'function_call') {
      _assertFunctionCallMatchesStream(item);
    }
    final index = readNonNegativeInt(
      payload['output_index'],
      field: 'output_index',
    );
    if (index == null) {
      throwLlm(
        LlmErrorKind.protocol,
        'Responses output_item.done is missing output_index.',
      );
    }
    final copy = Map<String, Object?>.from(item);
    final existing = _completedByIndex[index];
    if (existing != null) {
      if (!jsonEquals(existing, copy)) {
        throwLlm(
          LlmErrorKind.protocol,
          'Conflicting Responses output item at index $index.',
        );
      }
      return;
    }
    _completedByIndex[index] = copy;
  }

  void _assertFunctionCallMatchesStream(Map<String, Object?> item) {
    final itemId = item['id'] is String ? (item['id'] as String).trim() : '';
    final ref = _callsByItemId[itemId];
    if (ref == null) {
      return;
    }
    final callId = (item['call_id'] as String).trim();
    final name = (item['name'] as String).trim();
    final arguments = item['arguments'] as String;
    if (ref.callId.value != callId ||
        (ref.name.isNotEmpty && ref.name != name) ||
        (ref.arguments.isNotEmpty && ref.arguments != arguments)) {
      throwLlm(
        LlmErrorKind.protocol,
        'function_call output item does not match streamed tool call.',
      );
    }
  }

  List<Map<String, Object?>> _sortedCompletedItems() {
    final indexes = _completedByIndex.keys.toList()..sort();
    return [
      for (final index in indexes)
        Map<String, Object?>.from(_completedByIndex[index]!),
    ];
  }

  LlmProviderTurnState? _turnStateOrFailure(
    LlmStreamSink sink,
    ProviderId providerId,
  ) {
    final completedItems = _sortedCompletedItems();
    if (completedItems.isEmpty) {
      if (_sawFunctionCall &&
          generation.reasoningMode == ReasoningMode.enabled &&
          model.capabilities.reasoning !=
              ModelReasoningCapability.unsupported) {
        sink.add(LlmFailed(protocolError(providerId)));
      }
      return null;
    }
    final state = LlmProviderTurnState(
      origin: model.ref,
      wireFamily: LlmWireFamily.openaiResponses,
      format: openaiResponsesOutputItemsV1,
      payload: completedItems,
    );
    final reasoningEnabled =
        generation.reasoningMode == ReasoningMode.enabled &&
        model.capabilities.reasoning != ModelReasoningCapability.unsupported;
    if (reasoningEnabled &&
        (_sawFunctionCall || responsesTurnStateHasFunctionCall(state)) &&
        !responsesTurnStateHasEncryptedReasoning(state)) {
      sink.add(LlmFailed(protocolError(providerId)));
      return null;
    }
    if (!reasoningEnabled) {
      return null;
    }
    if (!responsesTurnStateHasEncryptedReasoning(state) &&
        !responsesTurnStateHasFunctionCall(state) &&
        !_sawFunctionCall) {
      return null;
    }
    return state;
  }

  void _handleItemAdded(Map<String, Object?> payload, LlmStreamSink sink) {
    final item = asJsonObject(payload['item']);
    if (item == null) {
      return;
    }
    if (item['type'] != 'function_call') {
      return;
    }
    final itemId = item['id'] is String ? (item['id'] as String).trim() : '';
    final callIdValue = item['call_id'] is String
        ? (item['call_id'] as String).trim()
        : '';
    if (itemId.isEmpty) {
      throwLlm(LlmErrorKind.protocol, 'Function call is missing an item id.');
    }
    if (callIdValue.isEmpty) {
      throwLlm(
        LlmErrorKind.protocol,
        'Function call is missing a stable identifier.',
      );
    }
    final callId = ToolCallId(callIdValue);
    _sawFunctionCall = true;
    final index =
        readNonNegativeInt(payload['output_index'], field: 'output_index') ??
        _toolIndex++;
    final name = item['name'] is String ? item['name'] as String : null;
    final arguments = item['arguments'] is String
        ? item['arguments'] as String
        : null;
    _callsByItemId[itemId] = _FunctionCallRef(
      callId: callId,
      index: index,
      name: name ?? '',
      arguments: arguments ?? '',
    );
    sink.add(
      LlmToolCallDelta(
        callId: callId,
        index: index,
        name: name,
        argumentsFragment: arguments == null || arguments.isEmpty
            ? null
            : arguments,
      ),
    );
  }

  void _handleArgumentDelta(Map<String, Object?> payload, LlmStreamSink sink) {
    final itemId = payload['item_id'] is String
        ? (payload['item_id'] as String).trim()
        : '';
    if (itemId.isEmpty) {
      throwLlm(
        LlmErrorKind.protocol,
        'Function call argument delta is missing item_id.',
      );
    }
    final ref = _callsByItemId[itemId];
    if (ref == null) {
      throwLlm(
        LlmErrorKind.protocol,
        'Function call argument delta refers to an unknown item.',
      );
    }
    final index = readNonNegativeInt(
      payload['output_index'],
      field: 'output_index',
    );
    if (index != null && index != ref.index) {
      throwLlm(
        LlmErrorKind.protocol,
        'Function call argument delta index does not match the item.',
      );
    }
    _sawFunctionCall = true;
    final delta = _deltaText(payload) ?? '';
    ref.arguments = '${ref.arguments}$delta';
    sink.add(
      LlmToolCallDelta(
        callId: ref.callId,
        index: ref.index,
        argumentsFragment: delta,
      ),
    );
  }

  LlmFinishReason _completedFinishReason(Map<String, Object?> payload) {
    if (_sawFunctionCall || _outputContainsFunctionCall(payload)) {
      return LlmFinishReason.toolCalls;
    }
    return LlmFinishReason.stop;
  }

  LlmFinishReason _incompleteFinishReason(Map<String, Object?> payload) {
    final response = asJsonObject(payload['response']) ?? payload;
    final details = asJsonObject(response['incomplete_details']);
    final reason = details?['reason'] ?? response['reason'];
    if (reason is! String) {
      return LlmFinishReason.unknown;
    }
    return switch (reason) {
      'max_output_tokens' || 'length' => LlmFinishReason.length,
      'content_filter' => LlmFinishReason.contentFilter,
      _ => LlmFinishReason.unknown,
    };
  }

  bool _outputContainsFunctionCall(Map<String, Object?> payload) {
    final response = asJsonObject(payload['response']) ?? payload;
    final output = response['output'];
    if (output is! List) {
      return false;
    }
    for (final item in output) {
      final map = asJsonObject(item);
      if (map?['type'] == 'function_call') {
        return true;
      }
    }
    return false;
  }

  LlmUsage? _usageFrom(Map<String, Object?> payload) {
    final response = asJsonObject(payload['response']) ?? payload;
    final rawUsage = response['usage'];
    if (rawUsage == null) {
      return null;
    }
    final usageMap = asJsonObject(rawUsage);
    if (usageMap == null) {
      throwLlm(LlmErrorKind.protocol, 'Expected a usage object.');
    }
    final rawDetails = usageMap['input_tokens_details'];
    Map<String, Object?>? details;
    if (rawDetails != null) {
      details = asJsonObject(rawDetails);
      if (details == null) {
        throwLlm(
          LlmErrorKind.protocol,
          'Expected input_tokens_details object.',
        );
      }
    }
    final parsed = LlmUsage(
      inputTokens: readNonNegativeInt(
        usageMap['input_tokens'],
        field: 'input_tokens',
      ),
      outputTokens: readNonNegativeInt(
        usageMap['output_tokens'],
        field: 'output_tokens',
      ),
      totalTokens: readNonNegativeInt(
        usageMap['total_tokens'],
        field: 'total_tokens',
      ),
      cacheHitTokens: details == null
          ? null
          : readNonNegativeInt(
              details['cached_tokens'],
              field: 'cached_tokens',
            ),
    );
    if (parsed.isEmpty) {
      return null;
    }
    usage = parsed;
    return parsed;
  }

  static String? _deltaText(Map<String, Object?> payload) {
    if (payload.containsKey('delta')) {
      final delta = payload['delta'];
      if (delta is String) {
        return delta;
      }
      final nested = asJsonObject(delta);
      if (nested != null && nested['text'] is String) {
        return nested['text'] as String;
      }
      throwLlm(LlmErrorKind.protocol, 'Expected text delta to be a string.');
    }
    if (payload.containsKey('text')) {
      final text = payload['text'];
      if (text is String) {
        return text;
      }
      throwLlm(LlmErrorKind.protocol, 'Expected text field to be a string.');
    }
    return null;
  }
}

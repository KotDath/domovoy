import 'errors.dart';
import 'identifiers.dart';
import 'json.dart';
import 'messages.dart';

const openaiResponsesOutputItemsV1 = 'openai.responses.output_items.v1';

final class LlmProviderTurnState {
  LlmProviderTurnState({
    required this.origin,
    required this.wireFamily,
    required String format,
    required Object payload,
  }) : format = format.trim(),
       payload = _requirePayload(payload) {
    if (this.format.isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Provider turn-state format must not be blank.',
      );
    }
    _assertKnownFormat(this.format, wireFamily);
    if (this.format == openaiResponsesOutputItemsV1) {
      validateOpenAiResponsesOutputItems(this.payload);
    }
  }

  factory LlmProviderTurnState.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmProviderTurnState(
      origin: ModelRef.fromJson(map['origin']),
      wireFamily: LlmWireFamily.fromJson(map['wireFamily']),
      format: requireNonBlankString(map, 'format'),
      payload:
          map['payload'] ??
          (throwLlm(LlmErrorKind.protocol, 'Expected payload field.')),
    );
  }

  static const jsonType = 'llm.provider_turn_state';

  final ModelRef origin;
  final LlmWireFamily wireFamily;
  final String format;
  final Object payload;

  int get itemCount {
    final items = payload is List ? payload as List : const <Object?>[];
    return items.length;
  }

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'origin': origin.toJson(),
      'wireFamily': wireFamily.toJson(),
      'format': format,
      'payload': deepCopyJson(payload),
    },
  );

  Map<String, Object?> diagnosticSummary() => <String, Object?>{
    'origin': origin.toString(),
    'wireFamily': wireFamily.wireName,
    'format': format,
    'itemCount': itemCount,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmProviderTurnState &&
          other.origin == origin &&
          other.wireFamily == wireFamily &&
          other.format == format &&
          jsonEquals(other.payload, payload);

  @override
  int get hashCode =>
      Object.hash(origin, wireFamily, format, jsonHash(payload));

  @override
  String toString() =>
      'LlmProviderTurnState($origin, ${wireFamily.wireName}, $format, items: $itemCount)';
}

final class LlmContinuationEntry {
  LlmContinuationEntry({
    required this.assistantMessageIndex,
    required this.state,
  }) {
    if (assistantMessageIndex < 0) {
      throwLlm(
        LlmErrorKind.configuration,
        'Continuation assistant-message index must be non-negative.',
      );
    }
  }

  factory LlmContinuationEntry.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final index = requireInt(map, 'assistantMessageIndex');
    if (index < 0) {
      throwLlm(
        LlmErrorKind.protocol,
        'Continuation assistant-message index must be non-negative.',
      );
    }
    return LlmContinuationEntry(
      assistantMessageIndex: index,
      state: LlmProviderTurnState.fromJson(map['state']),
    );
  }

  static const jsonType = 'llm.continuation_entry';

  final int assistantMessageIndex;
  final LlmProviderTurnState state;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'assistantMessageIndex': assistantMessageIndex,
      'state': state.toJson(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmContinuationEntry &&
          other.assistantMessageIndex == assistantMessageIndex &&
          other.state == state;

  @override
  int get hashCode => Object.hash(assistantMessageIndex, state);

  @override
  String toString() =>
      'LlmContinuationEntry(index: $assistantMessageIndex, ${state.diagnosticSummary()})';
}

void validateContinuationEntries({
  required List<LlmMessage> messages,
  required List<LlmContinuationEntry> entries,
  required ModelRef origin,
  required LlmWireFamily wireFamily,
}) {
  final seen = <int>{};
  for (final entry in entries) {
    if (!seen.add(entry.assistantMessageIndex)) {
      throwLlm(
        LlmErrorKind.configuration,
        'Duplicate continuation entry for message ${entry.assistantMessageIndex}.',
      );
    }
    if (entry.assistantMessageIndex >= messages.length) {
      throwLlm(
        LlmErrorKind.configuration,
        'Continuation entry points outside the transcript.',
      );
    }
    final message = messages[entry.assistantMessageIndex];
    if (message.role != LlmMessageRole.assistant) {
      throwLlm(
        LlmErrorKind.configuration,
        'Continuation entries must point to assistant messages.',
      );
    }
    if (entry.state.origin != origin || entry.state.wireFamily != wireFamily) {
      throwLlm(
        LlmErrorKind.configuration,
        'Continuation state does not match the selected provider/model/wire family.',
      );
    }
    _assertNormalizedContentConsistent(message, entry.state);
  }
}

void validateOpenAiResponsesOutputItems(Object payload) {
  if (payload is! List) {
    throwLlm(
      LlmErrorKind.protocol,
      'OpenAI Responses turn state must be a list of output items.',
    );
  }
  if (payload.isEmpty) {
    throwLlm(
      LlmErrorKind.protocol,
      'OpenAI Responses turn state must contain at least one output item.',
    );
  }
  for (final item in payload) {
    validateOpenAiResponsesOutputItem(item);
  }
}

void validateOpenAiResponsesOutputItem(Object? item) {
  final map = asJsonObject(item);
  if (map == null) {
    throwLlm(
      LlmErrorKind.protocol,
      'OpenAI Responses output items must be objects.',
    );
  }
  final type = map['type'];
  if (type is! String || type.trim().isEmpty) {
    throwLlm(
      LlmErrorKind.protocol,
      'OpenAI Responses output items must declare a type.',
    );
  }
  switch (type) {
    case 'reasoning':
      _validateClosedObject(
        map,
        allowed: const <String>{
          'type',
          'id',
          'status',
          'summary',
          'content',
          'encrypted_content',
        },
        requiredFields: const <String>['id'],
        label: 'reasoning output item',
      );
      _validateRequiredString(map, 'id', label: 'reasoning output item');
      _validateOptionalEnum(
        map['status'],
        allowed: _outputItemStatuses,
        label: 'reasoning status',
      );
      _validateOptionalTextParts(
        map['summary'],
        itemType: 'summary_text',
        label: 'reasoning summary',
      );
      _validateOptionalTextParts(
        map['content'],
        itemType: 'reasoning_text',
        label: 'reasoning content',
      );
      final encrypted = map['encrypted_content'];
      if (encrypted != null && encrypted is! String) {
        throwLlm(
          LlmErrorKind.protocol,
          'reasoning encrypted_content must be a string.',
        );
      }
    case 'message':
      _validateClosedObject(
        map,
        allowed: const <String>{
          'type',
          'id',
          'status',
          'role',
          'content',
          'phase',
        },
        requiredFields: const <String>['id', 'content'],
        label: 'message output item',
      );
      _validateRequiredString(map, 'id', label: 'message output item');
      _validateOptionalEnum(
        map['status'],
        allowed: _outputItemStatuses,
        label: 'message status',
      );
      _validateOptionalEnum(
        map['phase'],
        allowed: _messagePhases,
        label: 'message phase',
      );
      final role = map['role'];
      if (role != null && role != 'assistant') {
        throwLlm(
          LlmErrorKind.protocol,
          'message output item role must be assistant.',
        );
      }
      _validateMessageContent(map['content']);
    case 'function_call':
      _validateClosedObject(
        map,
        allowed: const <String>{
          'type',
          'id',
          'status',
          'call_id',
          'name',
          'arguments',
        },
        requiredFields: const <String>['id', 'call_id', 'name', 'arguments'],
        label: 'function_call output item',
      );
      _validateRequiredString(map, 'id', label: 'function_call output item');
      _validateRequiredString(
        map,
        'call_id',
        label: 'function_call output item',
      );
      _validateRequiredString(map, 'name', label: 'function_call output item');
      _validateOptionalEnum(
        map['status'],
        allowed: _outputItemStatuses,
        label: 'function_call status',
      );
      if (map['arguments'] is! String) {
        throwLlm(
          LlmErrorKind.protocol,
          'function_call arguments must be a string.',
        );
      }
    default:
      throwLlm(
        LlmErrorKind.protocol,
        'Unsupported OpenAI Responses output item type "$type".',
      );
  }
}

bool responsesTurnStateHasEncryptedReasoning(LlmProviderTurnState state) {
  if (state.format != openaiResponsesOutputItemsV1 || state.payload is! List) {
    return false;
  }
  for (final item in state.payload as List) {
    final map = asJsonObject(item);
    if (map == null || map['type'] != 'reasoning') {
      continue;
    }
    final encrypted = map['encrypted_content'];
    if (encrypted is String && encrypted.trim().isNotEmpty) {
      return true;
    }
  }
  return false;
}

bool responsesTurnStateHasFunctionCall(LlmProviderTurnState state) {
  if (state.format != openaiResponsesOutputItemsV1 || state.payload is! List) {
    return false;
  }
  for (final item in state.payload as List) {
    final map = asJsonObject(item);
    if (map?['type'] == 'function_call') {
      return true;
    }
  }
  return false;
}

Object _requirePayload(Object payload) {
  final frozen = deepFreezeJson(deepCopyJson(payload));
  if (frozen == null) {
    throwLlm(
      LlmErrorKind.configuration,
      'Turn state payload must not be null.',
    );
  }
  return frozen;
}

void _assertKnownFormat(String format, LlmWireFamily wireFamily) {
  if (format == openaiResponsesOutputItemsV1) {
    if (wireFamily != LlmWireFamily.openaiResponses) {
      throwLlm(
        LlmErrorKind.configuration,
        'Format "$format" is not valid for ${wireFamily.wireName}.',
      );
    }
    return;
  }
  throwLlm(
    LlmErrorKind.configuration,
    'Unknown continuation format "$format".',
  );
}

const _outputItemStatuses = <String>{'in_progress', 'completed', 'incomplete'};
const _messagePhases = <String>{'commentary', 'final_answer'};

void assertResponsesTurnStateMatchesAssistant({
  required LlmProviderTurnState? state,
  required String text,
  required List<LlmToolCallPart> calls,
}) {
  if (state == null || state.format != openaiResponsesOutputItemsV1) {
    return;
  }
  if (state.payload is! List) {
    throwLlm(
      LlmErrorKind.protocol,
      'OpenAI Responses turn state must be a list of output items.',
    );
  }
  final projected = _assistantProjectionFromResponsesPayload(state.payload);
  if (projected.text != text) {
    throwLlm(
      LlmErrorKind.protocol,
      'Complete message output items must match streamed assistant text.',
    );
  }
  if (projected.calls.length != calls.length) {
    throwLlm(
      LlmErrorKind.protocol,
      'Complete function_call output items must match streamed tool calls.',
    );
  }
  for (var index = 0; index < calls.length; index++) {
    final call = calls[index];
    final payload = projected.calls[index];
    if (payload.callId != call.callId.value ||
        payload.name != call.name ||
        payload.arguments != call.arguments) {
      throwLlm(
        LlmErrorKind.protocol,
        'Complete function_call output items must match streamed tool calls.',
      );
    }
  }
}

({String text, List<({String callId, String name, String arguments})> calls})
_assistantProjectionFromResponsesPayload(Object payload) {
  final text = StringBuffer();
  final calls = <({String callId, String name, String arguments})>[];
  if (payload is! List) {
    return (text: '', calls: calls);
  }
  for (final item in payload) {
    final map = asJsonObject(item);
    if (map == null) {
      continue;
    }
    switch (map['type']) {
      case 'message':
        text.write(_joinTextParts(map['content']));
      case 'function_call':
        calls.add((
          callId: (map['call_id'] as String).trim(),
          name: (map['name'] as String).trim(),
          arguments: map['arguments'] as String,
        ));
    }
  }
  return (text: text.toString(), calls: calls);
}

void _assertNormalizedContentConsistent(
  LlmMessage message,
  LlmProviderTurnState state,
) {
  if (state.format != openaiResponsesOutputItemsV1 || state.payload is! List) {
    return;
  }
  final text = message.parts
      .whereType<LlmTextPart>()
      .map((part) => part.text)
      .join();
  final calls = message.parts.whereType<LlmToolCallPart>().toList();
  final projected = _assistantProjectionFromResponsesPayload(state.payload);
  if (projected.text != text) {
    throwLlm(
      LlmErrorKind.configuration,
      'Continuation message text does not match the assistant message.',
    );
  }
  if (projected.calls.length != calls.length) {
    throwLlm(
      LlmErrorKind.configuration,
      'Continuation function calls do not match the assistant message.',
    );
  }
  for (var index = 0; index < calls.length; index++) {
    final call = calls[index];
    final payload = projected.calls[index];
    if (payload.callId != call.callId.value ||
        payload.name != call.name ||
        payload.arguments != call.arguments) {
      throwLlm(
        LlmErrorKind.configuration,
        'Continuation function-call fields do not match the assistant message.',
      );
    }
  }
}

void _validateClosedObject(
  Map<String, Object?> map, {
  required Set<String> allowed,
  required List<String> requiredFields,
  required String label,
}) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throwLlm(LlmErrorKind.protocol, 'Unsupported $label field "$key".');
    }
  }
  for (final field in requiredFields) {
    final value = map[field];
    if (value == null || (value is String && value.trim().isEmpty)) {
      throwLlm(LlmErrorKind.protocol, '$label is missing "$field".');
    }
  }
}

void _validateRequiredString(
  Map<String, Object?> map,
  String field, {
  required String label,
}) {
  final value = map[field];
  if (value is! String || value.trim().isEmpty) {
    throwLlm(
      LlmErrorKind.protocol,
      '$label "$field" must be a non-empty string.',
    );
  }
}

void _validateRequiredNonNegativeInt(
  Map<String, Object?> map,
  String field, {
  required String label,
}) {
  final value = map[field];
  if (value is! int || value < 0) {
    throwLlm(
      LlmErrorKind.protocol,
      '$label "$field" must be a non-negative integer.',
    );
  }
}

void _validateOptionalEnum(
  Object? value, {
  required Set<String> allowed,
  required String label,
}) {
  if (value == null) {
    return;
  }
  if (value is! String || !allowed.contains(value)) {
    throwLlm(
      LlmErrorKind.protocol,
      '$label must be one of ${allowed.join(', ')}.',
    );
  }
}

void _validateOptionalTextParts(
  Object? value, {
  required String itemType,
  required String label,
}) {
  if (value == null) {
    return;
  }
  _validateRequiredTextParts(value, itemType: itemType, label: label);
}

void _validateRequiredTextParts(
  Object? value, {
  required String itemType,
  required String label,
}) {
  if (value is! List) {
    throwLlm(LlmErrorKind.protocol, '$label must be a list.');
  }
  for (final item in value) {
    final map = asJsonObject(item);
    if (map == null) {
      throwLlm(LlmErrorKind.protocol, '$label entries must be objects.');
    }
    _validateClosedObject(
      map,
      allowed: const <String>{'type', 'text'},
      requiredFields: const <String>['type', 'text'],
      label: label,
    );
    if (map['type'] != itemType) {
      throwLlm(LlmErrorKind.protocol, '$label type must be "$itemType".');
    }
    if (map['text'] is! String) {
      throwLlm(LlmErrorKind.protocol, '$label text must be a string.');
    }
  }
}

void _validateMessageContent(Object? value) {
  if (value is! List) {
    throwLlm(LlmErrorKind.protocol, 'message content must be a list.');
  }
  for (final item in value) {
    final map = asJsonObject(item);
    if (map == null) {
      throwLlm(
        LlmErrorKind.protocol,
        'message content entries must be objects.',
      );
    }
    _validateClosedObject(
      map,
      allowed: const <String>{'type', 'text', 'annotations'},
      requiredFields: const <String>['type', 'text'],
      label: 'message content',
    );
    if (map['type'] != 'output_text') {
      throwLlm(
        LlmErrorKind.protocol,
        'message content type must be "output_text".',
      );
    }
    if (map['text'] is! String) {
      throwLlm(LlmErrorKind.protocol, 'message content text must be a string.');
    }
    _validateOutputTextAnnotations(map['annotations']);
  }
}

void _validateOutputTextAnnotations(Object? value) {
  if (value == null) {
    return;
  }
  if (value is! List) {
    throwLlm(LlmErrorKind.protocol, 'output_text annotations must be a list.');
  }
  for (final item in value) {
    final map = asJsonObject(item);
    if (map == null) {
      throwLlm(
        LlmErrorKind.protocol,
        'output_text annotations must be objects.',
      );
    }
    final type = map['type'];
    if (type is! String) {
      throwLlm(
        LlmErrorKind.protocol,
        'output_text annotation type must be a string.',
      );
    }
    switch (type) {
      case 'url_citation':
        _validateClosedObject(
          map,
          allowed: const <String>{
            'type',
            'start_index',
            'end_index',
            'url',
            'title',
          },
          requiredFields: const <String>[
            'type',
            'url',
            'title',
            'start_index',
            'end_index',
          ],
          label: 'url_citation annotation',
        );
        _validateRequiredString(map, 'url', label: 'url_citation annotation');
        _validateRequiredString(map, 'title', label: 'url_citation annotation');
        _validateRequiredNonNegativeInt(
          map,
          'start_index',
          label: 'url_citation annotation',
        );
        _validateRequiredNonNegativeInt(
          map,
          'end_index',
          label: 'url_citation annotation',
        );
      case 'file_citation':
        _validateClosedObject(
          map,
          allowed: const <String>{'type', 'index', 'file_id', 'filename'},
          requiredFields: const <String>[
            'type',
            'file_id',
            'index',
            'filename',
          ],
          label: 'file_citation annotation',
        );
        _validateRequiredString(
          map,
          'file_id',
          label: 'file_citation annotation',
        );
        _validateRequiredNonNegativeInt(
          map,
          'index',
          label: 'file_citation annotation',
        );
        _validateRequiredString(
          map,
          'filename',
          label: 'file_citation annotation',
        );
      case 'container_file_citation':
        _validateClosedObject(
          map,
          allowed: const <String>{
            'type',
            'container_id',
            'file_id',
            'start_index',
            'end_index',
            'filename',
          },
          requiredFields: const <String>[
            'type',
            'container_id',
            'file_id',
            'start_index',
            'end_index',
            'filename',
          ],
          label: 'container_file_citation annotation',
        );
        _validateRequiredString(
          map,
          'container_id',
          label: 'container_file_citation annotation',
        );
        _validateRequiredString(
          map,
          'file_id',
          label: 'container_file_citation annotation',
        );
        _validateRequiredNonNegativeInt(
          map,
          'start_index',
          label: 'container_file_citation annotation',
        );
        _validateRequiredNonNegativeInt(
          map,
          'end_index',
          label: 'container_file_citation annotation',
        );
        _validateRequiredString(
          map,
          'filename',
          label: 'container_file_citation annotation',
        );
      case 'file_path':
        _validateClosedObject(
          map,
          allowed: const <String>{'type', 'file_id', 'index'},
          requiredFields: const <String>['type', 'file_id', 'index'],
          label: 'file_path annotation',
        );
        _validateRequiredString(map, 'file_id', label: 'file_path annotation');
        _validateRequiredNonNegativeInt(
          map,
          'index',
          label: 'file_path annotation',
        );
      default:
        throwLlm(
          LlmErrorKind.protocol,
          'Unsupported output_text annotation type "$type".',
        );
    }
  }
}

String _joinTextParts(Object? value) {
  if (value is! List) {
    return '';
  }
  final buffer = StringBuffer();
  for (final item in value) {
    final map = asJsonObject(item);
    final text = map?['text'];
    if (text is String) {
      buffer.write(text);
    }
  }
  return buffer.toString();
}

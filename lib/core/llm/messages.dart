import 'errors.dart';
import 'identifiers.dart';
import 'json.dart';

enum LlmMessageRole {
  user,
  assistant,
  tool;

  static LlmMessageRole fromName(String value) {
    return switch (value) {
      'user' => LlmMessageRole.user,
      'assistant' => LlmMessageRole.assistant,
      'tool' => LlmMessageRole.tool,
      _ => throwLlm(LlmErrorKind.protocol, 'Unknown message role "$value".'),
    };
  }
}

sealed class LlmContentPart {
  const LlmContentPart();

  Map<String, Object?> toJson();

  static LlmContentPart fromJson(Object? json) {
    if (json is! Map) {
      throwLlm(LlmErrorKind.protocol, 'Expected a content part object.');
    }
    final raw = Map<Object?, Object?>.from(json);
    final type = raw[llmJsonTypeKey];
    return switch (type) {
      LlmTextPart.jsonType => LlmTextPart.fromJson(json),
      LlmReasoningPart.jsonType => LlmReasoningPart.fromJson(json),
      LlmToolCallPart.jsonType => LlmToolCallPart.fromJson(json),
      LlmToolResultPart.jsonType => LlmToolResultPart.fromJson(json),
      _ => throwLlm(
        LlmErrorKind.protocol,
        'Unknown content part type "$type".',
      ),
    };
  }
}

final class LlmTextPart extends LlmContentPart {
  LlmTextPart(this.text);

  factory LlmTextPart.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmTextPart(requireString(map, 'text'));
  }

  static const jsonType = 'llm.text_part';

  final String text;

  @override
  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'text': text});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LlmTextPart && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

final class LlmReasoningPart extends LlmContentPart {
  LlmReasoningPart(this.text);

  factory LlmReasoningPart.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmReasoningPart(requireString(map, 'text'));
  }

  static const jsonType = 'llm.reasoning_part';

  final String text;

  @override
  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'text': text});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LlmReasoningPart && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

final class LlmToolCallPart extends LlmContentPart {
  LlmToolCallPart({
    required this.callId,
    required String name,
    required this.arguments,
  }) : name = name.trim() {
    if (this.name.isEmpty) {
      throwLlm(LlmErrorKind.configuration, 'Tool call name must not be blank.');
    }
  }

  factory LlmToolCallPart.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmToolCallPart(
      callId: ToolCallId.fromJson(map['callId']),
      name: requireString(map, 'name'),
      arguments: requireString(map, 'arguments'),
    );
  }

  static const jsonType = 'llm.tool_call_part';

  final ToolCallId callId;
  final String name;
  final String arguments;

  @override
  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'callId': callId.toJson(),
      'name': name,
      'arguments': arguments,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmToolCallPart &&
          other.callId == callId &&
          other.name == name &&
          other.arguments == arguments;

  @override
  int get hashCode => Object.hash(callId, name, arguments);
}

final class LlmToolResultPart extends LlmContentPart {
  LlmToolResultPart({required this.callId, required this.content});

  factory LlmToolResultPart.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final callJson = map['callId'];
    if (callJson == null) {
      throwLlm(
        LlmErrorKind.protocol,
        'Tool result is missing a call identifier.',
      );
    }
    return LlmToolResultPart(
      callId: ToolCallId.fromJson(callJson),
      content: requireString(map, 'content'),
    );
  }

  static const jsonType = 'llm.tool_result_part';

  final ToolCallId callId;
  final String content;

  @override
  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{'callId': callId.toJson(), 'content': content},
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmToolResultPart &&
          other.callId == callId &&
          other.content == content;

  @override
  int get hashCode => Object.hash(callId, content);
}

final class LlmMessage {
  LlmMessage({required this.role, required List<LlmContentPart> parts})
    : parts = List<LlmContentPart>.unmodifiable(
        List<LlmContentPart>.from(parts),
      ) {
    if (this.parts.isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Message must contain at least one content part.',
      );
    }
    for (final part in this.parts) {
      if (!_isAllowed(role, part)) {
        throwLlm(
          LlmErrorKind.configuration,
          'Content part ${part.runtimeType} is not allowed for role ${role.name}.',
        );
      }
    }
  }

  factory LlmMessage.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmMessage(
      role: LlmMessageRole.fromName(requireNonBlankString(map, 'role')),
      parts: requireList(map, 'parts').map(LlmContentPart.fromJson).toList(),
    );
  }

  static const jsonType = 'llm.message';

  final LlmMessageRole role;
  final List<LlmContentPart> parts;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'role': role.name,
      'parts': parts.map((part) => part.toJson()).toList(growable: false),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmMessage &&
          other.role == role &&
          listEquals(other.parts, parts);

  @override
  int get hashCode => Object.hash(role, Object.hashAll(parts));
}

bool _isAllowed(LlmMessageRole role, LlmContentPart part) {
  return switch (role) {
    LlmMessageRole.user => part is LlmTextPart,
    LlmMessageRole.assistant =>
      part is LlmTextPart ||
          part is LlmReasoningPart ||
          part is LlmToolCallPart,
    LlmMessageRole.tool => part is LlmToolResultPart,
  };
}

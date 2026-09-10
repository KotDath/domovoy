import 'dart:async';

import 'continuation.dart';
import 'errors.dart';
import 'identifiers.dart';
import 'json.dart';
import 'usage.dart';

sealed class LlmEvent {
  const LlmEvent();

  bool get isTerminal =>
      this is LlmCompleted || this is LlmFailed || this is LlmCancelled;

  Map<String, Object?> toJson();

  static LlmEvent fromJson(Object? json) {
    if (json is! Map) {
      throwLlm(LlmErrorKind.protocol, 'Expected an event object.');
    }
    final raw = Map<Object?, Object?>.from(json);
    final type = raw[llmJsonTypeKey];
    return switch (type) {
      LlmReasoningDelta.jsonType => LlmReasoningDelta.fromJson(json),
      LlmTextDelta.jsonType => LlmTextDelta.fromJson(json),
      LlmToolCallDelta.jsonType => LlmToolCallDelta.fromJson(json),
      LlmUsageUpdate.jsonType => LlmUsageUpdate.fromJson(json),
      LlmCompleted.jsonType => LlmCompleted.fromJson(json),
      LlmFailed.jsonType => LlmFailed.fromJson(json),
      LlmCancelled.jsonType => LlmCancelled.fromJson(json),
      _ => throwLlm(LlmErrorKind.protocol, 'Unknown event type "$type".'),
    };
  }
}

final class LlmReasoningDelta extends LlmEvent {
  const LlmReasoningDelta(this.text);

  factory LlmReasoningDelta.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmReasoningDelta(requireString(map, 'text'));
  }

  static const jsonType = 'llm.reasoning_delta';

  final String text;

  @override
  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'text': text});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmReasoningDelta && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

final class LlmTextDelta extends LlmEvent {
  const LlmTextDelta(this.text);

  factory LlmTextDelta.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmTextDelta(requireString(map, 'text'));
  }

  static const jsonType = 'llm.text_delta';

  final String text;

  @override
  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: <String, Object?>{'text': text});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LlmTextDelta && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

final class LlmToolCallDelta extends LlmEvent {
  LlmToolCallDelta({
    required this.callId,
    required this.index,
    this.name,
    this.argumentsFragment,
  }) {
    if (index < 0) {
      throwLlm(
        LlmErrorKind.configuration,
        'Tool call index must be non-negative.',
      );
    }
    if (name != null && name!.trim().isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Tool call name fragment must not be blank.',
      );
    }
  }

  factory LlmToolCallDelta.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final index = requireInt(map, 'index');
    if (index < 0) {
      throwLlm(
        LlmErrorKind.protocol,
        'Tool call index must be a non-negative integer.',
      );
    }
    return LlmToolCallDelta(
      callId: ToolCallId.fromJson(map['callId']),
      index: index,
      name: optionalString(map, 'name'),
      argumentsFragment: optionalString(map, 'argumentsFragment'),
    );
  }

  static const jsonType = 'llm.tool_call_delta';

  final ToolCallId callId;
  final int index;
  final String? name;
  final String? argumentsFragment;

  @override
  Map<String, Object?> toJson() {
    final fields = <String, Object?>{'callId': callId.toJson(), 'index': index};
    if (name != null) {
      fields['name'] = name;
    }
    if (argumentsFragment != null) {
      fields['argumentsFragment'] = argumentsFragment;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmToolCallDelta &&
          other.callId == callId &&
          other.index == index &&
          other.name == name &&
          other.argumentsFragment == argumentsFragment;

  @override
  int get hashCode => Object.hash(callId, index, name, argumentsFragment);
}

final class LlmUsageUpdate extends LlmEvent {
  const LlmUsageUpdate(this.usage);

  factory LlmUsageUpdate.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmUsageUpdate(LlmUsage.fromJson(map['usage']));
  }

  static const jsonType = 'llm.usage_update';

  final LlmUsage usage;

  @override
  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{'usage': usage.toJson()},
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LlmUsageUpdate && other.usage == usage;

  @override
  int get hashCode => usage.hashCode;
}

final class LlmCompleted extends LlmEvent {
  const LlmCompleted({this.finishReason, this.usage, this.turnState});

  factory LlmCompleted.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmCompleted(
      finishReason: map['finishReason'] == null
          ? null
          : LlmFinishReason.fromJson(map['finishReason']),
      usage: map['usage'] == null ? null : LlmUsage.fromJson(map['usage']),
      turnState: map['turnState'] == null
          ? null
          : LlmProviderTurnState.fromJson(map['turnState']),
    );
  }

  static const jsonType = 'llm.completed';

  final LlmFinishReason? finishReason;
  final LlmUsage? usage;
  final LlmProviderTurnState? turnState;

  @override
  Map<String, Object?> toJson() {
    final fields = <String, Object?>{};
    if (finishReason != null) {
      fields['finishReason'] = finishReason!.toJson();
    }
    if (usage != null) {
      fields['usage'] = usage!.toJson();
    }
    if (turnState != null) {
      fields['turnState'] = turnState!.toJson();
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmCompleted &&
          other.finishReason == finishReason &&
          other.usage == usage &&
          other.turnState == turnState;

  @override
  int get hashCode => Object.hash(finishReason, usage, turnState);

  @override
  String toString() =>
      'LlmCompleted(finishReason: $finishReason, usage: $usage, '
      'turnState: ${turnState?.diagnosticSummary()})';
}

final class LlmFailed extends LlmEvent {
  const LlmFailed(this.error);

  factory LlmFailed.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmFailed(LlmError.fromJson(map['error']));
  }

  static const jsonType = 'llm.failed';

  final LlmError error;

  @override
  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{'error': error.toJson()},
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LlmFailed && other.error == error;

  @override
  int get hashCode => error.hashCode;
}

final class LlmCancelled extends LlmEvent {
  const LlmCancelled();

  factory LlmCancelled.fromJson(Object? json) {
    decodeTypedJson(json, type: jsonType);
    return const LlmCancelled();
  }

  static const jsonType = 'llm.cancelled';

  @override
  Map<String, Object?> toJson() =>
      typedJson(type: jsonType, fields: const <String, Object?>{});

  @override
  bool operator ==(Object other) => other is LlmCancelled;

  @override
  int get hashCode => jsonType.hashCode;
}

LlmError interruptedProtocolError() {
  return LlmError(
    kind: LlmErrorKind.interrupted,
    message: 'Соединение прервалось до завершения ответа.',
  );
}

LlmError unexpectedFailureError() {
  return LlmError(
    kind: LlmErrorKind.unknown,
    message: 'Не удалось получить ответ. Попробуйте ещё раз.',
  );
}

/// Enforces one terminal event, suppresses later events, and converts a stream
/// that closes without a terminal into an interrupted protocol failure.
Stream<LlmEvent> guardLlmEventStream(Stream<LlmEvent> source) {
  late StreamController<LlmEvent> controller;
  StreamSubscription<LlmEvent>? subscription;
  var terminated = false;

  void emit(LlmEvent event) {
    if (terminated || controller.isClosed) {
      return;
    }
    if (event.isTerminal) {
      terminated = true;
    }
    controller.add(event);
    if (terminated && !controller.isClosed) {
      scheduleMicrotask(() {
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      });
    }
  }

  controller = StreamController<LlmEvent>(
    onListen: () {
      subscription = source.listen(
        emit,
        onError: (Object error, StackTrace stackTrace) {
          emit(LlmFailed(unexpectedFailureError()));
        },
        onDone: () {
          if (!terminated) {
            emit(LlmFailed(interruptedProtocolError()));
          } else if (!controller.isClosed) {
            unawaited(controller.close());
          }
        },
        cancelOnError: false,
      );
    },
    onCancel: () async {
      await subscription?.cancel();
    },
  );
  return controller.stream;
}

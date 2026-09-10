import 'dart:async';

import 'package:domovoy/core/llm/llm.dart';

final class ScriptedLlmProvider implements LlmProvider {
  ScriptedLlmProvider({
    required this.id,
    required this.wireFamily,
    this.events = const <LlmEvent>[],
    this.closeWithoutTerminal = false,
    this.gate,
  });

  @override
  final ProviderId id;

  @override
  final LlmWireFamily wireFamily;

  final List<LlmEvent> events;
  final bool closeWithoutTerminal;
  final Completer<void>? gate;
  final List<LlmRequest> requests = <LlmRequest>[];

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    requests.add(request);
    if (cancellation.isCancelled) {
      yield const LlmCancelled();
      return;
    }
    for (final event in events) {
      if (cancellation.isCancelled) {
        yield const LlmCancelled();
        return;
      }
      yield event;
      if (event.isTerminal) {
        return;
      }
    }
    if (gate != null) {
      await Future.any<void>(<Future<void>>[
        gate!.future,
        cancellation.whenCancelled,
      ]);
      if (cancellation.isCancelled) {
        yield const LlmCancelled();
        return;
      }
    }
    if (closeWithoutTerminal) {
      return;
    }
    yield const LlmCompleted(finishReason: LlmFinishReason.stop);
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/llm/cancellation.dart';
import '../../../core/llm/credentials.dart';
import '../../../core/llm/errors.dart';
import '../../../core/llm/events.dart';
import '../../../core/llm/identifiers.dart';
import '../../../core/llm/json.dart';
import 'sse_decoder.dart';

final class LlmStreamSink {
  LlmStreamSink(this._controller);

  final StreamController<LlmEvent> _controller;
  var terminated = false;

  bool add(LlmEvent event) {
    if (terminated || _controller.isClosed) {
      return false;
    }
    if (event.isTerminal) {
      terminated = true;
    }
    _controller.add(event);
    return true;
  }
}

LlmError missingCredentialError(ProviderId providerId) {
  return LlmError(
    kind: LlmErrorKind.configuration,
    message: 'Для провайдера ${providerId.value} не задан API-ключ.',
  );
}

LlmError httpStatusError(ProviderId providerId, int statusCode) {
  if (statusCode == 401 || statusCode == 403) {
    return LlmError(
      kind: LlmErrorKind.authentication,
      message: 'Провайдер ${providerId.value} отклонил API-ключ.',
    );
  }
  if (statusCode == 429) {
    return LlmError(
      kind: LlmErrorKind.rateLimit,
      message:
          'Лимит запросов провайдера ${providerId.value} исчерпан. Попробуйте позже.',
    );
  }
  return LlmError(
    kind: LlmErrorKind.provider,
    message: 'Провайдер ${providerId.value} вернул ошибку HTTP $statusCode.',
  );
}

LlmError providerStreamError(ProviderId providerId) {
  return LlmError(
    kind: LlmErrorKind.provider,
    message:
        'Провайдер ${providerId.value} сообщил об ошибке во время генерации.',
  );
}

LlmError networkError(ProviderId providerId, {required bool timeout}) {
  if (timeout) {
    return LlmError(
      kind: LlmErrorKind.network,
      message:
          'Провайдер ${providerId.value} не ответил вовремя. Попробуйте ещё раз.',
    );
  }
  return LlmError(
    kind: LlmErrorKind.network,
    message:
        'Не удалось подключиться к провайдеру ${providerId.value}. Проверьте сеть.',
  );
}

LlmError protocolError(ProviderId providerId) {
  return LlmError(
    kind: LlmErrorKind.protocol,
    message:
        'Провайдер ${providerId.value} вернул поток в неожиданном формате.',
  );
}

Stream<LlmEvent> runLlmHttpStream({
  required ProviderId providerId,
  required Uri endpoint,
  required Map<String, Object?> body,
  required http.Client client,
  required ProviderCredentialResolver credentials,
  required String environmentVariable,
  required CancellationToken cancellation,
  required Future<void> Function(
    http.StreamedResponse response,
    LlmStreamSink sink,
    CancellationToken cancellation,
  )
  consume,
}) {
  late StreamController<LlmEvent> controller;
  final local = CancellationSource();
  var started = false;
  CancellationRegistration? requestedReg;

  void cancelAll() {
    local.cancel();
  }

  requestedReg = cancellation.register(cancelAll);

  final httpReleased = Completer<void>();
  void markHttpReleased() {
    if (!httpReleased.isCompleted) {
      httpReleased.complete();
    }
  }

  controller = StreamController<LlmEvent>(
    onListen: () {
      if (started) {
        return;
      }
      started = true;
      unawaited(() async {
        try {
          await _run(
            providerId: providerId,
            endpoint: endpoint,
            body: body,
            client: client,
            credentials: credentials,
            environmentVariable: environmentVariable,
            cancellation: local.token,
            requested: cancellation,
            consume: consume,
            controller: controller,
            onHttpReleased: markHttpReleased,
          );
        } finally {
          markHttpReleased();
          requestedReg?.dispose();
        }
      }());
    },
    onCancel: () async {
      requestedReg?.dispose();
      cancelAll();
      if (!started) {
        markHttpReleased();
      }
      await httpReleased.future;
    },
  );
  return controller.stream;
}

Future<void> _run({
  required ProviderId providerId,
  required Uri endpoint,
  required Map<String, Object?> body,
  required http.Client client,
  required ProviderCredentialResolver credentials,
  required String environmentVariable,
  required CancellationToken cancellation,
  required CancellationToken requested,
  required Future<void> Function(
    http.StreamedResponse response,
    LlmStreamSink sink,
    CancellationToken cancellation,
  )
  consume,
  required StreamController<LlmEvent> controller,
  required void Function() onHttpReleased,
}) async {
  final sink = LlmStreamSink(controller);
  bool isCancelled() => cancellation.isCancelled || requested.isCancelled;
  http.StreamedResponse? response;
  try {
    if (isCancelled()) {
      sink.add(const LlmCancelled());
      return;
    }
    final LlmResolvedCredential? credential;
    try {
      credential = await raceCancellation(
        credentials.resolve(
          providerId: providerId,
          environmentVariable: environmentVariable,
        ),
        cancellation: requested,
        also: cancellation,
      );
    } on LlmMissingCredentialException {
      if (isCancelled()) {
        sink.add(const LlmCancelled());
        return;
      }
      sink.add(LlmFailed(missingCredentialError(providerId)));
      return;
    }
    if (credential == null || isCancelled()) {
      sink.add(const LlmCancelled());
      return;
    }

    final request =
        http.AbortableRequest(
            'POST',
            endpoint,
            abortTrigger: cancellation.whenCancelled,
          )
          ..headers.addAll(<String, String>{
            'Accept': 'text/event-stream',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${credential.value}',
          })
          ..body = jsonEncode(body);

    response = await client.send(request);
    if (isCancelled()) {
      await _release(response);
      sink.add(const LlmCancelled());
      return;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final status = response.statusCode;
      await _release(response);
      sink.add(LlmFailed(httpStatusError(providerId, status)));
      return;
    }

    await consume(response, sink, cancellation);
    if (!sink.terminated) {
      if (isCancelled()) {
        sink.add(const LlmCancelled());
      } else {
        sink.add(LlmFailed(interruptedProtocolError()));
      }
    }
  } on http.RequestAbortedException {
    sink.add(const LlmCancelled());
  } on LlmException catch (error) {
    if (isCancelled()) {
      sink.add(const LlmCancelled());
    } else {
      sink.add(LlmFailed(error.error));
    }
  } on http.ClientException {
    if (isCancelled()) {
      sink.add(const LlmCancelled());
    } else {
      sink.add(LlmFailed(networkError(providerId, timeout: false)));
    }
  } on TimeoutException {
    if (isCancelled()) {
      sink.add(const LlmCancelled());
    } else {
      sink.add(LlmFailed(networkError(providerId, timeout: true)));
    }
  } on FormatException {
    if (isCancelled()) {
      sink.add(const LlmCancelled());
    } else {
      sink.add(LlmFailed(protocolError(providerId)));
    }
  } on Object {
    if (isCancelled()) {
      sink.add(const LlmCancelled());
    } else {
      sink.add(LlmFailed(unexpectedFailureError()));
    }
  } finally {
    try {
      if (response != null) {
        await _release(response);
      }
    } finally {
      onHttpReleased();
    }
    if (!controller.isClosed) {
      await controller.close();
    }
  }
}

Future<void> consumeSse({
  required http.StreamedResponse response,
  required LlmStreamSink sink,
  required CancellationToken cancellation,
  required Future<void> Function(SseMessage message, LlmStreamSink sink)
  onMessage,
}) async {
  if (cancellation.isCancelled || sink.terminated) {
    return;
  }
  final done = Completer<void>();
  late final StreamSubscription<SseMessage> subscription;
  void finish() {
    if (!done.isCompleted) {
      done.complete();
    }
  }

  subscription = const SseDecoder()
      .decodeMessages(_cancellableBytes(response.stream, cancellation))
      .listen(
        (message) {
          subscription.pause();
          unawaited(() async {
            try {
              if (done.isCompleted ||
                  sink.terminated ||
                  cancellation.isCancelled) {
                finish();
                return;
              }
              await onMessage(message, sink);
              if (sink.terminated || cancellation.isCancelled) {
                finish();
                return;
              }
              subscription.resume();
            } on Object catch (error, stackTrace) {
              if (!done.isCompleted) {
                done.completeError(error, stackTrace);
              }
            }
          }());
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!done.isCompleted) {
            done.completeError(error, stackTrace);
          }
        },
        onDone: finish,
        cancelOnError: false,
      );
  final registration = cancellation.register(() {
    unawaited(subscription.cancel());
    finish();
  });
  try {
    await done.future;
  } finally {
    registration.dispose();
    await subscription.cancel();
  }
}

Stream<List<int>> _cancellableBytes(
  Stream<List<int>> source,
  CancellationToken cancellation,
) {
  late StreamController<List<int>> controller;
  StreamSubscription<List<int>>? subscription;
  CancellationRegistration? registration;
  controller = StreamController<List<int>>(
    onListen: () {
      subscription = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          if (!controller.isClosed) {
            unawaited(controller.close());
          }
        },
      );
      registration = cancellation.register(() {
        unawaited(subscription?.cancel());
        if (!controller.isClosed) {
          unawaited(controller.close());
        }
      });
    },
    onCancel: () async {
      registration?.dispose();
      await subscription?.cancel();
    },
  );
  return controller.stream;
}

Map<String, Object?> decodeSseJsonObject(String data, ProviderId providerId) {
  final payload = jsonDecode(data);
  final object = asJsonObject(payload);
  if (object == null) {
    throwLlm(
      LlmErrorKind.protocol,
      'Провайдер ${providerId.value} вернул поток в неожиданном формате.',
    );
  }
  return object;
}

Future<T?> raceCancellation<T>(
  Future<T> future, {
  required CancellationToken cancellation,
  CancellationToken? also,
}) async {
  bool isCancelled() =>
      cancellation.isCancelled || (also?.isCancelled ?? false);
  if (isCancelled()) {
    return null;
  }
  final completer = Completer<T?>();
  var settled = false;

  void completeValue(T? value) {
    if (settled || completer.isCompleted) {
      return;
    }
    settled = true;
    completer.complete(value);
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (settled || completer.isCompleted) {
      return;
    }
    settled = true;
    completer.completeError(error, stackTrace);
  }

  unawaited(
    future.then(
      (value) {
        completeValue(isCancelled() ? null : value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (isCancelled()) {
          completeValue(null);
        } else {
          completeError(error, stackTrace);
        }
      },
    ),
  );
  final registrations = <CancellationRegistration>[
    cancellation.register(() => completeValue(null)),
  ];
  if (also != null) {
    registrations.add(also.register(() => completeValue(null)));
  }
  try {
    return await completer.future;
  } finally {
    for (final registration in registrations) {
      registration.dispose();
    }
  }
}

int? readNonNegativeInt(Object? value, {String field = 'integer'}) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    if (value < 0) {
      throwLlm(
        LlmErrorKind.protocol,
        'Expected a non-negative integer for $field.',
      );
    }
    return value;
  }
  throwLlm(
    LlmErrorKind.protocol,
    'Expected a non-negative integer for $field.',
  );
}

Future<void> _release(http.StreamedResponse response) async {
  try {
    await response.stream.listen((_) {}).cancel();
  } on Object {
    // The subscription may already be cancelled by abort.
  }
}

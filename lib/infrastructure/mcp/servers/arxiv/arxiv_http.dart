import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'arxiv_errors.dart';

/// One HTTP response of the arXiv API, bounded by the adapter.
final class ArxivHttpResponse {
  const ArxivHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;

  /// Response headers; `package:http` lower-cases them already.
  final Map<String, String> headers;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Case-insensitive header lookup that works with fake adapters too.
  String? header(String name) => headers[name] ?? headers[name.toLowerCase()];
}

/// Injectable HTTP transport of the official arXiv API.
///
/// The `arxiv` server never talks to the network itself: tests inject a fake
/// adapter with controlled Atom fixtures, and B9 passes the application HTTP
/// client through [HttpArxivHttpAdapter]. Implementations may throw
/// [ArxivFailure] to report a transport-level problem; other errors are
/// mapped by the client.
abstract interface class ArxivHttpAdapter {
  Future<ArxivHttpResponse> get(Uri url, {required Duration timeout});
}

/// Default [ArxivHttpAdapter] built on `package:http`.
///
/// Safety properties:
/// - the body is read as a byte stream and rejected past [maxResponseBytes],
///   so a hostile or broken response cannot exhaust memory;
/// - redirects are not followed, because the arXiv query endpoint never
///   redirects and an injected Authorization-free GET must not silently move
///   to another host;
/// - invalid UTF-8 is a protocol failure instead of a replacement-character
///   soup;
/// - the request carries `Abortable.abortTrigger` (`package:http` 1.6), so
///   the deadline aborts the request instead of only abandoning its future;
///   the adapter then waits for the transport to settle (aborted) before it
///   reports the timeout, which keeps the caller's single-request queue from
///   being released while a socket is demonstrably still pending;
/// - [settleTimeout] bounds that post-abort wait for injected clients that
///   ignore `abortTrigger`: after it elapses the timeout is reported even
///   though the connection could not be confirmed as settled;
/// - no PDF link is ever requested: only the injected query URL is fetched.
final class HttpArxivHttpAdapter implements ArxivHttpAdapter {
  HttpArxivHttpAdapter({
    http.Client? client,
    this.maxResponseBytes = 2 * 1024 * 1024,
    this.settleTimeout = const Duration(seconds: 5),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const _accept =
      'application/atom+xml, application/xml;q=0.9, text/xml;q=0.8';

  final http.Client _client;
  final bool _ownsClient;
  final int maxResponseBytes;

  /// Extra time allowed for a timed-out transport to settle before the
  /// timeout is reported. It is observable only for clients that do not honor
  /// `Abortable.abortTrigger`; clients that do settle immediately on abort.
  final Duration settleTimeout;

  @override
  Future<ArxivHttpResponse> get(Uri url, {required Duration timeout}) async {
    final abort = Completer<void>();
    final deadline = Completer<void>();
    final timer = Timer(timeout, () {
      if (!deadline.isCompleted) {
        deadline.complete();
      }
      if (!abort.isCompleted) {
        abort.complete();
      }
    });
    Future<Object?>? pending;
    try {
      final request =
          http.AbortableRequest('GET', url, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['accept'] = _accept;
      final sendFuture = _client.send(request);
      pending = sendFuture;
      final response = await _race(deadline.future, sendFuture);
      final bodyFuture = _readBody(response);
      pending = bodyFuture;
      final body = await _race(deadline.future, bodyFuture);
      return ArxivHttpResponse(
        statusCode: response.statusCode,
        body: body,
        headers: response.headers,
      );
    } on _DeadlineExceeded {
      await _settle(pending);
      throwArxiv(
        ArxivFailureKind.timeout,
        'arXiv не ответил за ${timeout.inSeconds} с.',
      );
    } on ArxivFailure {
      rethrow;
    } on http.RequestAbortedException {
      // The abort trigger belongs to this adapter, so an aborted request can
      // only mean that the deadline fired.
      throwArxiv(
        ArxivFailureKind.timeout,
        'arXiv не ответил за ${timeout.inSeconds} с.',
      );
    } on http.ClientException {
      throwArxiv(ArxivFailureKind.network, 'Не удалось подключиться к arXiv.');
    } on FormatException {
      throwArxiv(
        ArxivFailureKind.protocol,
        'Ответ arXiv не является текстом UTF-8.',
      );
    } finally {
      timer.cancel();
    }
  }

  /// Completes with [operation]'s result, or with [_DeadlineExceeded] as soon
  /// as [deadline] completes.
  Future<T> _race<T>(Future<void> deadline, Future<T> operation) {
    final completer = Completer<T>();
    operation.then(
      (value) {
        if (!completer.isCompleted) {
          completer.complete(value);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    deadline.whenComplete(() {
      if (!completer.isCompleted) {
        completer.completeError(const _DeadlineExceeded());
      }
    });
    return completer.future;
  }

  Future<String> _readBody(http.StreamedResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
      if (bytes.length > maxResponseBytes) {
        throwArxiv(
          ArxivFailureKind.protocol,
          'Ответ arXiv превысил $maxResponseBytes байт.',
        );
      }
    }
    return utf8.decode(bytes, allowMalformed: false);
  }

  /// Waits, bounded by [settleTimeout], for a timed-out operation to settle.
  ///
  /// A client that honors the abort trigger settles almost immediately with
  /// the abort error; a client that ignores it may never settle, in which
  /// case the bound keeps the queue from blocking forever.
  Future<void> _settle(Future<Object?>? pending) async {
    if (pending == null) {
      return;
    }
    try {
      await pending.timeout(settleTimeout);
    } on Object {
      // Settled with an error (the expected abort) or the bound elapsed; the
      // timeout failure below is authoritative either way.
    }
  }

  /// Closes the HTTP client when this adapter created it.
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

final class _DeadlineExceeded implements Exception {
  const _DeadlineExceeded();
}

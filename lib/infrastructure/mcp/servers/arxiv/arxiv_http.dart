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
/// - no PDF link is ever requested: only the injected query URL is fetched.
final class HttpArxivHttpAdapter implements ArxivHttpAdapter {
  HttpArxivHttpAdapter({
    http.Client? client,
    this.maxResponseBytes = 2 * 1024 * 1024,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const _accept =
      'application/atom+xml, application/xml;q=0.9, text/xml;q=0.8';

  final http.Client _client;
  final bool _ownsClient;
  final int maxResponseBytes;

  @override
  Future<ArxivHttpResponse> get(Uri url, {required Duration timeout}) async {
    try {
      final request = http.Request('GET', url)
        ..followRedirects = false
        ..headers['accept'] = _accept;
      final response = await _client.send(request).timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxResponseBytes) {
          throwArxiv(
            ArxivFailureKind.protocol,
            'Ответ arXiv превысил $maxResponseBytes байт.',
          );
        }
      }
      final body = utf8.decode(bytes, allowMalformed: false);
      return ArxivHttpResponse(
        statusCode: response.statusCode,
        body: body,
        headers: response.headers,
      );
    } on ArxivFailure {
      rethrow;
    } on TimeoutException {
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
    }
  }

  /// Closes the HTTP client when this adapter created it.
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

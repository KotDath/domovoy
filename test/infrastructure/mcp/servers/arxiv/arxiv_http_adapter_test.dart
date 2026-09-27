import 'dart:async';
import 'dart:convert';

import 'package:domovoy/infrastructure/mcp/servers/arxiv/arxiv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final url = Uri.parse('https://export.arxiv.org/api/query');

  group('HttpArxivHttpAdapter', () {
    test('returns the bounded body, status and headers', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.headers['accept'], contains('application/atom+xml'));
        return http.Response(
          'atom body',
          200,
          headers: <String, String>{'retry-after': '3'},
        );
      });
      final adapter = HttpArxivHttpAdapter(client: client);

      final response = await adapter.get(
        url,
        timeout: const Duration(seconds: 5),
      );

      expect(response.statusCode, 200);
      expect(response.body, 'atom body');
      expect(response.isSuccess, isTrue);
      expect(response.header('Retry-After'), '3');
    });

    test(
      'rejects a body over maxResponseBytes as a protocol failure',
      () async {
        final adapter = HttpArxivHttpAdapter(
          client: MockClient(
            (request) async => http.Response('0123456789', 200),
          ),
          maxResponseBytes: 4,
        );

        await expectLater(
          adapter.get(url, timeout: const Duration(seconds: 5)),
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.protocol,
            ),
          ),
        );
      },
    );

    test('rejects invalid UTF-8 as a protocol failure', () async {
      final adapter = HttpArxivHttpAdapter(
        client: MockClient(
          (request) async => http.Response.bytes(<int>[0xFF, 0xFE, 0xFD], 200),
        ),
      );

      await expectLater(
        adapter.get(url, timeout: const Duration(seconds: 5)),
        throwsA(
          isA<ArxivFailure>().having(
            (failure) => failure.kind,
            'kind',
            ArxivFailureKind.protocol,
          ),
        ),
      );
    });

    test('returns redirects instead of following them', () async {
      final adapter = HttpArxivHttpAdapter(
        client: MockClient(
          (request) async => http.Response(
            'moved',
            302,
            headers: <String, String>{
              'location': 'https://evil.example/collect',
            },
          ),
        ),
      );

      final response = await adapter.get(
        url,
        timeout: const Duration(seconds: 5),
      );
      expect(response.statusCode, 302);
      expect(response.isSuccess, isFalse);
    });

    test('maps a client failure to a network failure', () async {
      final adapter = HttpArxivHttpAdapter(
        client: MockClient(
          (request) async => throw http.ClientException('offline'),
        ),
      );

      await expectLater(
        adapter.get(url, timeout: const Duration(seconds: 5)),
        throwsA(
          isA<ArxivFailure>().having(
            (failure) => failure.kind,
            'kind',
            ArxivFailureKind.network,
          ),
        ),
      );
    });

    test('maps an unanswered request to a timeout failure', () async {
      final adapter = HttpArxivHttpAdapter(
        client: MockClient(
          (request) => Future<http.Response>.delayed(
            const Duration(milliseconds: 200),
            () => http.Response('late', 200),
          ),
        ),
      );

      await expectLater(
        adapter.get(url, timeout: const Duration(milliseconds: 20)),
        throwsA(
          isA<ArxivFailure>().having(
            (failure) => failure.kind,
            'kind',
            ArxivFailureKind.timeout,
          ),
        ),
      );
    });

    test(
      'aborts an abortable transport at the deadline and waits for it',
      () async {
        final transport = _AbortableTransport();
        final adapter = HttpArxivHttpAdapter(client: transport);

        await expectLater(
          adapter.get(url, timeout: const Duration(milliseconds: 20)),
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.timeout,
            ),
          ),
        );

        expect(transport.abortObserved, isTrue);
        expect(transport.settled, isTrue);
      },
    );

    test(
      'waits for a transport that ignores abort to settle before timing out',
      () async {
        var transportSettled = false;
        var completedAfterTransportSettled = false;
        final transport = _ControlledTransport((request) async {
          expect(request, isA<http.Abortable>());
          await Future<void>.delayed(const Duration(milliseconds: 40));
          transportSettled = true;
          return _streamedResponse('late body');
        });
        final adapter = HttpArxivHttpAdapter(
          client: transport,
          settleTimeout: const Duration(seconds: 5),
        );

        final future = adapter.get(
          url,
          timeout: const Duration(milliseconds: 10),
        );
        unawaited(
          future.then<void>(
            (_) {},
            onError: (Object _) {
              completedAfterTransportSettled = transportSettled;
            },
          ),
        );

        await expectLater(
          future,
          throwsA(
            isA<ArxivFailure>().having(
              (failure) => failure.kind,
              'kind',
              ArxivFailureKind.timeout,
            ),
          ),
        );
        expect(transportSettled, isTrue);
        expect(completedAfterTransportSettled, isTrue);
      },
    );

    test('does not block forever when the transport never settles', () async {
      final transport = _ControlledTransport(
        (request) => Completer<http.StreamedResponse>().future,
      );
      final adapter = HttpArxivHttpAdapter(
        client: transport,
        settleTimeout: const Duration(milliseconds: 60),
      );

      var completed = false;
      final future = adapter.get(
        url,
        timeout: const Duration(milliseconds: 20),
      );
      unawaited(
        future.then<void>(
          (_) {},
          onError: (Object _) {
            completed = true;
          },
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        completed,
        isFalse,
        reason: 'the queue must stay held past the request deadline',
      );

      await expectLater(
        future,
        throwsA(
          isA<ArxivFailure>().having(
            (failure) => failure.kind,
            'kind',
            ArxivFailureKind.timeout,
          ),
        ),
      );
      expect(completed, isTrue);
    });
  });
}

/// Controlled `http.Client` for the transport-settlement tests.
final class _ControlledTransport extends http.BaseClient {
  _ControlledTransport(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _handler(request);
}

/// Transport that honors `Abortable.abortTrigger` like `IOClient` does.
final class _AbortableTransport extends http.BaseClient {
  bool abortObserved = false;
  bool settled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final abortable = request as http.Abortable;
    final trigger = abortable.abortTrigger;
    if (trigger == null) {
      throw StateError('adapter must send an AbortableRequest with a trigger');
    }
    final completer = Completer<http.StreamedResponse>();
    unawaited(
      trigger.then<void>((_) {
        abortObserved = true;
        completer.completeError(http.RequestAbortedException(request.url));
      }),
    );
    unawaited(
      completer.future.then<void>(
        (_) {
          settled = true;
        },
        onError: (Object _) {
          settled = true;
        },
      ),
    );
    return completer.future;
  }
}

http.StreamedResponse _streamedResponse(String body, {int statusCode = 200}) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    http.ByteStream.fromBytes(bytes),
    statusCode,
    contentLength: bytes.length,
    headers: const <String, String>{},
    request: http.AbortableRequest('GET', Uri.parse('https://example.com/')),
  );
}

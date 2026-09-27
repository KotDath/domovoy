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
  });
}

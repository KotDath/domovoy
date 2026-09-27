import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/servers/arxiv/arxiv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'arxiv_test_support.dart';

void main() {
  late FakeArxivClock clock;

  setUp(() {
    clock = FakeArxivClock();
  });

  group('ArxivMcpServerFactory', () {
    test('exposes a stable local server contract', () {
      final factory = ArxivMcpServerFactory(
        httpAdapter: FakeArxivHttpAdapter(clock: clock),
        clock: clock,
      );
      final definition = factory.create();

      expect(definition.id, 'arxiv');
      expect(definition.serverId, McpConnectionId('arxiv'));
      expect(definition.displayName, 'arXiv');
      expect(definition.version, '1.0.0');
      expect(definition.instructions, isNotNull);
      expect(factory.create().id, 'arxiv');
    });
  });

  group('arxiv tools', () {
    test('advertise strict schemas and annotations', () async {
      final harness = await _Harness.start(clock, <ArxivHttpResponse>[
        atomResponse(atomFeed(entries: <String>[atomEntry()])),
      ]);
      addTearDown(harness.close);

      final page = await harness.listTools();
      expect(page.map((tool) => tool.originalName).toSet(), <String>{
        'search_papers',
        'get_paper',
      });

      final search = page.firstWhere(
        (tool) => tool.originalName == 'search_papers',
      );
      expect(search.title, isNotEmpty);
      expect(search.description, isNotEmpty);
      expect(search.inputSchema['type'], 'object');
      expect(search.inputSchema['required'], <String>['query']);
      expect(search.inputSchema['additionalProperties'], isFalse);
      final searchProperties =
          search.inputSchema['properties']! as Map<String, Object?>;
      final limit = searchProperties['limit']! as Map<String, Object?>;
      expect(limit['minimum'], 1);
      expect(limit['maximum'], 30);
      expect(limit['type'], 'integer');
      final sortBy = searchProperties['sortBy']! as Map<String, Object?>;
      expect(sortBy['enum'], <String>[
        'relevance',
        'lastUpdatedDate',
        'submittedDate',
      ]);
      expect(search.outputSchema, isNotNull);
      expect(search.annotations?['readOnlyHint'], isTrue);
      expect(search.annotations?['openWorldHint'], isTrue);

      final get = page.firstWhere((tool) => tool.originalName == 'get_paper');
      expect(get.inputSchema['required'], <String>['arxivId']);
      expect(get.inputSchema['additionalProperties'], isFalse);
      expect(get.outputSchema, isNotNull);
    });

    test(
      'search_papers returns Paper v1 structuredContent and short text',
      () async {
        final harness = await _Harness.start(clock, <ArxivHttpResponse>[
          atomResponse(
            atomFeed(totalResults: '1', entries: <String>[atomEntry()]),
          ),
        ]);
        addTearDown(harness.close);

        final result = await harness.call('search_papers', <String, Object?>{
          'query': 'electron',
        });

        expect(result.isError, isFalse);
        final structured = result.structuredContent! as Map<String, Object?>;
        expect(structured['count'], 1);
        expect(structured['truncated'], isFalse);
        expect(structured['totalResults'], 1);
        final papers = structured['papers']! as List<Object?>;
        expect(papers, <Object?>[paperFixture().toJson()]);
        expect(result.textContent, contains('2501.01234v1'));
        expect(result.textContent, isNot(contains('Example abstract')));
      },
    );

    test('get_paper returns one normalized Paper', () async {
      final harness = await _Harness.start(clock, <ArxivHttpResponse>[
        atomResponse(atomFeed(entries: <String>[atomEntry()])),
      ]);
      addTearDown(harness.close);

      final result = await harness.call('get_paper', <String, Object?>{
        'arxivId': '2501.01234v1',
      });

      expect(result.isError, isFalse);
      expect(result.structuredContent, paperFixture().toJson());
      expect(result.textContent, contains('Example title'));
    });

    test('advertised output schemas accept the real results', () async {
      final harness = await _Harness.start(clock, <ArxivHttpResponse>[
        atomResponse(atomFeed(entries: <String>[atomEntry()])),
        atomResponse(atomFeed(entries: <String>[atomEntry()])),
      ]);
      addTearDown(harness.close);

      final page = await harness.listTools();
      final search = page.firstWhere(
        (tool) => tool.originalName == 'search_papers',
      );
      final get = page.firstWhere((tool) => tool.originalName == 'get_paper');

      final searchResult = await harness.call(
        'search_papers',
        <String, Object?>{'query': 'electron'},
      );
      expect(searchResult.isError, isFalse);
      expect(
        firstToolSchemaValueProblem(
          search.outputSchema!,
          searchResult.structuredContent,
        ),
        isNull,
      );

      final getResult = await harness.call('get_paper', <String, Object?>{
        'arxivId': '2501.01234',
      });
      expect(getResult.isError, isFalse);
      expect(
        firstToolSchemaValueProblem(
          get.outputSchema!,
          getResult.structuredContent,
        ),
        isNull,
      );
    });

    test('invalid arguments produce isError results, not exceptions', () async {
      final harness = await _Harness.start(clock, <ArxivHttpResponse>[]);
      addTearDown(harness.close);

      for (final arguments in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{'query': ''},
        <String, Object?>{'query': 'electron', 'limit': 31},
        <String, Object?>{'query': 'electron', 'unknown': 1},
        <String, Object?>{'arxivId': 'https://arxiv.org/abs/2501.01234'},
      ]) {
        final result = await harness.call(
          arguments.containsKey('arxivId') ? 'get_paper' : 'search_papers',
          arguments,
        );
        expect(result.isError, isTrue, reason: '$arguments');
        expect(result.textContent, isNotEmpty, reason: '$arguments');
      }
      expect(harness.adapter.requests, isEmpty);
    });

    test(
      'domain failures stay distinguishable from transport failures',
      () async {
        await _expectKind(
          responses: <ArxivHttpResponse>[atomResponse(atomFeed())],
          tool: 'get_paper',
          arguments: <String, Object?>{'arxivId': '2501.99999'},
          kind: 'not_found',
        );
        await _expectKind(
          responses: <ArxivHttpResponse>[
            atomResponse(
              'slow down',
              statusCode: 429,
              headers: <String, String>{'retry-after': '5'},
            ),
          ],
          tool: 'search_papers',
          arguments: <String, Object?>{'query': 'electron'},
          kind: 'rate_limited',
        );
        await _expectKind(
          responses: <ArxivHttpResponse>[atomResponse('<feed><entry></feed>')],
          tool: 'search_papers',
          arguments: <String, Object?>{'query': 'electron'},
          kind: 'protocol',
        );
        await _expectKind(
          responses: <ArxivHttpResponse>[atomResponse('boom', statusCode: 500)],
          tool: 'search_papers',
          arguments: <String, Object?>{'query': 'electron'},
          kind: 'network',
        );
      },
    );

    test('a hanging arXiv request is reported as a timeout', () async {
      final pending = Completer<ArxivHttpResponse>();
      final adapter = FakeArxivHttpAdapter(
        clock: clock,
        responder: (url, index) => pending.future,
      );
      final harness = await _Harness.startWithAdapter(
        clock,
        adapter,
        requestTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(harness.close);

      final result = await harness.call('search_papers', <String, Object?>{
        'query': 'electron',
      });

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[arxiv:timeout]'));
    });
  });
}

Future<void> _expectKind({
  required List<ArxivHttpResponse> responses,
  required String tool,
  required Map<String, Object?> arguments,
  required String kind,
}) async {
  final clock = FakeArxivClock();
  final harness = await _Harness.start(clock, responses);
  try {
    final result = await harness.call(tool, arguments);
    expect(result.isError, isTrue, reason: kind);
    expect(result.textContent, startsWith('[arxiv:$kind]'), reason: kind);
  } finally {
    await harness.close();
  }
}

final class _Harness {
  _Harness._({
    required this.host,
    required this.adapter,
    required this.connection,
    required this.token,
  });

  static Future<_Harness> start(
    FakeArxivClock clock,
    List<ArxivHttpResponse> responses,
  ) {
    return startWithAdapter(clock, adapterWithResponses(clock, responses));
  }

  static Future<_Harness> startWithAdapter(
    FakeArxivClock clock,
    FakeArxivHttpAdapter adapter, {
    Duration requestTimeout = const Duration(seconds: 15),
  }) async {
    final secrets = RuntimeMcpSecretResolver();
    final diagnostics = MemoryMcpDiagnosticsSink();
    final factory = ArxivMcpServerFactory(
      httpAdapter: adapter,
      clock: clock,
      requestTimeout: requestTimeout,
    );
    final host = LocalMcpServerHost(
      preference: McpLocalTransportPreference.stream,
      runtimeSecrets: secrets,
      diagnostics: diagnostics,
    );
    host.register(factory);
    await host.start(arxivServerId);
    final transportFactory = McpSdkTransportFactory(
      streams: host,
      diagnostics: diagnostics,
    );
    final connection =
        await transportFactory.create(
              host.connectionConfig(arxivServerId),
              secrets: secrets,
            )
            as McpSdkConnection;
    final cancellation = CancellationSource();
    final harness = _Harness._(
      host: host,
      adapter: adapter,
      connection: connection,
      token: cancellation.token,
    );
    await connection.connect(
      timeout: const Duration(seconds: 10),
      cancellation: cancellation.token,
    );
    return harness;
  }

  final LocalMcpServerHost host;
  final FakeArxivHttpAdapter adapter;
  final McpSdkConnection connection;
  final CancellationToken token;

  Future<List<McpToolDescriptor>> listTools() async {
    final page = await connection.listTools(
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
    return page.tools;
  }

  Future<McpToolCallResult> call(String tool, Map<String, Object?> arguments) {
    return connection.callTool(
      originalToolName: tool,
      arguments: arguments,
      timeout: const Duration(seconds: 10),
      cancellation: token,
    );
  }

  Future<void> close() async {
    await connection.close();
    await host.stopAll();
  }
}

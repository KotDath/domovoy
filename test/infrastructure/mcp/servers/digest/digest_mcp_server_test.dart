import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/mcp/servers/digest/digest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'digest_test_support.dart';

void main() {
  late FakeDigestClock clock;

  setUp(() {
    clock = FakeDigestClock();
  });

  group('DigestMcpServerFactory', () {
    test('exposes a stable local server contract', () {
      final factory = DigestMcpServerFactory(
        registry: digestRegistryWith(digestProvider()),
        pins: const UnavailableDigestModelPinResolver(),
        clock: clock,
      );
      final definition = factory.create();

      expect(definition.id, digestServerId);
      expect(definition.serverId, McpConnectionId('digest'));
      expect(definition.displayName, 'Digest');
      expect(definition.version, '1.0.0');
      expect(definition.instructions, isNotNull);
      expect(factory.create().id, 'digest');
    });

    test('rejects an invalid limit configuration synchronously', () {
      expect(
        () => DigestMcpServerFactory(
          registry: digestRegistryWith(digestProvider()),
          pins: const UnavailableDigestModelPinResolver(),
          limits: const DigestLimits(minPapers: 5, maxPapers: 2),
        ),
        throwsA(isA<McpException>()),
      );
    });
  });

  group('summarize_papers schema and result', () {
    test('advertises strict input/output schemas and annotations', () async {
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(digestProvider()),
        provider: digestProvider(),
        pins: const UnavailableDigestModelPinResolver(),
        clock: clock,
      );
      addTearDown(harness.close);

      final page = await harness.listTools();
      expect(page.map((tool) => tool.originalName), <String>[
        digestSummarizeToolName,
      ]);
      final tool = harness.tool(page, digestSummarizeToolName);
      expect(tool.title, isNotEmpty);
      expect(tool.description, contains('Digest v1'));
      expect(tool.inputSchema['type'], 'object');
      expect(tool.inputSchema['additionalProperties'], isFalse);
      expect(tool.inputSchema['required'], <String>['topic', 'papers']);
      final properties =
          tool.inputSchema['properties']! as Map<String, Object?>;
      final papers = properties['papers']! as Map<String, Object?>;
      expect(papers['type'], 'array');
      expect(papers['minItems'], 1);
      expect(papers['maxItems'], 10);

      final output = tool.outputSchema!;
      expect(output['type'], 'object');
      expect(output['additionalProperties'], isFalse);
      expect(
        output['required'],
        containsAll(<String>[
          'schemaVersion',
          'topic',
          'sourceScope',
          'overview',
          'items',
          'generatedAt',
        ]),
      );
      final outputProperties = output['properties']! as Map<String, Object?>;
      final scope = outputProperties['sourceScope']! as Map<String, Object?>;
      expect(scope['enum'], <String>['abstract']);
      final generatedAt =
          outputProperties['generatedAt']! as Map<String, Object?>;
      expect(generatedAt['format'], 'date-time');

      expect(tool.annotations?['readOnlyHint'], isTrue);
      expect(tool.annotations?['destructiveHint'], isFalse);
      expect(tool.annotations?['openWorldHint'], isTrue);
    });

    test('input and output schemas pass the B2 provider profiles', () async {
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(digestProvider()),
        provider: digestProvider(),
        pins: const UnavailableDigestModelPinResolver(),
        clock: clock,
      );
      addTearDown(harness.close);

      final tool = harness.tool(
        await harness.listTools(),
        digestSummarizeToolName,
      );
      for (final profile in <ToolSchemaProfile>[
        ToolSchemaProfile.openaiChatCompletions,
        ToolSchemaProfile.openaiResponses,
        ToolSchemaProfile.portable,
      ]) {
        expect(
          toolSchemaProblem(tool.inputSchema, profile: profile),
          isNull,
          reason: 'input schema for ${profile.id}',
        );
        expect(
          toolSchemaProblem(tool.outputSchema!, profile: profile),
          isNull,
          reason: 'output schema for ${profile.id}',
        );
        expect(
          representToolSchema(tool.inputSchema, profile: profile).isRepresented,
          isTrue,
          reason: 'input schema is representable for ${profile.id}',
        );
        expect(
          representToolSchema(
            tool.outputSchema!,
            profile: profile,
          ).isRepresented,
          isTrue,
          reason: 'output schema is representable for ${profile.id}',
        );
      }
    });

    test(
      'returns Digest v1 structuredContent and a brief abstract note',
      () async {
        final provider = digestProvider()
          ..script(
            digestModelAId,
            digestTurn(
              digestAnswerJson(
                items: <Map<String, Object?>>[digestAnswerItem('2501.01234')],
              ),
            ),
          );
        final harness = await DigestHarness.start(
          registry: digestRegistryWith(provider),
          provider: provider,
          pins: QueueDigestPinResolver(<DigestModelPin?>[
            DigestModelPin(model: digestModelA),
          ]),
          clock: clock,
        );
        addTearDown(harness.close);

        final result = await harness.call(
          digestSummarizeToolName,
          arguments: <String, Object?>{
            'topic': 'Research topic',
            'papers': <Object?>[digestPaper().toJson()],
          },
        );

        expect(result.isError, isFalse);
        final digest = Digest.fromJson(result.structuredContent);
        expect(digest.topic, 'Research topic');
        expect(digest.overview, 'Short synthesis');
        expect(digest.sourceScope, digestSourceScopeAbstract);
        expect(digest.generatedAt, clock.nowUtc());
        expect(digest.items.single.arxivId.value, '2501.01234');
        expect(result.textContent, contains('только по переданным аннотациям'));
        expect(result.textContent, contains('$digestModelA'));
        expect(result.textContent, contains('2501.01234'));
        expect(provider.requests, hasLength(1));
      },
    );

    test('a two-paper result satisfies the advertised output schema', () async {
      final provider = digestProvider()
        ..script(
          digestModelAId,
          digestTurn(
            digestAnswerJson(
              items: <Map<String, Object?>>[
                digestAnswerItem('2501.01234'),
                digestAnswerItem('2501.99999'),
              ],
            ),
          ),
        );
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: QueueDigestPinResolver(<DigestModelPin?>[
          DigestModelPin(model: digestModelA),
        ]),
        clock: clock,
      );
      addTearDown(harness.close);

      final tool = harness.tool(
        await harness.listTools(),
        digestSummarizeToolName,
      );
      final result = await harness.call(
        digestSummarizeToolName,
        arguments: <String, Object?>{
          'topic': 'Research topic',
          'papers': <Object?>[
            digestPaper().toJson(),
            digestPaper(arxivId: '2501.99999').toJson(),
          ],
        },
      );

      expect(result.isError, isFalse);
      expect(
        firstToolSchemaValueProblem(
          tool.outputSchema!,
          result.structuredContent,
        ),
        isNull,
      );
      final digest = Digest.fromJson(result.structuredContent);
      expect(digest.items.map((item) => item.arxivId.value), <String>[
        '2501.01234',
        '2501.99999',
      ]);
    });
  });

  group('summarize_papers failures', () {
    test('fails with model_unavailable when no pin is registered', () async {
      final provider = digestProvider();
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: const UnavailableDigestModelPinResolver(),
        clock: clock,
      );
      addTearDown(harness.close);

      final result = await harness.call(
        digestSummarizeToolName,
        arguments: <String, Object?>{
          'topic': 'Research topic',
          'papers': <Object?>[digestPaper().toJson()],
        },
      );

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[digest:model_unavailable]'));
      expect(result.structuredContent, isNull);
      expect(provider.requests, isEmpty);
    });

    test('rejects an incomplete Paper before any provider work', () async {
      final provider = digestProvider();
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: QueueDigestPinResolver(<DigestModelPin?>[
          DigestModelPin(model: digestModelA),
        ]),
        clock: clock,
      );
      addTearDown(harness.close);

      // The MCP layer validates the advertised input schema before the
      // handler runs; the server-side Paper check stays as defense in depth
      // for a transport that does not validate.
      final incomplete = digestPaper().toJson()..remove('abstract');
      final result = await harness.call(
        digestSummarizeToolName,
        arguments: <String, Object?>{
          'topic': 'Research topic',
          'papers': <Object?>[incomplete],
        },
      );

      expect(result.isError, isTrue);
      expect(result.textContent, contains('abstract'));
      expect(result.structuredContent, isNull);
      expect(provider.requests, isEmpty);
    });

    test('rejects an invalid Paper field before any provider work', () async {
      final provider = digestProvider();
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: QueueDigestPinResolver(<DigestModelPin?>[
          DigestModelPin(model: digestModelA),
        ]),
        clock: clock,
      );
      addTearDown(harness.close);

      final invalid = digestPaper().toJson()..['publishedAt'] = 'not-a-date';
      final result = await harness.call(
        digestSummarizeToolName,
        arguments: <String, Object?>{
          'topic': 'Research topic',
          'papers': <Object?>[invalid],
        },
      );

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[digest:invalid_input]'));
      expect(result.structuredContent, isNull);
      expect(provider.requests, isEmpty);
    });

    test('rejects unknown arguments', () async {
      final provider = digestProvider();
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: QueueDigestPinResolver(<DigestModelPin?>[
          DigestModelPin(model: digestModelA),
        ]),
        clock: clock,
      );
      addTearDown(harness.close);

      final result = await harness.call(
        digestSummarizeToolName,
        arguments: <String, Object?>{
          'topic': 'Research topic',
          'papers': <Object?>[digestPaper().toJson()],
          'modelRef': 'attacker/chosen-model',
        },
      );

      expect(result.isError, isTrue);
      expect(result.textContent, contains('modelRef'));
      expect(provider.requests, isEmpty);
    });

    test('rejects a response that references an outside paper', () async {
      final provider = digestProvider()
        ..script(
          digestModelAId,
          digestTurn(
            digestAnswerJson(
              items: <Map<String, Object?>>[digestAnswerItem('2501.99999')],
            ),
          ),
        );
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: QueueDigestPinResolver(<DigestModelPin?>[
          DigestModelPin(model: digestModelA),
        ]),
        clock: clock,
      );
      addTearDown(harness.close);

      final result = await harness.call(
        digestSummarizeToolName,
        arguments: <String, Object?>{
          'topic': 'Research topic',
          'papers': <Object?>[digestPaper().toJson()],
        },
      );

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[digest:model_response]'));
      expect(result.structuredContent, isNull);
    });

    test('reports provider failures as isError results', () async {
      final provider = digestProvider()
        ..script(digestModelAId, <LlmEvent>[
          LlmFailed(
            LlmError(
              kind: LlmErrorKind.rateLimit,
              message: 'Too many requests.',
            ),
          ),
        ]);
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: QueueDigestPinResolver(<DigestModelPin?>[
          DigestModelPin(model: digestModelA),
        ]),
        clock: clock,
      );
      addTearDown(harness.close);

      final result = await harness.call(
        digestSummarizeToolName,
        arguments: <String, Object?>{
          'topic': 'Research topic',
          'papers': <Object?>[digestPaper().toJson()],
        },
      );

      expect(result.isError, isTrue);
      expect(result.textContent, startsWith('[digest:provider]'));
      expect(result.structuredContent, isNull);
    });

    test('cancelling the client call aborts the provider turn', () async {
      final provider = digestProvider()..gate(digestModelAId);
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: QueueDigestPinResolver(<DigestModelPin?>[
          DigestModelPin(model: digestModelA),
        ]),
        clock: clock,
      );
      addTearDown(harness.close);
      final cancellation = CancellationSource();
      final future = harness.call(
        digestSummarizeToolName,
        arguments: <String, Object?>{
          'topic': 'Research topic',
          'papers': <Object?>[digestPaper().toJson()],
        },
        cancellation: cancellation.token,
      );
      await _waitFor(() => provider.requests.isNotEmpty);
      cancellation.cancel();

      try {
        final result = await future;
        expect(result.isError, isTrue);
        expect(result.textContent, contains('cancelled'));
        expect(result.structuredContent, isNull);
      } on McpException catch (error) {
        expect(error.error.kind, McpErrorKind.cancelled);
      }
      provider.release(digestModelAId);
    });
  });

  group('per-invocation model isolation', () {
    test('two concurrent calls with different pins stay isolated', () async {
      final provider = digestProvider()
        ..script(
          digestModelAId,
          digestTurn(
            digestAnswerJson(
              overview: 'OVERVIEW-A',
              items: <Map<String, Object?>>[digestAnswerItem('2501.01234')],
            ),
          ),
        )
        ..script(
          digestModelBId,
          digestTurn(
            digestAnswerJson(
              overview: 'OVERVIEW-B',
              items: <Map<String, Object?>>[digestAnswerItem('2501.01234')],
            ),
          ),
        )
        ..gate(digestModelAId)
        ..gate(digestModelBId);
      final resolver = QueueDigestPinResolver(<DigestModelPin?>[
        DigestModelPin(model: digestModelA),
        DigestModelPin(model: digestModelB),
      ]);
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: resolver,
        clock: clock,
      );
      addTearDown(harness.close);

      final arguments = <String, Object?>{
        'topic': 'Research topic',
        'papers': <Object?>[digestPaper().toJson()],
      };
      final futureA = harness.call(
        digestSummarizeToolName,
        arguments: arguments,
      );
      final futureB = harness.call(
        digestSummarizeToolName,
        arguments: arguments,
      );
      await _waitFor(() => provider.requests.length == 2);
      // Release in reverse order: a server that mixed the pins would return
      // the wrong overview for at least one call.
      provider.release(digestModelBId);
      provider.release(digestModelAId);
      final results = await Future.wait(<Future<McpToolCallResult>>[
        futureA,
        futureB,
      ]);

      expect(results[0].isError, isFalse);
      expect(results[1].isError, isFalse);
      expect(
        (results[0].structuredContent! as Map<String, Object?>)['overview'],
        'OVERVIEW-A',
      );
      expect(
        (results[1].structuredContent! as Map<String, Object?>)['overview'],
        'OVERVIEW-B',
      );
      expect(
        provider.requests.map((request) => request.model.modelId.value).toSet(),
        <String>{digestModelAId, digestModelBId},
      );
    });

    test('resolves the pin per invocation and never caches it', () async {
      final provider = digestProvider()
        ..script(
          digestModelAId,
          digestTurn(
            digestAnswerJson(
              items: <Map<String, Object?>>[digestAnswerItem('2501.01234')],
            ),
          ),
        );
      final resolver = QueueDigestPinResolver(<DigestModelPin?>[
        DigestModelPin(model: digestModelA),
        null,
      ]);
      final harness = await DigestHarness.start(
        registry: digestRegistryWith(provider),
        provider: provider,
        pins: resolver,
        clock: clock,
      );
      addTearDown(harness.close);

      final arguments = <String, Object?>{
        'topic': 'Research topic',
        'papers': <Object?>[digestPaper().toJson()],
      };
      final first = await harness.call(
        digestSummarizeToolName,
        arguments: arguments,
      );
      final second = await harness.call(
        digestSummarizeToolName,
        arguments: arguments,
      );

      expect(first.isError, isFalse);
      expect(second.isError, isTrue);
      expect(second.textContent, startsWith('[digest:model_unavailable]'));
      expect(resolver.scopes, hasLength(2));
      expect(resolver.scopes.first.requestId, isNotEmpty);
      expect(provider.requests, hasLength(1));
    });
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition was not reached');
}

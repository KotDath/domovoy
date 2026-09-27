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

  DigestSynthesizer synthesizerFor(
    ModelScriptedLlmProvider provider, {
    DigestLimits limits = const DigestLimits(),
  }) {
    return DigestSynthesizer(
      registry: digestRegistryWith(provider),
      limits: limits,
      clock: clock,
    );
  }

  DigestSynthesisRequest requestFor(
    List<Paper> papers, {
    String topic = 'Research topic',
    String? language,
    String? goal,
  }) {
    return DigestSynthesisRequest(
      topic: topic,
      papers: papers,
      language: language,
      goal: goal,
    );
  }

  group('synthesis', () {
    test(
      'produces a grounded abstract-scope digest in one provider turn',
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
        final synthesizer = synthesizerFor(provider);

        final digest = await synthesizer.synthesize(
          requestFor(<Paper>[digestPaper()]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        );

        expect(digest.topic, 'Research topic');
        expect(digest.overview, 'Short synthesis');
        expect(digest.sourceScope, digestSourceScopeAbstract);
        expect(digest.generatedAt, clock.nowUtc());
        expect(digest.items, hasLength(1));
        expect(digest.items.single.arxivId.value, '2501.01234');
        expect(
          digest.items.single.abstractUrl.toString(),
          'https://arxiv.org/abs/2501.01234',
        );
        expect(digest.items.single.finding, 'Finding for 2501.01234');
        expect(digest.items.single.limitation, 'Изучена только аннотация');

        expect(provider.requests, hasLength(1));
        final request = provider.requests.single;
        expect(request.model, digestModelA);
        expect(request.context.tools, isEmpty);
        expect(request.context.messages, hasLength(1));
        expect(request.context.systemPrompt, contains('JSON'));
        expect(
          request.generation.reasoningMode,
          ReasoningMode.disabled,
          reason: 'optional-reasoning models are asked not to reason',
        );
      },
    );

    test(
      'orders items by the supplied papers and accepts fenced JSON',
      () async {
        final provider = digestProvider()
          ..script(
            digestModelAId,
            digestTurn(
              'Вот сводка:\n```json\n'
              '${digestAnswerJson(
                overview: 'Fenced overview',
                items: <Map<String, Object?>>[
                  digestAnswerItem('2501.99999', finding: 'Second finding'),
                  digestAnswerItem('2501.01234', finding: 'First finding'),
                ],
              )}'
              '\n```\nГотово.',
            ),
          );
        final synthesizer = synthesizerFor(provider);

        final digest = await synthesizer.synthesize(
          requestFor(<Paper>[
            digestPaper(),
            digestPaper(arxivId: '2501.99999'),
          ]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        );

        expect(digest.overview, 'Fenced overview');
        expect(digest.items.map((item) => item.arxivId.value), <String>[
          '2501.01234',
          '2501.99999',
        ]);
        expect(digest.items.first.finding, 'First finding');
        expect(digest.items.last.finding, 'Second finding');
      },
    );

    test(
      'fills the server-authored limitation when the model omits it',
      () async {
        final provider = digestProvider()
          ..script(
            digestModelAId,
            digestTurn(
              digestAnswerJson(
                items: <Map<String, Object?>>[
                  digestAnswerItem('2501.01234', limitation: null),
                ],
              ),
            ),
          );
        final synthesizer = synthesizerFor(provider);

        final digest = await synthesizer.synthesize(
          requestFor(<Paper>[digestPaper()]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        );

        expect(digest.items.single.limitation, digestAbstractOnlyLimitation);
      },
    );

    test('uses the pinned model and never another catalog model', () async {
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
        );
      final synthesizer = synthesizerFor(provider);

      final digest = await synthesizer.synthesize(
        requestFor(<Paper>[digestPaper()]),
        model: digestModelB,
        cancellation: CancellationSource().token,
      );

      expect(digest.overview, 'OVERVIEW-B');
      expect(provider.requests.single.model, digestModelB);
    });

    test('sends every supplied paper into the prompt', () async {
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
      final synthesizer = synthesizerFor(provider);

      await synthesizer.synthesize(
        requestFor(
          <Paper>[
            digestPaper(abstractText: 'Abstract one'),
            digestPaper(arxivId: '2501.99999', abstractText: 'Abstract two'),
          ],
          language: 'ru',
          goal: 'Сравнить подходы',
        ),
        model: digestModelA,
        cancellation: CancellationSource().token,
      );

      final user = provider.requests.single.context.messages.single;
      final text = (user.parts.single as LlmTextPart).text;
      expect(text, contains('Abstract one'));
      expect(text, contains('Abstract two'));
      expect(text, contains('Сравнить подходы'));
      expect(text, contains('"language":"ru"'));
    });
  });

  group('model response validation', () {
    Future<DigestFailure> failureFor(
      String answer, {
      List<Paper>? papers,
      DigestLimits limits = const DigestLimits(),
      List<LlmEvent>? events,
    }) async {
      final provider = digestProvider()
        ..script(
          digestModelAId,
          events ??
              <LlmEvent>[
                LlmTextDelta(answer),
                const LlmCompleted(finishReason: LlmFinishReason.stop),
              ],
        );
      final synthesizer = synthesizerFor(provider, limits: limits);
      try {
        await synthesizer.synthesize(
          requestFor(papers ?? <Paper>[digestPaper()]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        );
      } on DigestFailure catch (failure) {
        return failure;
      }
      fail('Expected DigestFailure');
    }

    test('rejects a blank answer', () async {
      final failure = await failureFor('   ');
      expect(failure.kind, DigestFailureKind.modelResponse);
    });

    test('rejects a non-JSON answer', () async {
      final failure = await failureFor('I cannot summarize these papers.');
      expect(failure.kind, DigestFailureKind.modelResponse);
    });

    test(
      'rejects an answer that references a paper outside the input',
      () async {
        final failure = await failureFor(
          digestAnswerJson(
            items: <Map<String, Object?>>[digestAnswerItem('2501.99999')],
          ),
        );
        expect(failure.kind, DigestFailureKind.modelResponse);
        expect(failure.message, contains('2501.99999'));
      },
    );

    test('rejects a duplicated item', () async {
      final failure = await failureFor(
        digestAnswerJson(
          items: <Map<String, Object?>>[
            digestAnswerItem('2501.01234'),
            digestAnswerItem('2501.01234', finding: 'Again'),
          ],
        ),
      );
      expect(failure.kind, DigestFailureKind.modelResponse);
    });

    test('rejects an incomplete item set', () async {
      final failure = await failureFor(
        digestAnswerJson(
          items: <Map<String, Object?>>[digestAnswerItem('2501.01234')],
        ),
        papers: <Paper>[
          digestPaper(),
          digestPaper(arxivId: '2501.99999'),
        ],
      );
      expect(failure.kind, DigestFailureKind.modelResponse);
      expect(failure.message, contains('2501.99999'));
    });

    test('rejects an over-long finding', () async {
      final failure = await failureFor(
        digestAnswerJson(
          items: <Map<String, Object?>>[
            digestAnswerItem('2501.01234', finding: 'x' * 40),
          ],
        ),
        limits: const DigestLimits(maxFindingCharacters: 8),
      );
      expect(failure.kind, DigestFailureKind.modelResponse);
    });

    test('rejects an over-long overview', () async {
      final failure = await failureFor(
        digestAnswerJson(
          overview: 'x' * 40,
          items: <Map<String, Object?>>[digestAnswerItem('2501.01234')],
        ),
        limits: const DigestLimits(maxOverviewCharacters: 8),
      );
      expect(failure.kind, DigestFailureKind.modelResponse);
    });

    test('rejects a deeply nested JSON answer before decoding', () async {
      final nested = '${'[' * 80}1${']' * 80}';
      final failure = await failureFor('{"overview": $nested, "items": []}');
      expect(failure.kind, DigestFailureKind.modelResponse);
      expect(failure.message, contains('вложен'));
    });

    test('rejects a streamed answer over the output byte limit', () async {
      final failure = await failureFor(
        '',
        limits: const DigestLimits(maxOutputBytes: 32),
        events: <LlmEvent>[
          LlmTextDelta('y' * 64),
          const LlmCompleted(finishReason: LlmFinishReason.stop),
        ],
      );
      expect(failure.kind, DigestFailureKind.outputTooLarge);
    });

    test('rejects a truncated answer', () async {
      final failure = await failureFor(
        '',
        events: const <LlmEvent>[
          LlmTextDelta('{"overview": "cut'),
          LlmCompleted(finishReason: LlmFinishReason.length),
        ],
      );
      expect(failure.kind, DigestFailureKind.modelResponse);
    });

    test('rejects a tool call even though no tools were advertised', () async {
      final failure = await failureFor(
        '',
        events: <LlmEvent>[
          LlmToolCallDelta(
            callId: ToolCallId('call-1'),
            index: 0,
            name: 'search_papers',
            argumentsFragment: '{}',
          ),
          const LlmCompleted(finishReason: LlmFinishReason.toolCalls),
        ],
      );
      expect(failure.kind, DigestFailureKind.modelResponse);
    });

    test('rejects a content-filtered answer', () async {
      final failure = await failureFor(
        '',
        events: const <LlmEvent>[
          LlmTextDelta('blocked'),
          LlmCompleted(finishReason: LlmFinishReason.contentFilter),
        ],
      );
      expect(failure.kind, DigestFailureKind.provider);
    });
  });

  group('provider failures and budgets', () {
    test('reports an authentication failure as a provider error', () async {
      final provider = digestProvider()
        ..script(digestModelAId, <LlmEvent>[
          LlmFailed(
            LlmError(
              kind: LlmErrorKind.authentication,
              message: 'Invalid API key.',
            ),
          ),
        ]);
      final synthesizer = synthesizerFor(provider);

      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper()]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.provider,
          ),
        ),
      );
    });

    test('reports a stream that closes without a terminal event', () async {
      final provider = digestProvider()
        ..script(digestModelAId, const <LlmEvent>[LlmTextDelta('partial')]);
      final synthesizer = synthesizerFor(provider);

      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper()]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.provider,
          ),
        ),
      );
    });

    test('enforces the provider token budget', () async {
      final provider = digestProvider()
        ..script(
          digestModelAId,
          digestTurn(
            digestAnswerJson(
              items: <Map<String, Object?>>[digestAnswerItem('2501.01234')],
            ),
            usage: LlmUsage(inputTokens: 40000, outputTokens: 40000),
          ),
        );
      final synthesizer = synthesizerFor(
        provider,
        limits: const DigestLimits(maxTotalTokens: 1000, maxOutputTokens: 512),
      );

      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper()]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.budgetExceeded,
          ),
        ),
      );
    });

    test('times out when the model never answers', () async {
      final provider = digestProvider()..gate(digestModelAId);
      final synthesizer = synthesizerFor(
        provider,
        limits: const DigestLimits(
          invocationTimeout: Duration(milliseconds: 60),
        ),
      );
      final source = CancellationSource();

      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper()]),
          model: digestModelA,
          cancellation: source.token,
        ),
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.timeout,
          ),
        ),
      );
      provider.release(digestModelAId);
    });

    test('reports cancellation while the model is still answering', () async {
      final provider = digestProvider()..gate(digestModelAId);
      final synthesizer = synthesizerFor(provider);
      final source = CancellationSource();

      final future = synthesizer.synthesize(
        requestFor(<Paper>[digestPaper()]),
        model: digestModelA,
        cancellation: source.token,
      );
      await _waitFor(() => provider.requests.isNotEmpty);
      source.cancel();

      await expectLater(
        future,
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.cancelled,
          ),
        ),
      );
      provider.release(digestModelAId);
    });

    test('reports a pinned model that is not in the catalog', () async {
      final provider = digestProvider();
      final synthesizer = synthesizerFor(provider);

      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper()]),
          model: ModelRef(
            providerId: BuiltInLlmCatalog.deepSeek,
            modelId: ModelId('missing-model'),
          ),
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.modelUnavailable,
          ),
        ),
      );
      expect(provider.requests, isEmpty);
    });
  });

  group('DigestLimits and DigestFailure', () {
    test('rejects cross-field violations at construction', () {
      for (final limits in <DigestLimits>[
        const DigestLimits(minPapers: 2, maxPapers: 1),
        const DigestLimits(maxPapers: 0),
        const DigestLimits(maxTotalAbstractBytes: 1, maxPaperAbstractBytes: 2),
        const DigestLimits(maxTotalTokens: 10, maxOutputTokens: 20),
        const DigestLimits(invocationTimeout: Duration.zero),
      ]) {
        expect(
          () => limits.validate(),
          throwsA(isA<McpException>()),
          reason: '$limits',
        );
      }
    });

    test('sanitizes and bounds failure text', () {
      final failure = DigestFailure(
        kind: DigestFailureKind.provider,
        message: 'a\n\nb\u0000${'x' * 500}',
      );
      expect(failure.mcpText, startsWith('[digest:provider] '));
      expect(failure.message, isNot(contains('\n')));
      expect(failure.message.length, lessThanOrEqualTo(401));
    });
  });

  group('input limits', () {
    test('rejects an empty paper list', () async {
      final synthesizer = synthesizerFor(digestProvider());
      await expectLater(
        synthesizer.synthesize(
          requestFor(const <Paper>[]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.invalidInput,
          ),
        ),
      );
    });

    test('rejects more papers than the limit', () async {
      final synthesizer = synthesizerFor(digestProvider());
      final papers = <Paper>[
        for (var i = 0; i < 11; i++) digestPaper(arxivId: '2501.${10000 + i}'),
      ];
      await expectLater(
        synthesizer.synthesize(
          requestFor(papers),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<DigestFailure>()),
      );
    });

    test('rejects a blank topic', () async {
      final synthesizer = synthesizerFor(digestProvider());
      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper()], topic: '   '),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.invalidInput,
          ),
        ),
      );
    });

    test('rejects a duplicated paper', () async {
      final synthesizer = synthesizerFor(digestProvider());
      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper(), digestPaper(title: 'Duplicate')]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<DigestFailure>()),
      );
    });

    test('rejects an abstract over the byte limit', () async {
      final synthesizer = synthesizerFor(
        digestProvider(),
        limits: const DigestLimits(
          maxPaperAbstractBytes: 16,
          maxTotalAbstractBytes: 32,
        ),
      );
      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper(abstractText: 'x' * 40)]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<DigestFailure>()),
      );
    });

    test('rejects a total abstract size over the byte limit', () async {
      final synthesizer = synthesizerFor(
        digestProvider(),
        limits: const DigestLimits(
          maxPaperAbstractBytes: 16,
          maxTotalAbstractBytes: 20,
        ),
      );
      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[
            digestPaper(abstractText: 'x' * 12),
            digestPaper(arxivId: '2501.99999', abstractText: 'y' * 12),
          ]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<DigestFailure>()),
      );
    });

    test('rejects a prompt over the byte limit', () async {
      final synthesizer = synthesizerFor(
        digestProvider(),
        limits: const DigestLimits(maxPromptBytes: 64),
      );
      await expectLater(
        synthesizer.synthesize(
          requestFor(<Paper>[digestPaper(abstractText: 'x' * 200)]),
          model: digestModelA,
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<DigestFailure>().having(
            (failure) => failure.kind,
            'kind',
            DigestFailureKind.invalidInput,
          ),
        ),
      );
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

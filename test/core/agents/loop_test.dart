import 'dart:async';
import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/scripted_llm_provider.dart';

void main() {
  group('guarded agent loop', () {
    test('final answer without tools completes once', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          <LlmEvent>[
            const LlmReasoningDelta('think'),
            const LlmTextDelta('done'),
            LlmUsageUpdate(
              LlmUsage(inputTokens: 2, outputTokens: 1, totalTokens: 3),
            ),
            LlmCompleted(
              finishReason: LlmFinishReason.stop,
              usage: LlmUsage(inputTokens: 2, outputTokens: 1, totalTokens: 3),
            ),
          ],
        ],
      );
      final events = await testRuntime(
        provider: provider,
      ).agent(testDefinition()).run('hi').events.toList();
      expect(events.whereType<AgentReasoningDelta>(), hasLength(1));
      expect(events.whereType<AgentAnswerDelta>().single.text, 'done');
      expect(events.where((event) => event.isTerminal), hasLength(1));
      expect(events.last, isA<AgentRunCompleted>());
    });

    test('tool continuation is sequential and unlimited by default', () async {
      final executor = ScriptedToolExecutor((
        invocation, {
        required cancellation,
        required liveness,
      }) async {
        return ToolExecutionResult.success(<String, Object?>{
          'n': invocation.arguments['n'],
        });
      });
      final tools = AgentToolRegistry()
        ..register(
          AgentTool(
            descriptor: LlmToolDescriptor(
              name: 'lookup',
              parameters: <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'n': <String, Object?>{'type': 'integer'},
                },
                'required': <String>['n'],
              },
            ),
            executor: executor,
          ),
        );
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          toolTurn(name: 'lookup', callId: 'c1', arguments: '{"n":1}'),
          toolTurn(name: 'lookup', callId: 'c2', arguments: '{"n":2}'),
          textTurn('final'),
        ],
      );
      final events = await testRuntime(provider: provider, tools: tools)
          .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
          .run('go')
          .events
          .toList();
      expect(executor.executions, 2);
      expect(events.whereType<AgentAnswerDelta>().last.text, 'final');
      expect(events.last, isA<AgentRunCompleted>());
      expect(provider.requests, hasLength(3));
    });

    test('zero tool allowance stops without executing', () async {
      final executor = ScriptedToolExecutor((
        invocation, {
        required cancellation,
        required liveness,
      }) async {
        return ToolExecutionResult.success(<String, Object?>{});
      });
      final tools = AgentToolRegistry()
        ..register(
          AgentTool(
            descriptor: LlmToolDescriptor(name: 'lookup'),
            executor: executor,
          ),
        );
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[toolTurn(name: 'lookup', callId: 'c1')],
      );
      final events = await testRuntime(provider: provider, tools: tools)
          .agent(
            testDefinition(
              tools: <ToolId>[ToolId('lookup')],
              limits: AgentRunLimits(maxModelTurns: 1, maxToolCalls: 0),
            ),
          )
          .run('go')
          .events
          .toList();
      expect(executor.executions, 0);
      expect(
        (events.last as AgentRunStopped).reason,
        AgentStopReason.toolCallLimit,
      );
    });

    test('run override, definition, and profile precedence', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          toolTurn(name: 'lookup', callId: 'c1'),
          textTurn('should-not-run'),
        ],
      );
      final tools = AgentToolRegistry()
        ..register(
          AgentTool(
            descriptor: LlmToolDescriptor(name: 'lookup'),
            executor: ScriptedToolExecutor((
              invocation, {
              required cancellation,
              required liveness,
            }) async {
              return ToolExecutionResult.success(<String, Object?>{});
            }),
          ),
        );
      final runtime = testRuntime(
        provider: provider,
        tools: tools,
        profileLimits: AgentRunLimits(maxModelTurns: 9),
      );
      final agent = runtime.agent(
        testDefinition(
          tools: <ToolId>[ToolId('lookup')],
          limits: AgentRunLimits(maxModelTurns: 4),
        ),
      );
      final finite = await agent
          .run(
            'go',
            options: AgentRunOptions(maxModelTurns: QuotaOverride.value(1)),
          )
          .events
          .toList();
      expect(
        (finite.last as AgentRunStopped).reason,
        AgentStopReason.modelTurnLimit,
      );
      expect(provider.requests, hasLength(1));
    });

    test(
      'token budget overshoot keeps output and blocks continuation',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              const LlmTextDelta('partial'),
              LlmUsageUpdate(LlmUsage(totalTokens: 50)),
              LlmCompleted(
                finishReason: LlmFinishReason.stop,
                usage: LlmUsage(totalTokens: 50),
              ),
            ],
          ],
        );
        final events = await testRuntime(provider: provider)
            .agent(testDefinition(budget: AgentTokenBudget(totalTokens: 10)))
            .run('go')
            .events
            .toList();
        expect(events.whereType<AgentAnswerDelta>().single.text, 'partial');
        expect(
          (events.last as AgentRunStopped).reason,
          AgentStopReason.totalBudget,
        );
      },
    );

    test('unverifiable budget fails before continuation', () async {
      final executor = ScriptedToolExecutor((
        invocation, {
        required cancellation,
        required liveness,
      }) async {
        return ToolExecutionResult.success(<String, Object?>{});
      });
      final tools = AgentToolRegistry()
        ..register(
          AgentTool(
            descriptor: LlmToolDescriptor(name: 'lookup'),
            executor: executor,
          ),
        );
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[toolTurn(name: 'lookup', callId: 'c1')],
      );
      final events = await testRuntime(provider: provider, tools: tools)
          .agent(
            testDefinition(
              tools: <ToolId>[ToolId('lookup')],
              budget: AgentTokenBudget(totalTokens: 10),
            ),
          )
          .run('go')
          .events
          .toList();
      expect(
        (events.last as AgentRunFailed).error.kind,
        AgentErrorKind.budgetUnverifiable,
      );
      expect(executor.executions, 0);
    });

    test(
      'finite turn and tool quotas are run-local not session-cumulative',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('one'), textTurn('two')],
        );
        final session = await testRuntime(provider: provider)
            .agent(testDefinition(limits: AgentRunLimits(maxModelTurns: 1)))
            .createSession();
        final first = await session.run('a').events.toList();
        expect(first.last, isA<AgentRunCompleted>());
        final second = await session.run('b').events.toList();
        expect(second.last, isA<AgentRunCompleted>());
        expect(provider.requests, hasLength(2));
        await session.close();
      },
    );

    test(
      'cumulative usage is not treated as the current context bound',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              const LlmTextDelta('first'),
              LlmCompleted(
                finishReason: LlmFinishReason.stop,
                usage: LlmUsage(inputTokens: 2000000, totalTokens: 2000000),
              ),
            ],
            textTurn('second'),
          ],
        );
        final session = await testRuntime(
          provider: provider,
        ).agent(testDefinition()).createSession();
        await session.run('one').events.drain<void>();
        final second = await session.run('two').events.toList();
        expect(second.last, isA<AgentRunCompleted>());
        expect(provider.requests, hasLength(2));
        await session.close();
      },
    );

    test(
      'token budgets are run-local while session usage stays cumulative',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn('one', usage: LlmUsage(totalTokens: 50)),
            textTurn('two', usage: LlmUsage(totalTokens: 30)),
          ],
        );
        final session = await testRuntime(provider: provider)
            .agent(testDefinition(budget: AgentTokenBudget(totalTokens: 40)))
            .createSession();
        final first = await session.run('a').events.toList();
        expect(
          (first.last as AgentRunStopped).reason,
          AgentStopReason.totalBudget,
        );
        final second = await session.run('b').events.toList();
        expect(second.last, isA<AgentRunCompleted>());
        expect(session.snapshot.usage.totalTokens, 80);
        await session.close();
      },
    );

    test('run reasoning override is frozen for the whole run', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final events = await testRuntime(provider: provider)
          .agent(testDefinition())
          .run(
            'go',
            options: AgentRunOptions(
              reasoning: AgentReasoningOverride(
                mode: ReasoningMode.disabled,
                effort: ReasoningEffort.modelDefault,
              ),
            ),
          )
          .events
          .toList();
      expect(events.last, isA<AgentRunCompleted>());
      expect(
        provider.requests.single.generation.reasoningMode,
        ReasoningMode.disabled,
      );
      expect(
        provider.requests.single.generation.reasoningEffort,
        ReasoningEffort.modelDefault,
      );
    });

    test('idle watchdog uses a fake clock and resets on progress', () async {
      final clock = FakeAgentClock();
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('tick')],
        gate: gate,
      );
      final runtime = testRuntime(provider: provider, clock: clock);
      final run = runtime
          .agent(
            testDefinition(
              liveness: AgentLivenessPolicy(
                idleTimeout: const Duration(minutes: 10),
              ),
            ),
          )
          .run('go');
      final eventsFuture = run.events.toList();
      await Future<void>.delayed(Duration.zero);
      clock.elapse(const Duration(minutes: 9));
      clock.elapse(const Duration(minutes: 2));
      final events = await eventsFuture;
      expect(
        (events.last as AgentRunStopped).reason,
        AgentStopReason.idleTimeout,
      );
      gate.complete();
    });

    test(
      'no-progress warns at five and stops at ten, resetting on changed results',
      () async {
        var n = 0;
        final executor = ScriptedToolExecutor((
          invocation, {
          required cancellation,
          required liveness,
        }) async {
          n += 1;
          return ToolExecutionResult.success(<String, Object?>{'n': 1});
        });
        final changing = ScriptedToolExecutor((
          invocation, {
          required cancellation,
          required liveness,
        }) async {
          n += 1;
          return ToolExecutionResult.success(<String, Object?>{'n': n});
        });
        Future<List<AgentRunEvent>> runWith(AgentToolExecutor exec) async {
          n = 0;
          final tools = AgentToolRegistry()
            ..register(
              AgentTool(
                descriptor: LlmToolDescriptor(name: 'lookup'),
                executor: exec,
              ),
            );
          final turns = <List<LlmEvent>>[
            for (var i = 0; i < 12; i++)
              toolTurn(name: 'lookup', callId: 'c$i', arguments: '{"x":1}'),
            textTurn('done'),
          ];
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: turns,
          );
          return testRuntime(provider: provider, tools: tools)
              .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
              .run('go')
              .events
              .toList();
        }

        final stuck = await runWith(executor);
        expect(stuck.whereType<AgentNoProgressWarning>(), hasLength(1));
        expect(
          (stuck.last as AgentRunStopped).reason,
          AgentStopReason.noProgress,
        );

        final varied = await runWith(changing);
        expect(varied.last, isA<AgentRunCompleted>());
      },
    );

    test('usage updates in one turn are counted once', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          <LlmEvent>[
            const LlmTextDelta('ok'),
            LlmUsageUpdate(LlmUsage(totalTokens: 10)),
            LlmCompleted(
              finishReason: LlmFinishReason.stop,
              usage: LlmUsage(totalTokens: 10),
            ),
          ],
        ],
      );
      final events = await testRuntime(
        provider: provider,
      ).agent(testDefinition()).run('go').events.toList();
      final completed = events.last as AgentRunCompleted;
      expect(completed.usage?.totalTokens, 10);
    });

    test('duration limit is relative to run start', () async {
      final clock = FakeAgentClock();
      clock.elapse(const Duration(minutes: 5));
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('tick')],
        gate: gate,
      );
      final run = testRuntime(provider: provider, clock: clock)
          .agent(testDefinition())
          .run(
            'go',
            options: AgentRunOptions(
              maxDuration: const QuotaOverride.value(Duration(minutes: 1)),
            ),
          );
      final eventsFuture = run.events.toList();
      await Future<void>.delayed(Duration.zero);
      clock.elapse(const Duration(seconds: 30));
      clock.elapse(const Duration(seconds: 40));
      final events = await eventsFuture;
      expect(
        (events.last as AgentRunStopped).reason,
        AgentStopReason.durationLimit,
      );
      gate.complete();
    });

    test(
      'explicit unlimited run override ignores definition and profile',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            toolTurn(name: 'lookup', callId: 'c1'),
            textTurn('done'),
          ],
        );
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(name: 'lookup'),
              executor: ScriptedToolExecutor((
                invocation, {
                required cancellation,
                required liveness,
              }) async {
                return ToolExecutionResult.success(<String, Object?>{});
              }),
            ),
          );
        final events =
            await testRuntime(
                  provider: provider,
                  tools: tools,
                  profile: AgentRuntimeProfile(
                    limits: AgentRunLimits(maxModelTurns: 1),
                  ),
                )
                .agent(
                  testDefinition(
                    tools: <ToolId>[ToolId('lookup')],
                    limits: AgentRunLimits(maxModelTurns: 1),
                  ),
                )
                .run(
                  'go',
                  options: AgentRunOptions(
                    maxModelTurns: const QuotaOverride.unlimited(),
                  ),
                )
                .events
                .toList();
        expect(events.last, isA<AgentRunCompleted>());
        expect(provider.requests, hasLength(2));
      },
    );

    test('rejects negative run overrides', () {
      expect(
        () => AgentRunOptions(maxModelTurns: const QuotaOverride.value(-1)),
        throwsA(isA<AgentException>()),
      );
    });

    test('duplicate tool call ids fail without executing twice', () async {
      var executed = 0;
      final tools = AgentToolRegistry()
        ..register(
          AgentTool(
            descriptor: LlmToolDescriptor(name: 'lookup'),
            executor: ScriptedToolExecutor((
              invocation, {
              required cancellation,
              required liveness,
            }) async {
              executed += 1;
              return ToolExecutionResult.success(<String, Object?>{});
            }),
          ),
        );
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          <LlmEvent>[
            LlmToolCallDelta(
              callId: ToolCallId('c1'),
              index: 0,
              name: 'lookup',
              argumentsFragment: '{}',
            ),
            LlmToolCallDelta(
              callId: ToolCallId('c1'),
              index: 1,
              name: 'lookup',
              argumentsFragment: '{}',
            ),
            const LlmCompleted(finishReason: LlmFinishReason.toolCalls),
          ],
        ],
      );
      final events = await testRuntime(provider: provider, tools: tools)
          .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
          .run('go')
          .events
          .toList();
      expect(executed, 0);
      expect(
        (events.last as AgentRunFailed).error.kind,
        AgentErrorKind.protocol,
      );
    });

    test(
      'budget stop commits turn usage once for snapshot and restore',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              const LlmTextDelta('partial'),
              LlmUsageUpdate(LlmUsage(totalTokens: 50)),
              LlmCompleted(
                finishReason: LlmFinishReason.stop,
                usage: LlmUsage(totalTokens: 50),
              ),
            ],
          ],
        );
        final runtime = testRuntime(provider: provider);
        final agent = runtime.agent(
          testDefinition(budget: AgentTokenBudget(totalTokens: 10)),
        );
        final session = await agent.createSession(
          persistence: SessionPersistence.repository,
        );
        final events = await session.run('go').events.toList();
        expect(
          (events.last as AgentRunStopped).reason,
          AgentStopReason.totalBudget,
        );
        expect((events.last as AgentRunStopped).usage?.totalTokens, 50);
        expect(session.snapshot.usage.totalTokens, 50);
        expect(
          events.whereType<AgentUsageUpdated>().last.usage.totalTokens,
          50,
        );
        await session.close();
        final restored = await agent.restoreSession(session.id);
        expect(restored.snapshot.usage.totalTokens, 50);
        await restored.close();
      },
    );

    test('provider failure commits merged turn usage', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          <LlmEvent>[
            const LlmTextDelta('partial'),
            LlmUsageUpdate(LlmUsage(totalTokens: 7)),
            LlmFailed(
              LlmError(kind: LlmErrorKind.provider, message: 'upstream'),
            ),
          ],
        ],
      );
      final session = await testRuntime(
        provider: provider,
      ).agent(testDefinition()).createSession();
      final events = await session.run('go').events.toList();
      expect(events.last, isA<AgentRunFailed>());
      expect(session.snapshot.usage.totalTokens, 7);
      await session.close();
    });

    test('cancellation commits merged turn usage', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: <LlmEvent>[
          const LlmTextDelta('partial'),
          LlmUsageUpdate(LlmUsage(totalTokens: 4)),
        ],
        gate: gate,
      );
      final session = await testRuntime(
        provider: provider,
      ).agent(testDefinition()).createSession();
      final run = session.run('go');
      await Future<void>.delayed(Duration.zero);
      await run.cancel();
      final events = await run.events.toList();
      expect(events.last, isA<AgentRunCancelled>());
      expect(session.snapshot.usage.totalTokens, 4);
      gate.complete();
      await session.close();
    });

    test(
      'runtime profile no-progress applies when definition omits it',
      () async {
        final executor = ScriptedToolExecutor((
          invocation, {
          required cancellation,
          required liveness,
        }) async {
          return ToolExecutionResult.success(<String, Object?>{'n': 1});
        });
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(name: 'lookup'),
              executor: executor,
            ),
          );
        final turns = <List<LlmEvent>>[
          for (var i = 0; i < 6; i++)
            toolTurn(name: 'lookup', callId: 'c$i', arguments: '{"x":1}'),
          textTurn('done'),
        ];
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: turns,
        );
        final events =
            await testRuntime(
                  provider: provider,
                  tools: tools,
                  profile: AgentRuntimeProfile(
                    noProgress: AgentNoProgressPolicy(
                      warningThreshold: 2,
                      stopThreshold: 4,
                    ),
                  ),
                )
                .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
                .run('go')
                .events
                .toList();
        expect(events.whereType<AgentNoProgressWarning>(), hasLength(1));
        expect(
          (events.last as AgentRunStopped).reason,
          AgentStopReason.noProgress,
        );
        expect(provider.requests.length, lessThan(6));
      },
    );

    test('definition idle disable ignores runtime profile timeout', () async {
      final clock = FakeAgentClock();
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('tick')],
        gate: gate,
      );
      final run = testRuntime(
        provider: provider,
        clock: clock,
        profile: AgentRuntimeProfile(
          liveness: AgentLivenessPolicy(
            idleTimeout: const Duration(minutes: 1),
          ),
        ),
      ).agent(testDefinition(liveness: AgentLivenessPolicy.disabled)).run('go');
      final collected = <AgentRunEvent>[];
      final sub = run.events.listen(collected.add);
      await Future<void>.delayed(Duration.zero);
      clock.elapse(const Duration(minutes: 5));
      await Future<void>.delayed(Duration.zero);
      expect(collected.where((event) => event.isTerminal), isEmpty);
      gate.complete();
      await sub.asFuture<void>();
      expect(collected.last, isA<AgentRunCompleted>());
    });

    test('runtime-only idle applies when definition omits liveness', () async {
      final clock = FakeAgentClock();
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('tick')],
        gate: gate,
      );
      final events = testRuntime(
        provider: provider,
        clock: clock,
        profile: AgentRuntimeProfile(
          liveness: AgentLivenessPolicy(
            idleTimeout: const Duration(minutes: 1),
          ),
        ),
      ).agent(testDefinition()).run('go').events.toList();
      await Future<void>.delayed(Duration.zero);
      clock.elapse(const Duration(minutes: 2));
      final completed = await events;
      expect(
        (completed.last as AgentRunStopped).reason,
        AgentStopReason.idleTimeout,
      );
      gate.complete();
    });

    test(
      'long beforeTool hook does not idle-timeout after tool start reset',
      () async {
        final clock = FakeAgentClock();
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(name: 'lookup'),
              executor: ScriptedToolExecutor((
                invocation, {
                required cancellation,
                required liveness,
              }) async {
                return ToolExecutionResult.success(<String, Object?>{});
              }),
            ),
          );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            toolTurn(name: 'lookup', callId: 'c1'),
            textTurn('done'),
          ],
        );
        final events =
            await testRuntime(
                  provider: provider,
                  tools: tools,
                  clock: clock,
                  hooks: <AgentLifecycleHook>[
                    _ElapsingHook(
                      clock,
                      afterModel: const Duration(minutes: 9),
                      beforeToolDelay: const Duration(minutes: 2),
                    ),
                  ],
                )
                .agent(
                  testDefinition(
                    tools: <ToolId>[ToolId('lookup')],
                    liveness: AgentLivenessPolicy(
                      idleTimeout: const Duration(minutes: 10),
                    ),
                  ),
                )
                .run('go')
                .events
                .toList();
        expect(events.last, isA<AgentRunCompleted>());
      },
    );

    test(
      'long afterTool hook does not idle-timeout after executor reset',
      () async {
        final clock = FakeAgentClock();
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(name: 'lookup'),
              executor: ScriptedToolExecutor((
                invocation, {
                required cancellation,
                required liveness,
              }) async {
                liveness.reportProgress();
                clock.elapse(const Duration(minutes: 9));
                return ToolExecutionResult.success(<String, Object?>{});
              }),
            ),
          );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            toolTurn(name: 'lookup', callId: 'c1'),
            textTurn('done'),
          ],
        );
        final events =
            await testRuntime(
                  provider: provider,
                  tools: tools,
                  clock: clock,
                  hooks: <AgentLifecycleHook>[
                    _ElapsingHook(
                      clock,
                      afterToolDelay: const Duration(minutes: 2),
                    ),
                  ],
                )
                .agent(
                  testDefinition(
                    tools: <ToolId>[ToolId('lookup')],
                    liveness: AgentLivenessPolicy(
                      idleTimeout: const Duration(minutes: 10),
                    ),
                  ),
                )
                .run('go')
                .events
                .toList();
        expect(events.last, isA<AgentRunCompleted>());
      },
    );

    test(
      'mismatched Responses assistant text fails before tool execution',
      () async {
        final executor = ScriptedToolExecutor((
          invocation, {
          required cancellation,
          required liveness,
        }) async {
          return ToolExecutionResult.success(<String, Object?>{'ok': true});
        });
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(
                name: 'lookup',
                parameters: <String, Object?>{
                  'type': 'object',
                  'properties': <String, Object?>{},
                },
              ),
              executor: executor,
            ),
          );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.openAi,
          wireFamily: LlmWireFamily.openaiResponses,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              const LlmTextDelta('visible'),
              LlmToolCallDelta(
                callId: ToolCallId('call_1'),
                index: 0,
                name: 'lookup',
                argumentsFragment: '{}',
              ),
              LlmCompleted(
                finishReason: LlmFinishReason.toolCalls,
                turnState: LlmProviderTurnState(
                  origin: BuiltInLlmCatalog.gpt5MiniModel.ref,
                  wireFamily: LlmWireFamily.openaiResponses,
                  format: openaiResponsesOutputItemsV1,
                  payload: <Map<String, Object?>>[
                    <String, Object?>{
                      'type': 'message',
                      'id': 'msg_1',
                      'status': 'completed',
                      'role': 'assistant',
                      'content': <Map<String, Object?>>[
                        <String, Object?>{
                          'type': 'output_text',
                          'text': 'other',
                        },
                      ],
                    },
                    <String, Object?>{
                      'type': 'function_call',
                      'id': 'fc_1',
                      'call_id': 'call_1',
                      'name': 'lookup',
                      'arguments': '{}',
                    },
                  ],
                ),
              ),
            ],
          ],
        );
        final events = await testRuntime(provider: provider, tools: tools)
            .agent(
              testDefinition(
                model: BuiltInLlmCatalog.gpt5MiniModel.ref,
                tools: <ToolId>[ToolId('lookup')],
              ),
            )
            .run('go')
            .events
            .toList();
        expect(executor.executions, 0);
        expect(events.last, isA<AgentRunFailed>());
        expect(
          (events.last as AgentRunFailed).error.kind,
          AgentErrorKind.protocol,
        );
      },
    );

    test(
      'mismatched Responses function_call items fail before tool execution',
      () async {
        final executor = ScriptedToolExecutor((
          invocation, {
          required cancellation,
          required liveness,
        }) async {
          return ToolExecutionResult.success(<String, Object?>{'ok': true});
        });
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(
                name: 'lookup',
                parameters: <String, Object?>{
                  'type': 'object',
                  'properties': <String, Object?>{},
                },
              ),
              executor: executor,
            ),
          );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.openAi,
          wireFamily: LlmWireFamily.openaiResponses,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              LlmToolCallDelta(
                callId: ToolCallId('call_1'),
                index: 0,
                name: 'lookup',
                argumentsFragment: '{}',
              ),
              LlmCompleted(
                finishReason: LlmFinishReason.toolCalls,
                turnState: LlmProviderTurnState(
                  origin: BuiltInLlmCatalog.gpt5MiniModel.ref,
                  wireFamily: LlmWireFamily.openaiResponses,
                  format: openaiResponsesOutputItemsV1,
                  payload: <Map<String, Object?>>[
                    <String, Object?>{
                      'type': 'function_call',
                      'id': 'fc_1',
                      'call_id': 'call_1',
                      'name': 'other',
                      'arguments': '{}',
                    },
                  ],
                ),
              ),
            ],
          ],
        );
        final events = await testRuntime(provider: provider, tools: tools)
            .agent(
              testDefinition(
                model: BuiltInLlmCatalog.gpt5MiniModel.ref,
                tools: <ToolId>[ToolId('lookup')],
              ),
            )
            .run('go')
            .events
            .toList();
        expect(executor.executions, 0);
        expect(events.last, isA<AgentRunFailed>());
        expect(
          (events.last as AgentRunFailed).error.kind,
          AgentErrorKind.protocol,
        );
      },
    );

    group('context overflow recovery', () {
      test('custom trigger can decline the single overflow offer', () async {
        final trigger = _OverflowRecoveryTrigger(recover: false);
        final compactor = _CountingCompactor(
          RecentInteractionGroupsCompactor(0),
        );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[_overflowTurn()],
        );
        final events = await testRuntime(
          provider: provider,
          compactionTrigger: trigger,
          historyCompactor: compactor,
        ).agent(testDefinition()).run('go').events.toList();
        expect(provider.requests, hasLength(1));
        expect(compactor.calls, 0);
        expect(trigger.reasons, <AgentCompactionReason>[
          AgentCompactionReason.preRequest,
          AgentCompactionReason.providerOverflow,
        ]);
        expect(
          (events.last as AgentRunFailed).error.kind,
          AgentErrorKind.provider,
        );
      });

      test(
        'effective commit retries once with ordered sanitized events',
        () async {
          final trigger = _OverflowRecoveryTrigger(recover: true, target: 100);
          final estimator = _LoopMessageEstimator();
          final compactor = _CountingCompactor(
            RecentInteractionGroupsCompactor(1),
          );
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[
              textTurn('old answer'),
              _overflowTurn(),
              textTurn('recovered'),
            ],
          );
          final session = await testRuntime(
            provider: provider,
            contextEstimator: estimator,
            compactionTrigger: trigger,
            historyCompactor: compactor,
          ).agent(testDefinition()).createSession();
          await session.run('old').events.drain<void>();
          final events = await session.run('new').events.toList();
          final automatic = events
              .whereType<AgentAutomaticCompactionEvent>()
              .map((event) => event.compaction)
              .toList();
          expect(automatic, hasLength(2));
          expect(automatic.first, isA<AgentCompactionStarted>());
          expect(automatic.last, isA<AgentCompactionSucceeded>());
          expect(automatic.first.operationId, automatic.last.operationId);
          expect(
            automatic.first.reason,
            AgentCompactionReason.providerOverflow,
          );
          expect(automatic.first.runId, isNotNull);
          expect(automatic.first.triggerId, trigger.id);
          expect(automatic.first.strategyId, compactor.id);
          expect(automatic.first.estimatorId, estimator.id);
          expect(automatic.first.targetEstimate, 100);
          final succeeded = automatic.last as AgentCompactionSucceeded;
          expect(succeeded.beforeEstimate, 300);
          expect(succeeded.afterEstimate, 100);
          expect(succeeded.generation, 1);
          expect(
            events.indexOf(
              events.whereType<AgentAutomaticCompactionEvent>().last,
            ),
            lessThan(
              events.indexOf(events.whereType<AgentAnswerDelta>().single),
            ),
          );
          expect(provider.requests, hasLength(3));
          expect(provider.requests.last.context.messages, <LlmMessage>[
            LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('new')],
            ),
          ]);
          expect(compactor.calls, 1);
          expect(events.last, isA<AgentRunCompleted>());
          expect(events.where((event) => event.isTerminal), hasLength(1));
          expect(automatic.toString(), isNot(contains('old answer')));
          await session.close();
        },
      );

      test('second overflow cannot compact or request a third time', () async {
        final trigger = _OverflowRecoveryTrigger(recover: true, target: 100);
        final compactor = _CountingCompactor(
          RecentInteractionGroupsCompactor(1),
        );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            textTurn('old'),
            _overflowTurn(),
            _overflowTurn(),
          ],
        );
        final session = await testRuntime(
          provider: provider,
          contextEstimator: _LoopMessageEstimator(),
          compactionTrigger: trigger,
          historyCompactor: compactor,
        ).agent(testDefinition()).createSession();
        await session.run('old').events.drain<void>();
        final events = await session.run('new').events.toList();
        expect(provider.requests, hasLength(3));
        expect(compactor.calls, 1);
        expect(
          trigger.reasons.where(
            (reason) => reason == AgentCompactionReason.providerOverflow,
          ),
          hasLength(1),
        );
        expect(
          (events.last as AgentRunFailed).error.kind,
          AgentErrorKind.provider,
        );
        await session.close();
      });

      test(
        'text or tool-call delta forbids recovery and side effects',
        () async {
          for (final progress in <LlmEvent>[
            const LlmReasoningDelta('thinking'),
            const LlmTextDelta('partial'),
            LlmToolCallDelta(
              callId: ToolCallId('call_1'),
              index: 0,
              name: 'lookup',
              argumentsFragment: '{}',
            ),
          ]) {
            final trigger = _OverflowRecoveryTrigger(recover: true);
            final compactor = _CountingCompactor(
              RecentInteractionGroupsCompactor(0),
            );
            final provider = QueueScriptedLlmProvider(
              id: BuiltInLlmCatalog.deepSeek,
              wireFamily: LlmWireFamily.openaiChatCompletions,
              turns: <List<LlmEvent>>[
                <LlmEvent>[progress, ..._overflowTurn()],
              ],
            );
            final events = await testRuntime(
              provider: provider,
              compactionTrigger: trigger,
              historyCompactor: compactor,
            ).agent(testDefinition()).run('go').events.toList();
            expect(provider.requests, hasLength(1));
            expect(compactor.calls, 0);
            expect(trigger.reasons, <AgentCompactionReason>[
              AgentCompactionReason.preRequest,
            ]);
            expect(events.whereType<AgentToolStarted>(), isEmpty);
            expect(events.last, isA<AgentRunFailed>());
          }
        },
      );

      test('no-change and compactor failure terminate without retry', () async {
        Future<(List<AgentRunEvent>, int)> runWith(
          AgentHistoryCompactor compactor,
        ) async {
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[_overflowTurn()],
          );
          final events = await testRuntime(
            provider: provider,
            compactionTrigger: _OverflowRecoveryTrigger(recover: true),
            historyCompactor: compactor,
          ).agent(testDefinition()).run('go').events.toList();
          return (events, provider.requests.length);
        }

        final noChange = await runWith(_NoChangeCompactor());
        final noChangeEvents = noChange.$1
            .whereType<AgentAutomaticCompactionEvent>()
            .map((event) => event.compaction)
            .toList();
        expect(noChange.$2, 1);
        expect(noChangeEvents, hasLength(2));
        expect(noChangeEvents.last, isA<AgentCompactionNoChangeEvent>());
        expect(noChange.$1.last, isA<AgentRunFailed>());

        final failed = await runWith(_FailingCompactor());
        final failedEvents = failed.$1
            .whereType<AgentAutomaticCompactionEvent>()
            .map((event) => event.compaction)
            .toList();
        expect(failed.$2, 1);
        expect(failedEvents, hasLength(2));
        final failure = failedEvents.last as AgentCompactionFailed;
        expect(failure.error.kind, AgentErrorKind.compaction);
        expect(failure.error.message, isNot(contains('sk-secret')));
        expect(
          (failed.$1.last as AgentRunFailed).error.kind,
          AgentErrorKind.compaction,
        );
      });

      test(
        'cancellation during recovery emits cancelled before run terminal',
        () async {
          final compactor = _CancellableOverflowCompactor();
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[_overflowTurn()],
          );
          final session = await testRuntime(
            provider: provider,
            compactionTrigger: _OverflowRecoveryTrigger(recover: true),
            historyCompactor: compactor,
          ).agent(testDefinition()).createSession();
          final run = session.run('go');
          final eventsFuture = run.events.toList();
          await compactor.started.future;
          await run.cancel();
          final events = await eventsFuture;
          final automatic = events
              .whereType<AgentAutomaticCompactionEvent>()
              .map((event) => event.compaction)
              .toList();
          expect(provider.requests, hasLength(1));
          expect(automatic, hasLength(2));
          expect(automatic.last, isA<AgentCompactionCancelled>());
          expect(events.last, isA<AgentRunCancelled>());
          expect(events.where((event) => event.isTerminal), hasLength(1));
          await session.close();
        },
      );
    });

    group('summary compaction usage', () {
      test(
        'automatic summary usage aggregates all token and cache fields once',
        () async {
          final firstUsage = LlmUsage(
            inputTokens: 1,
            outputTokens: 1,
            totalTokens: 2,
            cacheHitTokens: 1,
            cacheMissTokens: 2,
          );
          final summaryUsage = LlmUsage(
            inputTokens: 3,
            outputTokens: 4,
            totalTokens: 7,
            cacheHitTokens: 5,
            cacheMissTokens: 6,
          );
          final finalUsage = LlmUsage(
            inputTokens: 2,
            outputTokens: 3,
            totalTokens: 5,
            cacheHitTokens: 7,
            cacheMissTokens: 8,
          );
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[
              textTurn('old answer', usage: firstUsage),
              textTurn(
                _summaryJson('private generated summary'),
                usage: summaryUsage,
              ),
              textTurn('final answer', usage: finalUsage),
            ],
          );
          final registry = _summaryRegistry(provider);
          final compactor = OpenCodeSummaryCompactor(
            llm: RegistryAgentSummaryLlmInvocation(registry),
          );
          final session = await InMemoryAgentRuntime(
            registry: registry,
            contextEstimator: _LoopMessageEstimator(),
            compactionTrigger: _CompactTwoGroupsTrigger(),
            historyCompactor: compactor,
          ).agent(testDefinition()).createSession();
          await session.run('old').events.drain<void>();

          final events = await session.run('new').events.toList();
          final automatic = events
              .whereType<AgentAutomaticCompactionEvent>()
              .map((event) => event.compaction)
              .toList();
          expect(automatic, hasLength(2));
          final succeeded = automatic.last as AgentCompactionSucceeded;
          expect(succeeded.usage, summaryUsage);
          expect(session.snapshot.usage.inputTokens, 6);
          expect(session.snapshot.usage.outputTokens, 8);
          expect(session.snapshot.usage.totalTokens, 14);
          expect(session.snapshot.usage.cacheHitTokens, 13);
          expect(session.snapshot.usage.cacheMissTokens, 16);
          expect(session.snapshot.modelTurns, 2);
          expect(provider.requests, hasLength(3));
          expect(
            events.whereType<AgentUsageUpdated>().any(
              (event) => event.usage.totalTokens == 9,
            ),
            isTrue,
          );
          expect(
            events.toString(),
            isNot(contains('private generated summary')),
          );
          await session.close();
        },
      );

      test(
        'summary usage stops the run quota before candidate commit',
        () async {
          final summaryUsage = LlmUsage(totalTokens: 5, cacheMissTokens: 5);
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[
              textTurn('old answer', usage: LlmUsage(totalTokens: 1)),
              textTurn(
                _summaryJson('must-not-be-committed'),
                usage: summaryUsage,
              ),
              textTurn('must-not-run'),
            ],
          );
          final registry = _summaryRegistry(provider);
          final session =
              await InMemoryAgentRuntime(
                    registry: registry,
                    contextEstimator: _LoopMessageEstimator(),
                    compactionTrigger: _CompactTwoGroupsTrigger(),
                    historyCompactor: OpenCodeSummaryCompactor(
                      llm: RegistryAgentSummaryLlmInvocation(registry),
                    ),
                  )
                  .agent(
                    testDefinition(budget: AgentTokenBudget(totalTokens: 5)),
                  )
                  .createSession();
          await session.run('old').events.drain<void>();
          final before = session.snapshot.transcript;

          final events = await session.run('new').events.toList();
          final automatic = events
              .whereType<AgentAutomaticCompactionEvent>()
              .map((event) => event.compaction)
              .toList();
          expect(automatic, hasLength(2));
          final failed = automatic.last as AgentCompactionFailed;
          expect(failed.usage, summaryUsage);
          expect(
            failed.error.message,
            isNot(contains('must-not-be-committed')),
          );
          expect(
            (events.last as AgentRunStopped).reason,
            AgentStopReason.totalBudget,
          );
          expect(provider.requests, hasLength(2));
          expect(session.snapshot.usage.totalTokens, 6);
          expect(session.snapshot.compactionState, isNull);
          expect(
            session.snapshot.transcript.messages.take(2).toList(),
            before.messages,
          );
          expect(
            session.snapshot.transcript.messages.last,
            LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('new')],
            ),
          );
          await session.close();
        },
      );

      test(
        'missing compactor usage field makes the matching quota unverifiable',
        () async {
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[
              textTurn('old answer', usage: LlmUsage(totalTokens: 1)),
              textTurn(
                _summaryJson('unverifiable'),
                usage: LlmUsage(inputTokens: 4),
              ),
              textTurn('must-not-run'),
            ],
          );
          final registry = _summaryRegistry(provider);
          final session =
              await InMemoryAgentRuntime(
                    registry: registry,
                    contextEstimator: _LoopMessageEstimator(),
                    compactionTrigger: _CompactTwoGroupsTrigger(),
                    historyCompactor: OpenCodeSummaryCompactor(
                      llm: RegistryAgentSummaryLlmInvocation(registry),
                    ),
                  )
                  .agent(
                    testDefinition(budget: AgentTokenBudget(totalTokens: 10)),
                  )
                  .createSession();
          await session.run('old').events.drain<void>();

          final events = await session.run('new').events.toList();
          final failed = events
              .whereType<AgentAutomaticCompactionEvent>()
              .map((event) => event.compaction)
              .whereType<AgentCompactionFailed>()
              .single;
          expect(failed.usage?.inputTokens, 4);
          expect(
            (events.last as AgentRunFailed).error.kind,
            AgentErrorKind.budgetUnverifiable,
          );
          expect(provider.requests, hasLength(2));
          expect(session.snapshot.compactionState, isNull);
          await session.close();
        },
      );

      test(
        'failed summary charges reported usage without leaking details',
        () async {
          final failedUsage = LlmUsage(
            inputTokens: 4,
            totalTokens: 4,
            cacheHitTokens: 2,
          );
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: <List<LlmEvent>>[
              textTurn('old answer', usage: LlmUsage(totalTokens: 1)),
              <LlmEvent>[
                LlmUsageUpdate(failedUsage),
                LlmFailed(
                  LlmError(
                    kind: LlmErrorKind.provider,
                    message: 'provider-secret-summary-failure',
                  ),
                ),
              ],
            ],
          );
          final registry = _summaryRegistry(provider);
          final session = await InMemoryAgentRuntime(
            registry: registry,
            contextEstimator: _LoopMessageEstimator(),
            compactionTrigger: _CompactTwoGroupsTrigger(),
            historyCompactor: OpenCodeSummaryCompactor(
              llm: RegistryAgentSummaryLlmInvocation(registry),
            ),
          ).agent(testDefinition()).createSession();
          await session.run('old').events.drain<void>();

          final events = await session.run('new').events.toList();
          final failed = events
              .whereType<AgentAutomaticCompactionEvent>()
              .map((event) => event.compaction)
              .whereType<AgentCompactionFailed>()
              .single;
          expect(failed.usage, failedUsage);
          expect(failed.error.kind, AgentErrorKind.compaction);
          expect(failed.error.message, isNot(contains('provider-secret')));
          expect(session.snapshot.usage.totalTokens, 5);
          expect(session.snapshot.usage.inputTokens, 4);
          expect(session.snapshot.usage.cacheHitTokens, 2);
          expect(events.last, isA<AgentRunFailed>());
          expect(events.toString(), isNot(contains('provider-secret')));
          await session.close();
        },
      );
    });

    test('cancellation during model output is terminal once', () async {
      final gate = Completer<void>();
      final provider = ScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        events: const <LlmEvent>[LlmTextDelta('partial')],
        gate: gate,
      );
      final run = testRuntime(
        provider: provider,
      ).agent(testDefinition()).run('go');
      await Future<void>.delayed(Duration.zero);
      await run.cancel();
      gate.complete();
      final events = await run.events.toList();
      expect(events.whereType<AgentAnswerDelta>(), isNotEmpty);
      expect(events.where((event) => event.isTerminal), hasLength(1));
      expect(events.last, isA<AgentRunCancelled>());
    });
  });
}

final class _ElapsingHook extends AgentLifecycleHookBase {
  _ElapsingHook(
    this.clock, {
    this.afterModel,
    this.beforeToolDelay,
    this.afterToolDelay,
  });

  final FakeAgentClock clock;
  final Duration? afterModel;
  final Duration? beforeToolDelay;
  final Duration? afterToolDelay;

  @override
  Future<void> afterModelTurn(AgentHookContext context) async {
    if (afterModel != null) {
      clock.elapse(afterModel!);
    }
  }

  @override
  Future<void> beforeTool(AgentHookContext context) async {
    if (beforeToolDelay != null) {
      clock.elapse(beforeToolDelay!);
    }
  }

  @override
  Future<void> afterTool(AgentHookContext context) async {
    if (afterToolDelay != null) {
      clock.elapse(afterToolDelay!);
    }
  }
}

List<LlmEvent> _overflowTurn() => <LlmEvent>[
  LlmFailed(
    LlmError(kind: LlmErrorKind.contextOverflow, message: 'confirmed overflow'),
  ),
];

LlmProviderRegistry _summaryRegistry(LlmProvider provider) {
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  registry.registerProvider(provider);
  return registry;
}

String _summaryJson(String objective) => jsonEncode(<String, Object?>{
  'objective': objective,
  'constraintsAndDecisions': <String>[],
  'facts': <String>[],
  'relevantToolOutcomes': <String>[],
  'pendingWork': <String>[],
});

final class _CompactTwoGroupsTrigger implements AgentCompactionTrigger {
  @override
  AgentCompactionDecision evaluate(AgentCompactionContext context) {
    if (context.interactionGroups.length >= 2) {
      return AgentCompactionDecision.compact(
        triggerId: 'compact-two-groups',
        triggerVersion: 1,
      );
    }
    return AgentCompactionDecision.skip(
      triggerId: 'compact-two-groups',
      triggerVersion: 1,
    );
  }
}

final class _OverflowRecoveryTrigger implements AgentCompactionTrigger {
  _OverflowRecoveryTrigger({required this.recover, this.target});

  final bool recover;
  final int? target;
  final String id = 'overflow-recovery-test';
  final List<AgentCompactionReason> reasons = <AgentCompactionReason>[];

  @override
  AgentCompactionDecision evaluate(AgentCompactionContext context) {
    reasons.add(context.reason);
    if (recover && context.reason == AgentCompactionReason.providerOverflow) {
      return AgentCompactionDecision.compact(
        triggerId: id,
        triggerVersion: 1,
        targetEstimate: target,
      );
    }
    return AgentCompactionDecision.skip(triggerId: id, triggerVersion: 1);
  }
}

final class _LoopMessageEstimator implements AgentContextEstimator {
  final String id = 'loop-message-count';

  @override
  AgentContextEstimate estimate(AgentContextEstimateInput input) {
    return AgentContextEstimate(
      value: input.request.context.messages.length * 100,
      estimatorId: id,
      estimatorVersion: 1,
    );
  }
}

final class _CountingCompactor implements AgentHistoryCompactor {
  _CountingCompactor(this.delegate);

  final AgentHistoryCompactor delegate;
  var calls = 0;

  @override
  String get id => delegate.id;

  @override
  int get version => delegate.version;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) {
    calls += 1;
    return delegate.compact(context, decision);
  }
}

final class _NoChangeCompactor implements AgentHistoryCompactor {
  @override
  String get id => 'no-change-test';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async => AgentCompactionNoChange(strategyId: id, strategyVersion: version);
}

final class _FailingCompactor implements AgentHistoryCompactor {
  @override
  String get id => 'failing-test';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    throwAgent(AgentErrorKind.compaction, 'sk-secret removed history');
  }
}

final class _CancellableOverflowCompactor implements AgentHistoryCompactor {
  final Completer<void> started = Completer<void>();

  @override
  String get id => 'cancellable-overflow-test';

  @override
  int get version => 1;

  @override
  Future<AgentCompactionStrategyResult> compact(
    AgentCompactionContext context,
    AgentCompactionDecision decision,
  ) async {
    started.complete();
    await context.cancellation.whenCancelled;
    throwAgent(AgentErrorKind.cancelled, 'cancelled');
  }
}

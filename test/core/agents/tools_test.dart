import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  group('tools, schema, policy, and hooks', () {
    test('rejects malformed required and enum shapes', () {
      expect(
        () => validateToolSchema(<String, Object?>{
          'type': 'object',
          'required': <Object?>[1, 'name'],
        }),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => validateToolSchema(<String, Object?>{
          'type': 'string',
          'enum': <Object?>[],
        }),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => validateToolSchema(<String, Object?>{
          'type': 'string',
          'enum': <Object?>[
            <String, Object?>{'no': 'objects'},
          ],
        }),
        throwsA(isA<AgentException>()),
      );
    });

    test('rejects unsupported schemas at registration', () {
      expect(
        () => AgentTool(
          descriptor: LlmToolDescriptor(
            name: 'bad',
            parameters: <String, Object?>{
              'type': 'object',
              r'$ref': '#/defs/x',
            },
          ),
          executor: ScriptedToolExecutor((
            invocation, {
            required cancellation,
            required liveness,
          }) async {
            return ToolExecutionResult.success(<String, Object?>{});
          }),
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentTool(
          descriptor: LlmToolDescriptor(
            name: 'string-root',
            parameters: <String, Object?>{'type': 'string'},
          ),
          executor: ScriptedToolExecutor((
            invocation, {
            required cancellation,
            required liveness,
          }) async {
            return ToolExecutionResult.success(<String, Object?>{});
          }),
        ),
        throwsA(isA<AgentException>()),
      );
    });

    test('validates nested supported schemas and arguments', () {
      validateToolSchema(<String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'name': <String, Object?>{
            'type': 'string',
            'enum': <String>['a', 'b'],
          },
          'tags': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
        },
        'required': <String>['name'],
        'additionalProperties': false,
      });
      validateArguments(
        <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'name': <String, Object?>{'type': 'string'},
          },
          'required': <String>['name'],
        },
        <String, Object?>{'name': 'a'},
      );
      expect(
        () => validateArguments(<String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'name': <String, Object?>{'type': 'string'},
          },
          'required': <String>['name'],
        }, <String, Object?>{}),
        throwsA(isA<AgentException>()),
      );
    });

    test(
      'unknown, malformed, denied, and failed tools stay sanitized',
      () async {
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(
                name: 'lookup',
                parameters: <String, Object?>{
                  'type': 'object',
                  'properties': <String, Object?>{
                    'q': <String, Object?>{'type': 'string'},
                  },
                  'required': <String>['q'],
                },
              ),
              executor: ScriptedToolExecutor((
                invocation, {
                required cancellation,
                required liveness,
              }) async {
                throw StateError('secret stack');
              }),
            ),
          );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[
            toolTurn(name: 'lookup', callId: 'c1', arguments: 'not-json'),
            toolTurn(name: 'missing', callId: 'c2', arguments: '{}'),
            toolTurn(name: 'lookup', callId: 'c3', arguments: '{}'),
            toolTurn(name: 'lookup', callId: 'c4', arguments: '{"q":"x"}'),
            textTurn('ok'),
          ],
        );
        final events =
            await testRuntime(
                  provider: provider,
                  tools: tools,
                  policies: <String, ToolPermissionPolicy>{
                    'deny': const DenyAllPolicy(),
                  },
                )
                .agent(
                  testDefinition(
                    tools: <ToolId>[ToolId('lookup')],
                    policy: PolicyId('deny'),
                  ),
                )
                .run('go')
                .events
                .toList();
        expect(events.last, isA<AgentRunCompleted>());
        expect(events.toString(), isNot(contains('secret stack')));
        expect(events.whereType<AgentToolFinished>(), isNotEmpty);
        expect(
          events.whereType<AgentToolFinished>().every(
            (event) => event.success == false,
          ),
          isTrue,
        );
      },
    );

    test('ask without handler denies; allow executes once', () async {
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
              liveness.reportProgress(detail: 'working');
              return ToolExecutionResult.success(<String, Object?>{'ok': true});
            }),
          ),
        );
      final askProvider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          toolTurn(name: 'lookup', callId: 'c1'),
          textTurn('done'),
        ],
      );
      await testRuntime(
            provider: askProvider,
            tools: tools,
            policies: <String, ToolPermissionPolicy>{'ask': const _AskPolicy()},
          )
          .agent(
            testDefinition(
              tools: <ToolId>[ToolId('lookup')],
              policy: PolicyId('ask'),
            ),
          )
          .run('go')
          .events
          .drain<void>();
      expect(executed, 0);

      final allowProvider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          toolTurn(name: 'lookup', callId: 'c1'),
          textTurn('done'),
        ],
      );
      final events = await testRuntime(provider: allowProvider, tools: tools)
          .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
          .run('go')
          .events
          .toList();
      expect(executed, 1);
      expect(events.whereType<AgentToolProgress>(), isNotEmpty);
    });

    test('sanitizes executor failures and progress details', () async {
      final tools = AgentToolRegistry()
        ..register(
          AgentTool(
            descriptor: LlmToolDescriptor(name: 'lookup'),
            executor: ScriptedToolExecutor((
              invocation, {
              required cancellation,
              required liveness,
            }) async {
              liveness.reportProgress(detail: 'sk-secret-openai leaked');
              return ToolExecutionResult.failure('StateError: secret stack');
            }),
          ),
        );
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          toolTurn(name: 'lookup', callId: 'c1'),
          textTurn('ok'),
        ],
      );
      final events = await testRuntime(provider: provider, tools: tools)
          .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
          .run('go')
          .events
          .toList();
      expect(events.toString(), isNot(contains('sk-secret')));
      expect(events.toString(), isNot(contains('secret stack')));
      expect(
        events.whereType<AgentToolProgress>().single.detail,
        'Tool reported progress.',
      );
    });

    test('cancels approval waits without executing the tool', () async {
      final approval = _HangingApproval();
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
        turns: <List<LlmEvent>>[toolTurn(name: 'lookup', callId: 'c1')],
      );
      final run =
          testRuntime(
                provider: provider,
                tools: tools,
                policies: <String, ToolPermissionPolicy>{
                  'ask': const _AskPolicy(),
                },
                approval: approval,
              )
              .agent(
                testDefinition(
                  tools: <ToolId>[ToolId('lookup')],
                  policy: PolicyId('ask'),
                ),
              )
              .run('go');
      await Future<void>.delayed(Duration.zero);
      await run.cancel();
      final events = await run.events.toList();
      expect(executed, 0);
      expect(events.last, isA<AgentRunCancelled>());
    });

    test(
      'cancel during tool executor does not run afterTool after terminal',
      () async {
        final started = Completer<void>();
        var afterTool = 0;
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(name: 'lookup'),
              executor: ScriptedToolExecutor((
                invocation, {
                required cancellation,
                required liveness,
              }) async {
                started.complete();
                await Completer<void>().future;
                return ToolExecutionResult.success(<String, Object?>{});
              }),
            ),
          );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[toolTurn(name: 'lookup', callId: 'c1')],
        );
        final run = testRuntime(
          provider: provider,
          tools: tools,
          hooks: <AgentLifecycleHook>[
            _CountingAfterToolHook(() {
              afterTool += 1;
            }),
          ],
        ).agent(testDefinition(tools: <ToolId>[ToolId('lookup')])).run('go');
        await started.future;
        await run.cancel();
        final events = await run.events.toList();
        expect(afterTool, 0);
        expect(events.last, isA<AgentRunCancelled>());
      },
    );

    test('executor AgentException becomes a sanitized tool result', () async {
      final tools = AgentToolRegistry()
        ..register(
          AgentTool(
            descriptor: LlmToolDescriptor(name: 'lookup'),
            executor: ScriptedToolExecutor((
              invocation, {
              required cancellation,
              required liveness,
            }) async {
              throw AgentException(
                AgentError(
                  kind: AgentErrorKind.runtime,
                  message: 'sk-secret-openai leaked',
                ),
              );
            }),
          ),
        );
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          toolTurn(name: 'lookup', callId: 'c1'),
          textTurn('ok'),
        ],
      );
      final events = await testRuntime(provider: provider, tools: tools)
          .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
          .run('go')
          .events
          .toList();
      expect(events.last, isA<AgentRunCompleted>());
      expect(events.toString(), isNot(contains('sk-secret')));
      expect(events.whereType<AgentToolFinished>().single.success, isFalse);
    });

    test('approval AgentException becomes a sanitized tool result', () async {
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
          textTurn('ok'),
        ],
      );
      final events =
          await testRuntime(
                provider: provider,
                tools: tools,
                policies: <String, ToolPermissionPolicy>{
                  'ask': const _AskPolicy(),
                },
                approval: _ThrowingApproval(),
              )
              .agent(
                testDefinition(
                  tools: <ToolId>[ToolId('lookup')],
                  policy: PolicyId('ask'),
                ),
              )
              .run('go')
              .events
              .toList();
      expect(events.last, isA<AgentRunCompleted>());
      expect(events.whereType<AgentToolStarted>(), isEmpty);
    });

    test(
      'afterTool runs after executor failure and hook failure wins',
      () async {
        var afterTool = 0;
        final tools = AgentToolRegistry()
          ..register(
            AgentTool(
              descriptor: LlmToolDescriptor(name: 'lookup'),
              executor: ScriptedToolExecutor((
                invocation, {
                required cancellation,
                required liveness,
              }) async {
                throw StateError('executor exploded');
              }),
            ),
          );
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[toolTurn(name: 'lookup', callId: 'c1')],
        );
        final events =
            await testRuntime(
                  provider: provider,
                  tools: tools,
                  hooks: <AgentLifecycleHook>[
                    _CountingAfterToolHook(() {
                      afterTool += 1;
                      throw StateError('hook exploded');
                    }),
                  ],
                )
                .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
                .run('go')
                .events
                .toList();
        expect(afterTool, 1);
        expect(
          (events.last as AgentRunFailed).error.kind,
          AgentErrorKind.runtime,
        );
      },
    );

    test('hooks run in order and hook failure is a runtime error', () async {
      final log = <String>[];
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
      final ok =
          await testRuntime(
                provider: provider,
                tools: tools,
                hooks: <AgentLifecycleHook>[
                  _LogHook(log, 'a'),
                  _LogHook(log, 'b'),
                ],
              )
              .agent(testDefinition(tools: <ToolId>[ToolId('lookup')]))
              .run('go')
              .events
              .toList();
      expect(
        log,
        containsAllInOrder(<String>['a:beforeModel', 'b:beforeModel']),
      );
      expect(ok.last, isA<AgentRunCompleted>());

      final failingProvider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('x')],
      );
      final failed = await testRuntime(
        provider: failingProvider,
        hooks: <AgentLifecycleHook>[_ThrowingHook()],
      ).agent(testDefinition()).run('go').events.toList();
      expect(
        (failed.last as AgentRunFailed).error.kind,
        AgentErrorKind.runtime,
      );
    });
  });
}

final class _HangingApproval implements ToolApprovalHandler {
  final Completer<bool> _completer = Completer<bool>();

  @override
  Future<bool> approve(ToolInvocation invocation) => _completer.future;
}

final class _AskPolicy implements ToolPermissionPolicy {
  const _AskPolicy();

  @override
  PolicyId get id => PolicyId('ask');

  @override
  ToolPermission decide(ToolInvocation invocation) => ToolPermission.ask;
}

final class _LogHook extends AgentLifecycleHookBase {
  _LogHook(this.log, this.name);

  final List<String> log;
  final String name;

  @override
  Future<void> beforeModelTurn(AgentHookContext context) async {
    log.add('$name:beforeModel');
  }
}

final class _ThrowingHook extends AgentLifecycleHookBase {
  @override
  Future<void> beforeModelTurn(AgentHookContext context) async {
    throw StateError('hook exploded');
  }
}

final class _ThrowingApproval implements ToolApprovalHandler {
  @override
  Future<bool> approve(ToolInvocation invocation) {
    throw AgentException(
      AgentError(
        kind: AgentErrorKind.runtime,
        message: 'approval sk-secret failed',
      ),
    );
  }
}

final class _CountingAfterToolHook extends AgentLifecycleHookBase {
  _CountingAfterToolHook(this.onAfter);

  final void Function() onAfter;

  @override
  Future<void> afterTool(AgentHookContext context) async {
    onAfter();
  }
}

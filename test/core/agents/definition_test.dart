import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  group('AgentDefinition', () {
    test('round-trips serializable fields without secrets', () {
      final definition = AgentDefinition(
        id: AgentId('writer'),
        name: 'Writer',
        systemPrompt: 'Write carefully.',
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
        initialMessages: <LlmMessage>[
          LlmMessage(
            role: LlmMessageRole.user,
            parts: <LlmContentPart>[LlmTextPart('hello')],
          ),
        ],
        generation: LlmGenerationConfig(temperature: 0.2, maxOutputTokens: 16),
        enabledTools: <ToolId>[ToolId('lookup')],
        policy: PolicyId('allow'),
        limits: AgentRunLimits(maxModelTurns: 3, maxToolCalls: 0),
        liveness: AgentLivenessPolicy(idleTimeout: const Duration(minutes: 2)),
        noProgress: AgentNoProgressPolicy(
          warningThreshold: 2,
          stopThreshold: 4,
        ),
        budget: AgentTokenBudget(totalTokens: 100),
      );
      final restored = AgentDefinition.fromJson(definition.toJson());
      expect(restored, definition);
      expect(definition.toJson().toString(), isNot(contains('sk-')));
    });

    test('omitted productive quotas are unspecified', () {
      final definition = testDefinition();
      expect(definition.limits, isNull);
      expect(definition.budget, isNull);
      expect(definition.liveness, isNull);
      expect(definition.noProgress, isNull);
    });

    test('rejects invalid finite limits', () {
      expect(
        () => AgentRunLimits(maxModelTurns: 0),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentRunLimits(maxToolCalls: -1),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentRunLimits(maxDuration: Duration.zero),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentLivenessPolicy(idleTimeout: Duration.zero),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentNoProgressPolicy(warningThreshold: 5, stopThreshold: 5),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => AgentTokenBudget(inputTokens: -2),
        throwsA(isA<AgentException>()),
      );
    });

    test('opening a session fails for missing resources', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(
        testDefinition(tools: <ToolId>[ToolId('missing')]),
      );
      await expectLater(agent.createSession(), throwsA(isA<AgentException>()));
    });
  });

  test(
    'core/agents does not import Flutter, http, dart:io, or secure storage',
    () {
      final directory = Directory('lib/core/agents');
      expect(directory.existsSync(), isTrue);
      for (final entity in directory.listSync()) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        for (final line in source.split('\n')) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('import ')) {
            continue;
          }
          expect(
            trimmed.contains('dart:io') ||
                trimmed.contains('package:flutter') ||
                trimmed.contains('package:http') ||
                trimmed.contains('flutter_secure_storage'),
            isFalse,
            reason: '${entity.path} imports $trimmed',
          );
        }
      }
    },
  );
}

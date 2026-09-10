import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/scripted_llm_provider.dart';

void main() {
  group('session messaging', () {
    test('rejects non-positive router bounds', () {
      expect(
        () => InMemorySessionRouter(capacity: 0),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => InMemorySessionRouter(capacity: -1),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => InMemorySessionRouter(closedTrackingLimit: 0),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => InMemorySessionRouter(closedTrackingLimit: -8),
        throwsA(isA<AgentException>()),
      );
    });

    test('delivery receipts round-trip and reject malformed JSON', () {
      final receipt = DeliveryReceipt(
        status: DeliveryStatus.queued,
        messageId: MessageId('m1'),
        correlationId: CorrelationId('c1'),
      );
      expect(DeliveryReceipt.fromJson(receipt.toJson()), receipt);
      expect(
        () => DeliveryReceipt.fromJson(<String, Object?>{
          'type': DeliveryReceipt.jsonType,
          'version': 1.0,
          'status': 'queued',
          'messageId': MessageId('m1').toJson(),
        }),
        throwsA(anything),
      );
    });

    test(
      'queues FIFO correlated messages and consumes them at safe boundaries',
      () async {
        final provider = QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: <List<LlmEvent>>[textTurn('one'), textTurn('two')],
        );
        final runtime = testRuntime(provider: provider);
        final agent = runtime.agent(testDefinition());
        final source = await agent.createSession();
        final target = await agent.createSession();
        final first = await runtime.router.send(
          SessionEnvelope(
            id: MessageId('m1'),
            source: source.id,
            target: target.id,
            payload: LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('alpha')],
            ),
            acceptedAtMicros: 1,
            correlationId: CorrelationId('corr'),
          ),
        );
        final second = await runtime.router.send(
          SessionEnvelope(
            id: MessageId('m2'),
            source: source.id,
            target: target.id,
            payload: LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('beta')],
            ),
            acceptedAtMicros: 2,
            correlationId: CorrelationId('corr'),
            replyTo: MessageId('m1'),
          ),
          preference: DeliveryPreference.preferSteer,
        );
        expect(first.status, DeliveryStatus.queued);
        expect(second.status, DeliveryStatus.queued);
        final events = await target.run('prompt').events.toList();
        final inbound = events
            .whereType<AgentInboundMessageConsumed>()
            .toList();
        expect(inbound, hasLength(2));
        expect(
          (inbound.first.message.parts.single as LlmTextPart).text,
          'alpha',
        );
        expect(inbound.first.correlationId, CorrelationId('corr'));
        expect(inbound.last.replyTo, MessageId('m1'));
        expect(provider.requests.first.context.messages, hasLength(3));
        await source.close();
        await target.close();
      },
    );

    test(
      'busy run does not consume until the next run after a final turn',
      () async {
        final gate = Completer<void>();
        final provider = ScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          events: const <LlmEvent>[LlmTextDelta('busy')],
          gate: gate,
        );
        final runtime = testRuntime(provider: provider);
        final agent = runtime.agent(testDefinition());
        final source = await agent.createSession();
        final target = await agent.createSession();
        final run = target.run('go');
        await Future<void>.delayed(Duration.zero);
        final receipt = await runtime.router.send(
          SessionEnvelope(
            id: MessageId('late'),
            source: source.id,
            target: target.id,
            payload: LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart('queued-late')],
            ),
            acceptedAtMicros: 3,
          ),
        );
        expect(receipt.status, DeliveryStatus.queued);
        gate.complete();
        await run.events.drain<void>();
        expect(runtime.router.queuedCount(target.id), 1);
        await source.close();
        await target.close();
      },
    );

    test('rejects unknown, closed, and full mailboxes', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final router = InMemorySessionRouter(capacity: 1);
      final runtime = testRuntime(provider: provider, router: router);
      final agent = runtime.agent(testDefinition());
      final source = await agent.createSession();
      final target = await agent.createSession();
      Future<DeliveryReceipt> sendTo(AgentSessionId id, String text) {
        return runtime.router.send(
          SessionEnvelope(
            id: MessageId(text),
            source: source.id,
            target: id,
            payload: LlmMessage(
              role: LlmMessageRole.user,
              parts: <LlmContentPart>[LlmTextPart(text)],
            ),
            acceptedAtMicros: 1,
          ),
        );
      }

      expect(
        (await sendTo(AgentSessionId('missing'), 'x')).rejection,
        RejectionReason.unknown,
      );
      expect((await sendTo(target.id, 'one')).status, DeliveryStatus.queued);
      expect((await sendTo(target.id, 'two')).rejection, RejectionReason.full);
      await target.close();
      expect(
        (await sendTo(target.id, 'three')).rejection,
        RejectionReason.closed,
      );
      await source.close();
    });

    test('restored session has an empty mailbox', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[textTurn('ok')],
      );
      final runtime = testRuntime(provider: provider);
      final agent = runtime.agent(testDefinition());
      final source = await agent.createSession();
      final target = await agent.createSession(
        persistence: SessionPersistence.repository,
      );
      await runtime.router.send(
        SessionEnvelope(
          id: MessageId('keep'),
          source: source.id,
          target: target.id,
          payload: LlmMessage(
            role: LlmMessageRole.user,
            parts: <LlmContentPart>[LlmTextPart('queued')],
          ),
          acceptedAtMicros: 1,
        ),
      );
      final id = target.id;
      await target.close();
      final restored = await agent.restoreSession(id);
      expect(runtime.router.queuedCount(id), 0);
      await restored.close();
      await source.close();
    });
  });
}

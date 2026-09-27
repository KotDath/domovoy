import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/infrastructure/automation_chat/automation_chat.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';

void main() {
  AutomationChatDelivery card() => AutomationChatDelivery(
    chatId: 'chat-one',
    runId: 'ran_0000000000000001',
    taskId: 'atm_0000000000000001',
    taskName: 'Исследование',
    status: AutomationRunStatus.succeeded,
    resultText: 'Готовая подборка',
    deliveredAt: DateTime.utc(2026, 1, 1),
  );

  test('concurrent retry and reopen preserve one separate card', () async {
    final storage = FakeMemoryJsonlStorage();
    final first = JsonlAutomationChatDeliveryStore(storage: storage);
    final writes = await Future.wait([
      first.saveIfAbsent(card()),
      first.saveIfAbsent(card()),
    ]);
    expect(writes.where((write) => write.created), hasLength(1));
    expect(storage.keys, hasLength(1));
    first.dispose();

    final reopened = JsonlAutomationChatDeliveryStore(storage: storage);
    final cards = await reopened.deliveriesForChat('chat-one');
    expect(cards, hasLength(1));
    expect(cards.single.resultText, 'Готовая подборка');
    expect(cards.single.cardRef, isNot(cards.single.reference));
    expect((await reopened.saveIfAbsent(card())).deduplicated, isTrue);
    expect(await reopened.deliveriesForChat('chat-other'), isEmpty);
    reopened.dispose();
  });

  test('corrupt version fails visibly on replay', () async {
    final storage = FakeMemoryJsonlStorage();
    final store = JsonlAutomationChatDeliveryStore(storage: storage);
    await store.saveIfAbsent(card());
    final key = card().deliveryId;
    storage.replaceText(
      key,
      '{"type":"domovoy.automation_chat_delivery","version":2}\n',
    );
    await expectLater(
      store.deliveriesForChat('chat-one'),
      throwsA(isA<AutomationException>()),
    );
    store.dispose();
  });
}

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/features/tasks/tasks.dart';
import 'package:domovoy/infrastructure/automation_chat/automation_chat.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/automation_fakes.dart';
import '../../../support/memory_jsonl_storage.dart';

final class _ChatExistence implements TasksChatExistence {
  bool exists = true;
  @override
  Future<bool> chatExists(String chatId) async => exists;
}

final class _FailingSessionRepository extends Fake
    implements AgentSessionRepository {
  @override
  Future<AgentSessionRecord?> load(AgentSessionId id) async =>
      throw StateError('storage unavailable');
}

void main() {
  test(
    'delivery retry is idempotent and missing chat remains undelivered',
    () async {
      final repository = InMemoryAutomationRepository();
      final cards = JsonlAutomationChatDeliveryStore(
        storage: FakeMemoryJsonlStorage(),
      );
      final existence = _ChatExistence();
      final sink = AutomationChatDeliverySink(
        store: cards,
        chatExists: existence,
        tasks: repository,
      );
      final service = AutomationService(
        tasks: repository,
        runs: repository,
        executor: ScriptedAutomationExecutor(),
        timeZones: automationTestZones(),
        clock: FakeAutomationClock(DateTime.utc(2026, 1, 1, 12)),
        ids: SequentialAutomationIdGenerator(),
        delivery: sink,
      );
      await service.start();
      final task = await service.createTask(
        automationDraft(
          allowedToolIds: ['mcp_arxiv_search_papers'],
          delivery: const AutomationDelivery.chat('chat-one'),
        ),
      );
      final first = await (await service.runTaskNow(task.taskId)).done;
      expect(first.delivery?.delivered, isTrue);
      expect(
        first.delivery?.reference,
        startsWith('domovoy://automation/chat/'),
      );
      final retried = await sink.deliver(
        target: const AutomationDelivery.chat('chat-one'),
        run: first,
      );
      expect(retried?.delivered, isTrue);
      expect(await cards.deliveriesForChat('chat-one'), hasLength(1));

      final unavailable = await AutomationChatDeliverySink(
        store: cards,
        chatExists: SessionRepositoryChatExistence(_FailingSessionRepository()),
      ).deliver(target: const AutomationDelivery.chat('chat-one'), run: first);
      expect(unavailable?.delivered, isFalse);
      expect(unavailable?.error, contains('Не удалось проверить чат'));

      existence.exists = false;
      final missing = await (await service.runTaskNow(task.taskId)).done;
      expect(missing.delivery?.delivered, isFalse);
      expect(missing.delivery?.error, contains('не найден'));
      expect(await cards.deliveriesForChat('chat-one'), hasLength(1));
      await service.dispose();
      cards.dispose();
    },
  );
}

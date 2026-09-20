import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/personalization/personalization.dart';
import 'package:domovoy/infrastructure/personalization/personalization.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/memory_jsonl_storage.dart';

void main() {
  test('uses the newly active profile on the next request', () async {
    final storage = FakeMemoryJsonlStorage();
    final repository = JsonlProfileRepository(storage: storage);
    final cancellation = CancellationSource().token;
    final first = AssistantProfile(
      id: ProfileId('concise'),
      name: 'Кратко',
      revision: 0,
      soulMarkdown: defaultSoulMarkdown,
      userMarkdown: '''## STYLE
- marker: CONCISE_PROFILE
## FORMAT
- bullets
## CONSTRAINTS
- none
## CONTEXT
- test''',
      createdAtMicros: 1,
      updatedAtMicros: 1,
    );
    final second = AssistantProfile(
      id: ProfileId('detailed'),
      name: 'Подробно',
      revision: 0,
      soulMarkdown: defaultSoulMarkdown,
      userMarkdown: '''## STYLE
- marker: DETAILED_PROFILE
## FORMAT
- prose
## CONSTRAINTS
- none
## CONTEXT
- test''',
      createdAtMicros: 2,
      updatedAtMicros: 2,
    );
    await repository.save(
      first,
      expectedRevision: 0,
      cancellation: cancellation,
    );
    await repository.save(
      second,
      expectedRevision: 0,
      cancellation: cancellation,
    );
    await repository.saveActive(
      ActiveProfileSelection(profileId: first.id, revision: 0),
      expectedRevision: 0,
      cancellation: cancellation,
    );
    final catalog = ProfileCatalogService(
      profiles: repository,
      activeProfile: repository,
      nowMicros: () => 3,
    );
    final provider = QueueScriptedLlmProvider(
      id: BuiltInLlmCatalog.deepSeek,
      wireFamily: LlmWireFamily.openaiChatCompletions,
      turns: <List<LlmEvent>>[textTurn('one'), textTurn('two')],
    );
    final runtime = testRuntime(
      provider: provider,
      dynamicContextProvider: PersonalizationDynamicContextProvider(
        catalog: catalog,
      ),
    );

    final firstEvents = await runtime
        .agent(testDefinition())
        .run('first')
        .events
        .toList();
    await repository.saveActive(
      ActiveProfileSelection(profileId: second.id, revision: 1),
      expectedRevision: 0,
      cancellation: cancellation,
    );
    final secondEvents = await runtime
        .agent(testDefinition())
        .run('second')
        .events
        .toList();

    expect(
      provider.requests[0].context.systemPrompt,
      contains('CONCISE_PROFILE'),
    );
    expect(
      provider.requests[0].context.systemPrompt,
      isNot(contains('DETAILED_PROFILE')),
    );
    expect(
      provider.requests[1].context.systemPrompt,
      contains('DETAILED_PROFILE'),
    );
    expect(
      firstEvents.whereType<AgentDynamicContextEvent>().single.audit,
      isA<ProfileContextTrace>(),
    );
    expect(
      secondEvents.whereType<AgentDynamicContextEvent>().single.audit,
      isA<ProfileContextTrace>(),
    );
    await runtime.close();
  });

  test('composite provider preserves profile before memory', () async {
    final composite = CompositeAgentDynamicContextProvider([
      _StaticContext('PROFILE', 1),
      _StaticContext('MEMORY', 2),
    ]);
    final result = await composite.provide(
      AgentDynamicContextRequest(
        sessionId: AgentSessionId('session'),
        projectId: null,
        query: 'hello',
      ),
    );

    expect(result?.systemPromptText, 'PROFILE\n\nMEMORY');
    final audit = result?.audit! as CompositeAgentDynamicContextAudit;
    expect(audit.firstOfType<int>(), 1);
  });
}

final class _StaticContext implements AgentDynamicContextProvider {
  const _StaticContext(this.text, this.audit);

  final String text;
  final int audit;

  @override
  Future<AgentDynamicContext?> provide(
    AgentDynamicContextRequest request,
  ) async => AgentDynamicContext(systemPromptText: text, audit: audit);
}

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/support/support.dart';
import 'package:domovoy/features/chat/application/chat_workspace_controller.dart';
import 'package:domovoy/features/support/application/support_catalog.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_agent_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/agent_harness.dart';
import '../../../support/memory_jsonl_storage.dart';

void main() {
  for (final support in [true, false]) {
    for (final longHistory in [true, false]) {
      test(
        'production model switch preserves support privacy and ordinary compaction (support=$support, long=$longHistory)',
        () async {
          final provider = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: [
              textTurn(
                '{"objective":"summary","constraintsAndDecisions":[],"facts":[],"relevantToolOutcomes":[],"pendingWork":[]}',
              ),
            ],
          );
          final target = QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.openAi,
            wireFamily: LlmWireFamily.openaiResponses,
            turns: [],
          );
          final registry = LlmProviderRegistry();
          BuiltInLlmCatalog.registerInto(registry);
          registry.registerProvider(provider);
          registry.registerProvider(target);
          final sessions = JsonlAgentSessionStore(
            storage: FakeMemoryJsonlStorage(),
          );
          final runtime = InMemoryAgentRuntime(
            registry: registry,
            repository: sessions,
            tools: AgentToolRegistry(),
            policies: {'support': SupportToolPolicy(SupportRunScopes())},
            historyCompactor: OpenCodeSummaryCompactor(
              llm: RegistryAgentSummaryLlmInvocation(registry),
            ),
          );
          addTearDown(runtime.close);
          final definition = supportDefinition(
            BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
          );
          final created = await runtime
              .agent(definition)
              .createSession(
                id: AgentSessionId(
                  support ? 'support-${'a' * 48}' : 'ordinary-model-switch',
                ),
                persistence: SessionPersistence.repository,
              );
          final id = created.id;
          await created.close();
          final previous = (await sessions.load(id))!;
          await sessions.save(
            previous.copyWith(
              revision: previous.revision + 1,
              transcript: AgentTranscript(
                messages: [
                  LlmMessage(
                    role: LlmMessageRole.user,
                    parts: [LlmTextPart('x' * (longHistory ? 600000 : 100))],
                  ),
                  LlmMessage(
                    role: LlmMessageRole.assistant,
                    parts: [
                      LlmToolCallPart(
                        callId: ToolCallId('old'),
                        name: 'mcp_support__get_ticket',
                        arguments: '{}',
                      ),
                    ],
                  ),
                  LlmMessage(
                    role: LlmMessageRole.tool,
                    parts: [
                      LlmToolResultPart(
                        callId: ToolCallId('old'),
                        content: 'OLD_SUPPORT_TOOL_PAYLOAD_DO_NOT_REUSE',
                      ),
                    ],
                  ),
                  LlmMessage(
                    role: LlmMessageRole.assistant,
                    parts: [LlmTextPart('Old answer')],
                  ),
                  LlmMessage(
                    role: LlmMessageRole.user,
                    parts: [LlmTextPart('Recent question')],
                  ),
                  LlmMessage(
                    role: LlmMessageRole.assistant,
                    parts: [LlmTextPart('Recent answer')],
                  ),
                ],
              ),
            ),
            expectedRevision: previous.revision,
            cancellation: CancellationSource().token,
          );
          final chat = ChatWorkspaceController(
            runtime: runtime,
            definition: definition,
            catalog: SupportSessionCatalog(sessions, support: support),
            repository: sessions,
            registry: registry,
            supportMode: support,
          );
          addTearDown(chat.dispose);
          // Ordinary selection exercises the same retained transcript with a regular ID.
          expect((await chat.restoreChat(id)).isSuccess, true);
          final before = (await sessions.load(id))!;
          final result = await chat.changeSelection(
            AgentSessionSelection(
              model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
              reasoningMode: ReasoningMode.disabled,
              reasoningEffort: ReasoningEffort.modelDefault,
            ),
          );
          final after = (await sessions.load(id))!;
          if (support && longHistory) {
            expect(result.isSuccess, false);
            expect(
              chat.state.error!.message,
              contains('модель с большим контекстом'),
            );
            expect(provider.requests, isEmpty);
            expect(target.requests, isEmpty);
            expect(after.toJson(), before.toJson());
            expect(chat.state.selectedSession!.selection, before.selection);
            // A rejected switch cannot trigger another dispatch or deferred rewrite.
            await Future<void>.delayed(Duration.zero);
            expect(provider.requests, isEmpty);
            expect((await sessions.load(id))!.toJson(), before.toJson());
          } else {
            expect(result.isSuccess, true);
            expect(provider.requests, hasLength(longHistory ? 1 : 0));
            expect(target.requests, isEmpty);
            expect(after.selection.model, BuiltInLlmCatalog.gpt4oMiniModel.ref);
            if (longHistory) {
              expect(
                after.transcript.messages.length,
                lessThan(before.transcript.messages.length),
              );
            } else {
              expect(after.transcript.toJson(), before.transcript.toJson());
            }
          }
        },
      );
    }
  }
}

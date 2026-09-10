import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';

/// Feature-only prompt workspace policy. These finite quotas are not the
/// global agent-runtime defaults.
final class PromptWorkspace {
  static final AgentId agentId = AgentId('prompt-workspace');

  static final AgentRunLimits limits = AgentRunLimits(
    maxModelTurns: 1,
    maxToolCalls: 0,
  );

  static AgentDefinition definition({
    ReasoningMode reasoningMode = ReasoningMode.enabled,
  }) {
    return AgentDefinition(
      id: agentId,
      name: 'Prompt workspace',
      systemPrompt: '',
      model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      generation: LlmGenerationConfig(reasoningMode: reasoningMode),
      enabledTools: const <ToolId>[],
      policy: PolicyId('deny'),
      limits: limits,
    );
  }

  static AgentDefinition snapshotReasoning(
    AgentDefinition definition,
    ReasoningMode reasoningMode,
  ) {
    return AgentDefinition(
      id: definition.id,
      name: definition.name,
      systemPrompt: definition.systemPrompt,
      initialMessages: definition.initialMessages,
      model: definition.model,
      generation: LlmGenerationConfig(
        reasoningMode: reasoningMode,
        reasoningEffort: ReasoningEffort.modelDefault,
        temperature: definition.generation.temperature,
        maxOutputTokens: definition.generation.maxOutputTokens,
      ),
      enabledTools: definition.enabledTools,
      policy: definition.policy,
      limits: definition.limits,
      liveness: definition.liveness,
      noProgress: definition.noProgress,
      budget: definition.budget,
    );
  }
}

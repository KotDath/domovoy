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

  static final AgentRunLimits interactiveLimits = AgentRunLimits(
    maxModelTurns: 10000,
    maxToolCalls: 10000,
  );

  static AgentDefinition definition({
    ReasoningMode reasoningMode = ReasoningMode.enabled,
    List<ToolId> enabledTools = const <ToolId>[],
    PolicyId? policy,
    AgentRunLimits? runLimits,
  }) {
    return AgentDefinition(
      id: agentId,
      name: 'Prompt workspace',
      systemPrompt: '',
      model: BuiltInLlmCatalog.deepSeekFlashModel.ref,
      generation: LlmGenerationConfig(reasoningMode: reasoningMode),
      enabledTools: enabledTools,
      policy: policy ?? PolicyId('deny'),
      limits: runLimits ?? limits,
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

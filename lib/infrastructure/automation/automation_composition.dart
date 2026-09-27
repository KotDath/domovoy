import '../../core/agents/agents.dart';
import '../../core/automation/automation.dart';
import '../../core/llm/llm.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';
import 'agent_session_automation_executor.dart';
import 'automation_jsonl_store.dart';
import 'system_clock.dart';
import 'time_zone_database.dart';

/// Composition-ready bundle of the automation subsystem.
final class AutomationStack {
  const AutomationStack({
    required this.store,
    required this.executor,
    required this.timeZones,
    required this.service,
  });

  /// Durable task and run history; the only automation store of the app.
  final JsonlAutomationStore store;

  final AgentSessionAutomationExecutor executor;
  final PackageAutomationTimeZones timeZones;

  /// The application service shared by the tasks UI and the MCP server.
  final AutomationService service;
}

/// Builds the production automation stack over an injected runtime.
///
/// B9 calls this once and registers the `automation` MCP server with
/// [AutomationMcpServerFactory] over `stack.service`; B8 uses the same service
/// for the tasks UI, so there is exactly one scheduler and one task store.
///
/// [policies] must be the live policy table of [runtime] (for the production
/// `InMemoryAgentRuntime` this is `runtime.policies`): the executor installs a
/// scheduled-task grant per run and the runtime resolves it by policy id.
AutomationStack buildAutomationStack({
  required JsonlStreamStorage storage,
  required AgentRuntime runtime,
  required Map<String, ToolPermissionPolicy> policies,
  required LlmProviderRegistry models,
  required AgentToolRegistry tools,
  ProviderCredentialResolver? credentials,
  AgentRunToolContextFactory? runToolContexts,
  AutomationLimits limits = const AutomationLimits(),
  AutomationResultDelivery? delivery,
  AutomationClock? clock,
  AutomationIdGenerator? ids,
}) {
  final validated = limits.validate();
  final store = JsonlAutomationStore(storage: storage, limits: validated);
  final timeZones = PackageAutomationTimeZones();
  final executor = AgentSessionAutomationExecutor(
    runtime: runtime,
    models: models,
    tools: tools,
    policies: policies,
    credentials: credentials,
    runToolContexts: runToolContexts,
    runLimits: validated.run,
  );
  final service = AutomationService(
    tasks: store,
    runs: store,
    executor: executor,
    timeZones: timeZones,
    clock: clock ?? const SystemAutomationClock(),
    limits: validated,
    delivery: delivery,
    ids: ids,
  );
  return AutomationStack(
    store: store,
    executor: executor,
    timeZones: timeZones,
    service: service,
  );
}

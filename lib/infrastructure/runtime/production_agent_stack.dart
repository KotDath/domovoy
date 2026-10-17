import 'dart:math';
import 'package:http/http.dart' as http;
import '../../core/agents/agents.dart';
import '../../core/llm/llm.dart';
import '../../features/prompt/domain/prompt_workspace.dart';
import '../agents/jsonl/jsonl_agent_session_store.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';
import '../llm/openai_compatible/openai_compatible.dart';
import '../llm/openai_responses/openai_responses.dart';
import '../llm/discovery/native_streaming_provider.dart';
import '../llm/discovery/provider_manifest.dart';
import '../llm/discovery/provider_model_catalog.dart';

final class ProductionAgentStack {
  ProductionAgentStack({
    required this.registry,
    required this.runtime,
    required this.promptDefinition,
    required this.credentials,
    required this.repository,
    required this.catalog,
    this.providerModelCatalog,
  });

  final LlmProviderRegistry registry;
  final InMemoryAgentRuntime runtime;
  final AgentDefinition promptDefinition;
  final ProviderCredentialResolver credentials;
  final AgentSessionRepository repository;
  final AgentSessionCatalog catalog;
  final ProviderModelCatalog? providerModelCatalog;
}

ProductionAgentStack buildProductionAgentStack({
  required http.Client httpClient,
  required ProviderCredentialResolver credentials,
  AgentSessionRepository? repository,
  AgentSessionCatalog? catalog,
  bool diagnosticNoCompaction = false,
  AgentIdFactory? ids,
  AgentDynamicContextProvider? dynamicContextProvider,
  AgentToolRegistry? tools,
  List<ToolId> enabledTools = const <ToolId>[],
  ToolPermissionPolicy? interactivePolicy,
  JsonlStreamStorage? storage,
  Future<String> Function()? loadBundled,
  Future<String?> Function()? readCached,
  Future<void> Function(String)? writeCached,
}) {
  if ((repository == null) != (catalog == null)) {
    throw ArgumentError(
      'Repository and catalog replacements must be supplied together.',
    );
  }
  if (interactivePolicy != null && interactivePolicy.id != PolicyId('allow')) {
    throw ArgumentError.value(
      interactivePolicy.id.value,
      'interactivePolicy',
      'The interactive policy must keep the stable "allow" id so existing '
          'sessions resolve it without a migration.',
    );
  }
  final durableStore = repository == null
      ? JsonlAgentSessionStore(
          storage:
              storage ?? (throw ArgumentError('Durable storage is required')),
        )
      : null;
  final resolvedRepository = repository ?? durableStore!;
  final resolvedCatalog = catalog ?? durableStore!;
  final registry = LlmProviderRegistry();
  final compatibleProfiles = <String, OpenAiCompatibleProfile>{};
  final responseProfiles = <String, OpenAiResponsesProfile>{};
  for (final spec in ApiKeyProviderManifest.entries) {
    final initial = BuiltInLlmCatalog.models
        .where((model) => model.providerId.value == spec.id)
        .toList(growable: false);
    registry.registerProfile(spec.profile);
    switch (spec.protocol) {
      case ApiKeyProviderProtocol.chatCompletions:
        final profile = OpenAiCompatibleProfile.builtInDynamic(
          snapshot: spec.profile,
          models: initial,
          dialectFor: (modelId) {
            if (spec.id == 'deepseek' || spec.id == 'moonshotai') {
              final builtIn = ChatCompletionsDialect.forBuiltInModel(modelId);
              if (builtIn != ChatCompletionsDialect.generic) return builtIn;
            }
            return _dialectForReasoningFormat(spec.reasoningFormat);
          },
          sessionAffinityHeader: spec.sessionAffinityHeader,
        );
        compatibleProfiles[spec.id] = profile;
        registry.registerProvider(
          OpenAiChatCompletionsLlmProvider(
            profile: profile,
            client: httpClient,
            credentials: credentials,
          ),
        );
      case ApiKeyProviderProtocol.responses:
        final profile = OpenAiResponsesProfile(
          snapshot: spec.profile,
          models: initial,
          allowEmptyModels: true,
        );
        responseProfiles[spec.id] = profile;
        registry.registerProvider(
          OpenAiResponsesLlmProvider(
            profile: profile,
            client: httpClient,
            credentials: credentials,
          ),
        );
      case ApiKeyProviderProtocol.anthropicMessages:
      case ApiKeyProviderProtocol.geminiGenerateContent:
        registry.registerProvider(
          NativeStreamingLlmProvider(
            spec: spec,
            client: httpClient,
            credentials: credentials,
          ),
        );
    }
  }
  registry.replaceModels(BuiltInLlmCatalog.models);
  final providerModelCatalog = ProviderModelCatalog(
    loadBundled: loadBundled,
    readCached: readCached,
    writeCached: writeCached,
    client: httpClient,
    credentials: credentials,
    publishModels: (models) {
      registry.replaceModels(models);
      for (final entry in compatibleProfiles.entries) {
        entry.value.replaceModels(
          models
              .where((model) => model.providerId.value == entry.key)
              .toList(growable: false),
        );
      }
      for (final entry in responseProfiles.entries) {
        entry.value.replaceModels(
          models
              .where((model) => model.providerId.value == entry.key)
              .toList(growable: false),
        );
      }
    },
  );
  const contextEstimator = Utf8FramingAgentContextEstimator();
  final compactionTrigger = OpenCodeCompactionTrigger();
  final modelSwitchFitPolicy = OpenCodeAgentModelSwitchFitPolicy();
  final historyCompactor = OpenCodeSummaryCompactor(
    llm: RegistryAgentSummaryLlmInvocation(registry),
    contextEstimator: contextEstimator,
  );
  final interactiveTools = enabledTools.isNotEmpty || interactivePolicy != null;
  final runtime = InMemoryAgentRuntime(
    registry: registry,
    tools: tools ?? AgentToolRegistry(),
    policies: <String, ToolPermissionPolicy>{
      'deny': const DenyAllPolicy(),
      'allow': interactivePolicy ?? const AllowAllPolicy(),
    },
    repository: resolvedRepository,
    router: InMemorySessionRouter(),
    profile: AgentRuntimeProfile(),
    contextEstimator: contextEstimator,
    compactionTrigger: diagnosticNoCompaction ? null : compactionTrigger,
    modelSwitchFitPolicy: modelSwitchFitPolicy,
    historyCompactor: diagnosticNoCompaction ? null : historyCompactor,
    ids: ids ?? AgentIdFactory(namespace: _newRuntimeNamespace()),
    dynamicContextProvider: dynamicContextProvider,
  );
  return ProductionAgentStack(
    registry: registry,
    runtime: runtime,
    promptDefinition: PromptWorkspace.definition(
      enabledTools: enabledTools,
      policy: interactiveTools ? PolicyId('allow') : PolicyId('deny'),
      runLimits: PromptWorkspace.interactiveLimits,
    ),
    credentials: credentials,
    repository: resolvedRepository,
    catalog: resolvedCatalog,
    providerModelCatalog: providerModelCatalog,
  );
}

ChatCompletionsDialect _dialectForReasoningFormat(
  ApiKeyProviderReasoningFormat format,
) => switch (format) {
  ApiKeyProviderReasoningFormat.none => ChatCompletionsDialect.generic,
  ApiKeyProviderReasoningFormat.openAiEffort =>
    ChatCompletionsDialect.openAiReasoningEffort,
  ApiKeyProviderReasoningFormat.deepSeekThinking =>
    ChatCompletionsDialect.catalogDeepSeekThinking,
  ApiKeyProviderReasoningFormat.zaiThinking =>
    ChatCompletionsDialect.zaiThinking,
  ApiKeyProviderReasoningFormat.qwenThinking =>
    ChatCompletionsDialect.qwenThinking,
  ApiKeyProviderReasoningFormat.openRouterReasoning =>
    ChatCompletionsDialect.openRouterReasoning,
  ApiKeyProviderReasoningFormat.antLingReasoning =>
    ChatCompletionsDialect.antLingReasoning,
  ApiKeyProviderReasoningFormat.togetherReasoning =>
    ChatCompletionsDialect.togetherReasoning,
};

String _newRuntimeNamespace() {
  final random = Random.secure();
  final nonce = List<String>.generate(
    4,
    (_) => random.nextInt(1 << 30).toRadixString(36),
  ).join('-');
  return 'runtime-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$nonce';
}

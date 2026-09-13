import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../app.dart';
import '../core/agents/agents.dart';
import '../core/environment/platform_environment_reader.dart';
import '../core/llm/llm.dart';
import '../infrastructure/agents/jsonl/jsonl.dart';
import '../infrastructure/credentials/credentials.dart';
import 'day09_compaction.dart';
import 'demo_dependencies.dart';

/// Two isolated runtime policies sharing one durable repository and HTTP client.
final class Day09DemoDependencies {
  Day09DemoDependencies({
    required this.baseline,
    required this.summarized,
    required this.repository,
    required this.client,
  });

  factory Day09DemoDependencies.production({bool browserRelay = false}) {
    const secureStorage = FlutterSecureStorage();
    const environment = PlatformEnvironmentReader();
    final credentialStore = browserRelay
        ? MemoryProviderCredentialStore(<ProviderId, String>{
            BuiltInLlmCatalog.deepSeek: browserRelayCredentialMarker,
          })
        : NamespacedProviderCredentialStore(
            FlutterSecureStringStore(secureStorage),
          );
    final credentials = DefaultProviderCredentialResolver(
      store: credentialStore,
      readEnvironment: environment.read,
    );
    final client = browserRelay
        ? DeepSeekRelayClient(http.Client())
        : http.Client();
    final repository = JsonlAgentSessionStore(
      storage: createPlatformJsonlStreamStorage(),
    );
    final baseline = buildProductionAgentStack(
      httpClient: client,
      credentials: credentials,
      repository: repository,
      catalog: repository,
      diagnosticNoCompaction: true,
    );
    final summarized = buildProductionAgentStack(
      httpClient: client,
      credentials: credentials,
      repository: repository,
      catalog: repository,
      compactionTriggerOverride: const Day09MessageCadenceTrigger(),
      historyCompactorFactory: (registry, estimator) =>
          Day09StructuredSummaryCompactor(
            OpenCodeSummaryCompactor(
              llm: RegistryAgentSummaryLlmInvocation(registry),
              contextEstimator: estimator,
              recentGroupCount: Day09MessageCadenceTrigger.retainedPairs,
              maxOutputTokens: 1536,
              summaryInstruction: Day09StructuredSummaryCompactor.instruction,
              summarySystemPrompt: Day09StructuredSummaryCompactor.systemPrompt,
            ),
          ),
    );
    return Day09DemoDependencies(
      baseline: baseline,
      summarized: summarized,
      repository: repository,
      client: client,
    );
  }

  final ProductionAgentStack baseline;
  final ProductionAgentStack summarized;
  final JsonlAgentSessionStore repository;
  final http.Client client;

  Future<void> close() async {
    await baseline.runtime.close();
    await summarized.runtime.close();
    await baseline.providerModelCatalog?.close();
    await summarized.providerModelCatalog?.close();
    client.close();
  }
}

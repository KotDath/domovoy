import '../../../core/llm/capabilities.dart';
import '../../../core/llm/catalog.dart';
import '../../../core/llm/errors.dart';
import '../../../core/llm/identifiers.dart';
import '../../../core/llm/provider.dart';
import 'chat_completions_dialect.dart';

enum LlmEndpointSecurityPolicy { productionHttpsOnly, allowLoopbackHttp }

final class OpenAiCompatibleProfile {
  OpenAiCompatibleProfile({
    required this.snapshot,
    required List<LlmModel> models,
    required ChatCompletionsDialect Function(ModelId id) dialectFor,
    this.securityPolicy = LlmEndpointSecurityPolicy.productionHttpsOnly,
    this.sessionAffinityHeader,
    bool allowEmptyModels = false,
  }) : _models = List<LlmModel>.unmodifiable(List<LlmModel>.from(models)),
       _dialectFor = dialectFor {
    if (_models.isEmpty && !allowEmptyModels) {
      throwLlm(
        LlmErrorKind.configuration,
        'A compatible profile must declare explicit model entries.',
      );
    }
    final seen = <String>{};
    for (final model in _models) {
      if (model.providerId != snapshot.id) {
        throwLlm(
          LlmErrorKind.configuration,
          'Model ${model.id.value} does not belong to provider ${snapshot.id.value}.',
        );
      }
      if (model.wireFamily != snapshot.wireFamily) {
        throwLlm(
          LlmErrorKind.configuration,
          'Model ${model.id.value} wire family does not match the profile.',
        );
      }
      if (!seen.add(model.id.value)) {
        throwLlm(
          LlmErrorKind.configuration,
          'Duplicate model ${model.id.value} in compatible profile.',
        );
      }
    }
    if (snapshot.wireFamily != LlmWireFamily.openaiChatCompletions) {
      throwLlm(
        LlmErrorKind.configuration,
        'OpenAI-compatible profiles must use the Chat Completions wire family.',
      );
    }
    validateEndpoint(snapshot.endpoint, securityPolicy);
  }

  factory OpenAiCompatibleProfile.deepSeek() {
    return OpenAiCompatibleProfile(
      snapshot: BuiltInLlmCatalog.deepSeekProfile,
      models: <LlmModel>[
        BuiltInLlmCatalog.deepSeekFlashModel,
        BuiltInLlmCatalog.deepSeekV4FlashModel,
        BuiltInLlmCatalog.deepSeekV4ProModel,
      ],
      dialectFor: ChatCompletionsDialect.forBuiltInModel,
    );
  }

  factory OpenAiCompatibleProfile.moonshotAi() {
    return OpenAiCompatibleProfile(
      snapshot: BuiltInLlmCatalog.moonshotAiProfile,
      models: <LlmModel>[
        BuiltInLlmCatalog.kimiK26Model,
        BuiltInLlmCatalog.kimiK27CodeModel,
        BuiltInLlmCatalog.kimiK3Model,
      ],
      dialectFor: ChatCompletionsDialect.forBuiltInModel,
    );
  }

  factory OpenAiCompatibleProfile.custom({
    required ProviderId id,
    String? displayName,
    required Uri endpoint,
    required String environmentVariable,
    required List<LlmModel> models,
    ChatCompletionsDialect dialect = ChatCompletionsDialect.generic,
    String dialectId = 'custom_chat_completions',
    LlmEndpointSecurityPolicy securityPolicy =
        LlmEndpointSecurityPolicy.productionHttpsOnly,
    String? sessionAffinityHeader,
  }) {
    return OpenAiCompatibleProfile(
      snapshot: LlmProviderProfile(
        id: id,
        displayName: displayName,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        endpoint: endpoint,
        environmentVariable: environmentVariable,
        dialectId: dialectId,
      ),
      models: models,
      dialectFor: (_) => dialect,
      securityPolicy: securityPolicy,
      sessionAffinityHeader: sessionAffinityHeader,
    );
  }

  factory OpenAiCompatibleProfile.builtInDynamic({
    required LlmProviderProfile snapshot,
    required List<LlmModel> models,
    required ChatCompletionsDialect Function(ModelId id) dialectFor,
    String? sessionAffinityHeader,
  }) => OpenAiCompatibleProfile(
    snapshot: snapshot,
    models: models,
    dialectFor: dialectFor,
    sessionAffinityHeader: sessionAffinityHeader,
    allowEmptyModels: true,
  );

  final LlmProviderProfile snapshot;
  List<LlmModel> _models;
  List<LlmModel> get models => _models;
  final LlmEndpointSecurityPolicy securityPolicy;

  /// Request header that carries the per-conversation session id for gateways
  /// that need session affinity (OpenCode Zen). Null for ordinary providers.
  final String? sessionAffinityHeader;
  final ChatCompletionsDialect Function(ModelId id) _dialectFor;

  ProviderId get id => snapshot.id;

  ChatCompletionsDialect dialectFor(ModelId id) => _dialectFor(id);

  void replaceModels(List<LlmModel> models) {
    final seen = <String>{};
    for (final model in models) {
      if (model.providerId != snapshot.id ||
          model.wireFamily != snapshot.wireFamily ||
          !seen.add(model.id.value)) {
        throwLlm(LlmErrorKind.configuration, 'Invalid dynamic model set.');
      }
    }
    _models = List<LlmModel>.unmodifiable(models);
  }

  LlmModel requireModel(ModelId id) {
    for (final model in models) {
      if (model.id == id) {
        return model;
      }
    }
    throwLlm(
      LlmErrorKind.configuration,
      'Model ${id.value} is not registered on provider ${snapshot.id.value}.',
    );
  }

  static void validateEndpoint(Uri endpoint, LlmEndpointSecurityPolicy policy) {
    requireSecretFreeEndpoint(endpoint);
    if (endpoint.scheme == 'https' && endpoint.host.isNotEmpty) {
      return;
    }
    if (policy == LlmEndpointSecurityPolicy.allowLoopbackHttp &&
        endpoint.scheme == 'http' &&
        _isLoopback(endpoint.host)) {
      return;
    }
    throwLlm(
      LlmErrorKind.configuration,
      'Custom compatible endpoints must use HTTPS, or loopback HTTP under an explicit development/test policy.',
    );
  }

  static bool _isLoopback(String host) {
    final normalized = host.trim().toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized == '[::1]';
  }
}

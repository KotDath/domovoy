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
  }) : models = List<LlmModel>.unmodifiable(List<LlmModel>.from(models)),
       _dialectFor = dialectFor {
    if (this.models.isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'A compatible profile must declare explicit model entries.',
      );
    }
    final seen = <String>{};
    for (final model in this.models) {
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
    required Uri endpoint,
    required String environmentVariable,
    required List<LlmModel> models,
    ChatCompletionsDialect dialect = ChatCompletionsDialect.generic,
    String dialectId = 'custom_chat_completions',
    LlmEndpointSecurityPolicy securityPolicy =
        LlmEndpointSecurityPolicy.productionHttpsOnly,
  }) {
    return OpenAiCompatibleProfile(
      snapshot: LlmProviderProfile(
        id: id,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        endpoint: endpoint,
        environmentVariable: environmentVariable,
        dialectId: dialectId,
      ),
      models: models,
      dialectFor: (_) => dialect,
      securityPolicy: securityPolicy,
    );
  }

  final LlmProviderProfile snapshot;
  final List<LlmModel> models;
  final LlmEndpointSecurityPolicy securityPolicy;
  final ChatCompletionsDialect Function(ModelId id) _dialectFor;

  ProviderId get id => snapshot.id;

  ChatCompletionsDialect dialectFor(ModelId id) => _dialectFor(id);

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

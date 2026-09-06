import 'package:http/http.dart' as http;

import '../../../core/environment/environment_reader.dart';
import '../../prompt/data/chat_completions_provider_profile.dart';
import '../../prompt/data/openai_compatible_chat_agent.dart';
import '../../prompt/domain/agent.dart';
import '../../settings/domain/api_key_credentials.dart';
import '../domain/chat_model_profile.dart';
import '../domain/profile_validation.dart';
import 'profile_credential_resolver.dart';

typedef ComparisonAgentFactory = Agent Function(ChatModelProfile profile);

final class ProfileChatAgentFactory {
  ProfileChatAgentFactory({
    required http.Client client,
    required ApiKeyResolver sharedDeepSeekResolver,
    required ProfileApiKeyOverrideStore profileOverrideStore,
    required EnvironmentReader environment,
  }) : _client = client,
       _sharedDeepSeekResolver = sharedDeepSeekResolver,
       _profileOverrideStore = profileOverrideStore,
       _environment = environment;

  final http.Client _client;
  final ApiKeyResolver _sharedDeepSeekResolver;
  final ProfileApiKeyOverrideStore _profileOverrideStore;
  final EnvironmentReader _environment;

  Agent create(ChatModelProfile profile) {
    ensureValidChatModelProfile(profile);
    return OpenAiCompatibleChatAgent(
      client: _client,
      apiKeyResolver: credentialResolverForProfile(
        profile: profile,
        sharedDeepSeekResolver: _sharedDeepSeekResolver,
        profileOverrideStore: _profileOverrideStore,
        environment: _environment,
      ),
      profile: ChatCompletionsProviderProfile(
        endpoint: profile.endpoint,
        model: profile.modelId,
        reasoningDeltaField: 'reasoning_content',
        dialect: profile.dialect,
      ),
      providerLabel: providerLabelFor(profile),
    );
  }

  static String providerLabelFor(ChatModelProfile profile) {
    if (profile.authentication == ProfileAuthenticationMode.sharedDeepSeek ||
        profile.dialect == ChatRequestDialect.deepSeek) {
      return 'DeepSeek';
    }
    return 'Провайдер';
  }
}

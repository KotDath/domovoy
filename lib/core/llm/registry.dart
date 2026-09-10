import 'cancellation.dart';
import 'capabilities.dart';
import 'errors.dart';
import 'events.dart';
import 'identifiers.dart';
import 'provider.dart';
import 'request.dart';

final class LlmResolvedSelection {
  LlmResolvedSelection({
    required this.provider,
    required this.model,
    this.profile,
  });

  final LlmProvider provider;
  final LlmModel model;
  final LlmProviderProfile? profile;
}

final class LlmProviderRegistry {
  final Map<String, LlmProvider> _providers = <String, LlmProvider>{};
  final Map<(String, String), LlmModel> _models =
      <(String, String), LlmModel>{};
  final Map<String, LlmProviderProfile> _profiles =
      <String, LlmProviderProfile>{};
  final Map<String, Set<String>> _providersByModelId = <String, Set<String>>{};

  List<LlmProviderProfile> get profiles =>
      List<LlmProviderProfile>.unmodifiable(
        _profiles.values.toList(growable: false),
      );

  List<LlmModel> get models =>
      List<LlmModel>.unmodifiable(_models.values.toList(growable: false));

  List<LlmProvider> get providers =>
      List<LlmProvider>.unmodifiable(_providers.values.toList(growable: false));

  void registerProvider(LlmProvider provider) {
    final key = provider.id.value;
    if (_providers.containsKey(key)) {
      throwLlm(
        LlmErrorKind.configuration,
        'Provider "$key" is already registered.',
      );
    }
    _providers[key] = provider;
  }

  void registerModel(LlmModel model) {
    final key = _modelKey(model.providerId, model.id);
    if (_models.containsKey(key)) {
      throwLlm(
        LlmErrorKind.configuration,
        'Model ${model.ref} is already registered.',
      );
    }
    _models[key] = model;
    _providersByModelId
        .putIfAbsent(model.id.value, () => <String>{})
        .add(model.providerId.value);
  }

  void registerProfile(LlmProviderProfile profile) {
    final key = profile.id.value;
    if (_profiles.containsKey(key)) {
      throwLlm(
        LlmErrorKind.configuration,
        'Profile "$key" is already registered.',
      );
    }
    _profiles[key] = profile;
  }

  LlmProvider requireProvider(ProviderId id) {
    final provider = _providers[id.value];
    if (provider == null) {
      throwLlm(LlmErrorKind.configuration, 'Unknown provider "${id.value}".');
    }
    return provider;
  }

  LlmModel requireModel(ModelRef ref) {
    final exact = _models[_modelKey(ref.providerId, ref.modelId)];
    if (exact != null) {
      return exact;
    }
    final others = _providersByModelId[ref.modelId.value];
    if (others != null && others.isNotEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Model "${ref.modelId.value}" is not registered under provider "${ref.providerId.value}".',
      );
    }
    throwLlm(
      LlmErrorKind.configuration,
      'Unknown model "${ref.modelId.value}" for provider "${ref.providerId.value}".',
    );
  }

  LlmResolvedSelection resolve(ModelRef ref) {
    final provider = requireProvider(ref.providerId);
    final model = requireModel(ref);
    if (model.wireFamily != provider.wireFamily) {
      throwLlm(
        LlmErrorKind.configuration,
        'Model "${model.id.value}" wire family does not match provider "${provider.id.value}".',
      );
    }
    final profile = _profiles[ref.providerId.value];
    if (profile != null && profile.wireFamily != model.wireFamily) {
      throwLlm(
        LlmErrorKind.configuration,
        'Model "${model.id.value}" wire family does not match profile "${profile.id.value}".',
      );
    }
    return LlmResolvedSelection(
      provider: provider,
      model: model,
      profile: profile,
    );
  }

  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) {
    final selection = resolve(request.model);
    validateRequestAgainstModel(request, selection.model);
    return guardLlmEventStream(
      selection.provider.stream(request, cancellation: cancellation),
    );
  }

  static (String, String) _modelKey(ProviderId providerId, ModelId modelId) =>
      (providerId.value, modelId.value);
}

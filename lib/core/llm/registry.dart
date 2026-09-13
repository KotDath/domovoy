import 'cancellation.dart';
import 'capabilities.dart';
import 'errors.dart';
import 'events.dart';
import 'identifiers.dart';
import 'json.dart';
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

final class LlmProviderGroup {
  LlmProviderGroup({
    required this.providerId,
    required String displayName,
    required List<LlmModel> models,
  }) : displayName = displayName.trim(),
       models = List<LlmModel>.unmodifiable(List<LlmModel>.from(models)) {
    if (this.displayName.isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Provider display name must not be blank.',
      );
    }
  }

  final ProviderId providerId;
  final String displayName;
  final List<LlmModel> models;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmProviderGroup &&
          other.providerId == providerId &&
          other.displayName == displayName &&
          listEquals(other.models, models);

  @override
  int get hashCode =>
      Object.hash(providerId, displayName, Object.hashAll(models));
}

final class LlmProviderRegistry {
  final Map<String, LlmProvider> _providers = <String, LlmProvider>{};
  final Map<(String, String), LlmModel> _models =
      <(String, String), LlmModel>{};
  final Map<(String, String), LlmModel> _retiredModels =
      <(String, String), LlmModel>{};
  final Map<String, LlmProviderProfile> _profiles =
      <String, LlmProviderProfile>{};
  final Map<String, Set<String>> _providersByModelId = <String, Set<String>>{};
  var _catalogGeneration = 0;

  int get catalogGeneration => _catalogGeneration;

  List<LlmProviderProfile> get profiles =>
      List<LlmProviderProfile>.unmodifiable(
        _profiles.values.toList(growable: false),
      );

  List<LlmModel> get models =>
      List<LlmModel>.unmodifiable(_models.values.toList(growable: false));

  List<LlmProvider> get providers =>
      List<LlmProvider>.unmodifiable(_providers.values.toList(growable: false));

  List<LlmProviderGroup> get providerGroups {
    final modelsByProvider = <String, List<LlmModel>>{};
    for (final model in _models.values) {
      if (!_profiles.containsKey(model.providerId.value)) {
        throwLlm(
          LlmErrorKind.configuration,
          'Model ${model.ref} has no registered provider profile.',
        );
      }
      modelsByProvider
          .putIfAbsent(model.providerId.value, () => <LlmModel>[])
          .add(model);
    }
    return List<LlmProviderGroup>.unmodifiable(<LlmProviderGroup>[
      for (final profile in _profiles.values)
        LlmProviderGroup(
          providerId: profile.id,
          displayName: profile.displayName,
          models: modelsByProvider[profile.id.value] ?? const <LlmModel>[],
        ),
    ]);
  }

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

  /// Publishes a complete validated model generation in one synchronous step.
  void replaceModels(Iterable<LlmModel> models) {
    final next = <(String, String), LlmModel>{};
    final byId = <String, Set<String>>{};
    for (final model in models) {
      final profile = _profiles[model.providerId.value];
      final provider = _providers[model.providerId.value];
      if (profile == null ||
          provider == null ||
          profile.wireFamily != model.wireFamily ||
          provider.wireFamily != model.wireFamily) {
        throwLlm(
          LlmErrorKind.configuration,
          'Model ${model.ref} has no matching registered provider and profile.',
        );
      }
      final key = _modelKey(model.providerId, model.id);
      if (next.containsKey(key)) {
        throwLlm(
          LlmErrorKind.configuration,
          'Duplicate model ${model.ref} in catalog generation.',
        );
      }
      next[key] = model;
      byId
          .putIfAbsent(model.id.value, () => <String>{})
          .add(model.providerId.value);
    }
    for (final entry in _models.entries) {
      if (!next.containsKey(entry.key)) _retiredModels[entry.key] = entry.value;
    }
    for (final key in next.keys) {
      _retiredModels.remove(key);
    }
    _models
      ..clear()
      ..addAll(next);
    _providersByModelId
      ..clear()
      ..addAll(byId);
    _catalogGeneration++;
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
    final key = _modelKey(ref.providerId, ref.modelId);
    final exact = _models[key] ?? _retiredModels[key];
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

  bool isModelAvailable(ModelRef ref) =>
      _models.containsKey(_modelKey(ref.providerId, ref.modelId));

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
    if (!isModelAvailable(request.model)) {
      throwLlm(
        LlmErrorKind.configuration,
        'Model "${request.model.modelId.value}" is no longer in the provider catalog. Select a replacement.',
      );
    }
    final selection = resolve(request.model);
    validateRequestAgainstModel(request, selection.model);
    return guardLlmEventStream(
      selection.provider.stream(request, cancellation: cancellation),
    );
  }

  static (String, String) _modelKey(ProviderId providerId, ModelId modelId) =>
      (providerId.value, modelId.value);
}
